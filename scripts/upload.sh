#!/bin/bash
# ─────────────────────────────────────────────────────────────────
# openmedia-uploader: S3 → 7z → Nyuu Usenet Upload Pipeline
#
# Streams MKV from S3 via mkfifo, splits into 7z parts with
# header encryption, generates 30% PAR2, uploads via Nyuu to
# all 3 providers. Each provider gets its own nyuu run + NZB.
# Final combined NZB is uploaded to S3.
#
# ENV Variables (required):
#   JOB_ID                 UploadJob ID in openmedia-api
#   JOB_HASH               NzbFile hash (= NZB hash)
#   S3_KEY                 S3 key of the MKV file
#   API_BASE_URL           openmedia-api base URL
#   SERVICE_TOKEN          API auth token
#   S3_ENDPOINT            Hetzner S3 endpoint
#   S3_BUCKET              S3 bucket name
#   S3_ACCESS_KEY          S3 access key
#   S3_SECRET_KEY          S3 secret key
#   HETZNER_API_TOKEN      For VPS self-delete
#   USENET_HOST_1/2/3      Usenet server hostnames
#   USENET_PORT_1/2/3      Usenet server ports
#   USENET_USER_1/2/3      Usenet usernames
#   USENET_PASS_1/2/3      Usenet passwords
#   USENET_SSL_1/2/3       Use SSL (1/0)
#   USENET_CONNS_1/2/3     Connections per provider
#   POSTER_NAME            Poster name in NNTP headers
# ─────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Constants ────────────────────────────────────────────────────
PART_SIZE="250m"
PAR2_REDUNDANCY="30"
NEWSGROUP_POOL=(
  "alt.binaries.misc"
  "alt.binaries.flowed"
  "alt.binaries.iso"
  "alt.binaries.test"
  "alt.binaries.a51"
  "alt.binaries.mom"
  "alt.binaries.bloaf"
  "alt.binaries.boneless"
  "alt.binaries.multimedia"
)
TMPDIR="/opt/openmedia/tmp"

# ── Helper: logging with timestamp ───────────────────────────────
log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { log "FATAL: $*" >&2; report_status "failed" "$*"; exit 1; }

# ── Validate required ENV ────────────────────────────────────────
validate_env() {
  local required=(
    JOB_HASH S3_KEY API_BASE_URL SERVICE_TOKEN
    S3_ENDPOINT S3_BUCKET S3_ACCESS_KEY S3_SECRET_KEY
    HETZNER_API_TOKEN USENET_HOST_1 USENET_HOST_2 USENET_HOST_3
  )
  for var in "${required[@]}"; do
    [[ -z "${!var:-}" ]] && die "Missing required ENV: $var"
  done
}

# ── Helper: report status to API ─────────────────────────────────
report_status() {
  local status="$1"
  local error="${2:-}"
  local body
  body=$(jq -n --arg status "$status" --arg error "$error" \
    '{status: $status, error: (if $error == "" then null else $error end)}')

  curl -sf -X PATCH "${API_BASE_URL}/upload-jobs/${JOB_ID}" \
    -H "Authorization: Bearer ${SERVICE_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$body" || log "WARN: API status report failed (status=${status})"
}

# ── Helper: select 3 unique random newsgroups from pool ──────────
select_newsgroups() {
  local indices
  indices=$(shuf -i 0-$((${#NEWSGROUP_POOL[@]}-1)) -n 3)
  local groups=()
  for i in $indices; do
    groups+=("${NEWSGROUP_POOL[$i]}")
  done
  echo "${groups[0]}" "${groups[1]}" "${groups[2]}"
}

# ── Helper: generate random password ─────────────────────────────
generate_password() {
  openssl rand -base64 18 | tr -d '/+=' | head -c 24
}

# ── Helper: generate UUID ────────────────────────────────────────
generate_uuid() {
  cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16
}

# ── Helper: upload NZB to S3 ─────────────────────────────────────
upload_nzb_to_s3() {
  local nzb_file="$1"
  local s3_key="nzb/${JOB_HASH}.nzb"

  log "Uploading NZB to S3: ${s3_key}"
  rclone copyto "$nzb_file" \
    "s3:${S3_BUCKET}/${s3_key}" \
    --s3-endpoint "${S3_ENDPOINT}" \
    --s3-access-key-id "${S3_ACCESS_KEY}" \
    --s3-secret-access-key "${S3_SECRET_KEY}" \
    || die "Failed to upload NZB to S3"
  echo "$s3_key"
}

# ── Helper: VPS self-delete ──────────────────────────────────────
vps_self_delete() {
  local instance_id
  instance_id=$(curl -sf http://169.254.169.254/hetzner/v1/metadata/instance-id) || {
    log "WARN: Could not determine VPS instance ID, skipping self-delete"
    return
  }

  log "VPS self-delete: instance=${instance_id}"
  curl -sf -X DELETE "https://api.hetzner.cloud/v1/servers/${instance_id}" \
    -H "Authorization: Bearer ${HETZNER_API_TOKEN}" || {
    log "WARN: VPS self-delete failed (instance=${instance_id})"
  }
}

# ── Helper: upload to one provider via Nyuu ──────────────────────
upload_to_provider() {
  local provider_num="$1"
  local host="$2"
  local port="${3:-563}"
  local user="$4"
  local pass="$5"
  local ssl="${6:-1}"
  local conns="${7:-10}"
  local group="$8"
  local password="$9"
  local part_dir="${10}"
  local hash="${11}"

  local ssl_flag=""
  [[ "$ssl" == "1" ]] && ssl_flag="--ssl"

  local nzb_path="${part_dir}/${hash}_provider${provider_num}.nzb"

  log "Provider ${provider_num}: ${host}:${port} (ssl=${ssl}, conns=${conns})"
  log "  Group: ${group}"
  log "  NZB:   ${nzb_path}"

  # Collect upload files (7z parts + PAR2 files), sorted
  local upload_files=()
  while IFS= read -r -d '' file; do
    upload_files+=("$file")
  done < <(
    find "$part_dir" -maxdepth 1 \( -name "${hash}.7z.*" -o -name "${hash}.par2" -o -name "${hash}.vol*.par2" \) \
      -print0 | sort -z
  )

  log "  Uploading ${#upload_files[@]} files"

  local nyuu_log="${part_dir}/nyuu_provider${provider_num}.log"

  nyuu \
    -h "$host" \
    -P "$port" \
    -u "$user" \
    -p "$pass" \
    $ssl_flag \
    -n "$conns" \
    -g "$group" \
    -f "${POSTER_NAME:-$(generate_uuid)}" \
    -o "$nzb_path" \
    --obfuscate full \
    --nzb-password "$password" \
    --nzb-category "Movies" \
    --check-connections all \
    --check-tries 3 \
    "${upload_files[@]}" 2>&1 | tee "$nyuu_log"

  local exit_code=${PIPESTATUS[0]}

  if [[ $exit_code -ne 0 ]]; then
    log "WARN: Provider ${provider_num} upload failed (exit=${exit_code})"
    return 1
  fi

  log "Provider ${provider_num}: upload complete"
  return 0
}

# ══════════════════════════════════════════════════════════════════
# MAIN PIPELINE
# ══════════════════════════════════════════════════════════════════
main() {
  log "=========================================="
  log "openmedia-uploader starting"
  log "Hash:     ${JOB_HASH:0:16}..."
  log "S3 Key:   ${S3_KEY}"
  log "Job ID:   ${JOB_ID}"
  log "=========================================="

  validate_env

  # ── Step 0: Mark as running ────────────────────────────────────
  report_status "running"
  local start_time
  start_time=$(date +%s)

  # ── Step 1: Prepare ────────────────────────────────────────────
  local password
  password=$(generate_password)
  log "Generated password: (hidden)"

  local group1 group2 group3
  read -r group1 group2 group3 < <(select_newsgroups)
  log "Newsgroups: ${group1} / ${group2} / ${group3}"

  local poster_name="${POSTER_NAME:-$(generate_uuid)}"
  log "Poster name: ${poster_name}"

  local part_dir="${TMPDIR}/${JOB_HASH}"
  mkdir -p "$part_dir"

  # ── Step 2: S3 → mkfifo → 7z (stream pipeline) ───────────────
  local mkv_pipe="${part_dir}/mkv.fifo"
  mkfifo "$mkv_pipe"

  log "Starting 7z compression (parts=${PART_SIZE}, header-encrypted)"
  7z a -si"${JOB_HASH}.mkv" \
    -p"${password}" \
    -mhe=on \
    -mx0 \
    -v"${PART_SIZE}" \
    -t7z \
    "${part_dir}/${JOB_HASH}.7z" < "$mkv_pipe" &
  local sevenz_pid=$!

  log "Starting rclone stream from S3"
  rclone cat "s3:${S3_BUCKET}/${S3_KEY}" \
    --s3-endpoint "${S3_ENDPOINT}" \
    --s3-access-key-id "${S3_ACCESS_KEY}" \
    --s3-secret-access-key "${S3_SECRET_KEY}" \
    > "$mkv_pipe" &
  local rclone_pid=$!

  # Wait for both — rclone drives the pipe, 7z consumes it
  local exit_code=0
  wait $sevenz_pid || exit_code=$?
  wait $rclone_pid 2>/dev/null || true

  rm -f "$mkv_pipe"

  if [[ $exit_code -ne 0 ]]; then
    die "7z compression failed (exit=$exit_code). Stream may have broken."
  fi

  local part_count
  part_count=$(find "$part_dir" -name "${JOB_HASH}.7z.*" | wc -l)
  local total_size
  total_size=$(du -sh "$part_dir" | cut -f1)
  log "7z done: ${part_count} parts, total=${total_size}"

  # ── Step 3: Generate PAR2 ──────────────────────────────────────
  log "Generating PAR2 files (redundancy=${PAR2_REDUNDANCY}%)"
  par2create -r"${PAR2_REDUNDANCY}" -q \
    "${part_dir}/${JOB_HASH}.par2" "${part_dir}/${JOB_HASH}.7z."* || \
    die "PAR2 generation failed"

  local par2_count
  par2_count=$(find "$part_dir" -name "${JOB_HASH}.par2" -o -name "${JOB_HASH}.vol*.par2" | wc -l)
  log "PAR2 done: ${par2_count} files"

  # ── Step 4: Upload to all 3 providers ──────────────────────────
  local providers_ok=0
  local providers_failed=0

  log "Starting Nyuu uploads to 3 providers"

  # Provider 1
  if upload_to_provider 1 \
    "${USENET_HOST_1}" "${USENET_PORT_1:-563}" \
    "${USENET_USER_1}" "${USENET_PASS_1}" \
    "${USENET_SSL_1:-1}" "${USENET_CONNS_1:-10}" \
    "$group1" "$password" "$part_dir" "$JOB_HASH"; then
    ((providers_ok++))
  else
    ((providers_failed++))
  fi

  # Provider 2
  if upload_to_provider 2 \
    "${USENET_HOST_2}" "${USENET_PORT_2:-563}" \
    "${USENET_USER_2}" "${USENET_PASS_2}" \
    "${USENET_SSL_2:-1}" "${USENET_CONNS_2:-10}" \
    "$group2" "$password" "$part_dir" "$JOB_HASH"; then
    ((providers_ok++))
  else
    ((providers_failed++))
  fi

  # Provider 3
  if upload_to_provider 3 \
    "${USENET_HOST_3}" "${USENET_PORT_3:-563}" \
    "${USENET_USER_3}" "${USENET_PASS_3}" \
    "${USENET_SSL_3:-1}" "${USENET_CONNS_3:-10}" \
    "$group3" "$password" "$part_dir" "$JOB_HASH"; then
    ((providers_ok++))
  else
    ((providers_failed++))
  fi

  log "Upload results: ${providers_ok} succeeded, ${providers_failed} failed"

  if [[ $providers_ok -eq 0 ]]; then
    die "All 3 providers failed. Upload cannot proceed."
  fi

  # ── Step 5: Combine NZBs into one ──────────────────────────────
  # Take the first successful provider's NZB as the primary.
  # All 3 have the same file list (just different servers/groups).
  local primary_nzb="${part_dir}/${JOB_HASH}_provider1.nzb"
  if [[ ! -f "$primary_nzb" ]]; then
    primary_nzb="${part_dir}/${JOB_HASH}_provider2.nzb"
  fi
  if [[ ! -f "$primary_nzb" ]]; then
    primary_nzb="${part_dir}/${JOB_HASH}_provider3.nzb"
  fi
  if [[ ! -f "$primary_nzb" ]]; then
    die "No NZB file found after uploads"
  fi

  # The primary NZB is the one we store — it contains references to
  # all the article parts. Any provider will serve them (articles
  # propagate between backbones).
  local nzb_path="${part_dir}/${JOB_HASH}.nzb"
  cp "$primary_nzb" "$nzb_path"

  local nzb_size
  nzb_size=$(stat -c%s "$nzb_path" 2>/dev/null || stat -f%z "$nzb_path")
  log "Primary NZB: ${nzb_path} (${nzb_size} bytes)"

  # ── Step 6: Upload NZB to S3 ───────────────────────────────────
  local nzb_s3_key
  nzb_s3_key=$(upload_nzb_to_s3 "$nzb_path")

  # ── Step 7: Report completion to API ───────────────────────────
  local elapsed=$(( $(date +%s) - start_time ))
  log "Total upload time: ${elapsed}s"

  curl -sf -X PATCH "${API_BASE_URL}/upload-jobs/${JOB_ID}" \
    -H "Authorization: Bearer ${SERVICE_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
      --arg status "completed" \
      --arg nzbS3Key "$nzb_s3_key" \
      '{status: $status, nzbS3Key: $nzbS3Key}'
    )" || log "WARN: API completion callback failed"

  log "API callback sent: status=completed, nzbS3Key=${nzb_s3_key}"

  # ── Step 8: Cleanup temp files ─────────────────────────────────
  rm -rf "$part_dir"
  log "Temp files cleaned up"

  # ── Step 9: VPS self-delete ────────────────────────────────────
  vps_self_delete

  log "=========================================="
  log "Upload completed successfully"
  log "Hash:     ${JOB_HASH:0:16}..."
  log "NZB:      ${nzb_s3_key}"
  log "Parts:    ${part_count}"
  log "Providers: ${providers_ok}/${providers_failed}"
  log "Time:     ${elapsed}s"
  log "=========================================="
}

main "$@"
