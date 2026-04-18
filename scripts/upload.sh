#!/bin/bash
# ─────────────────────────────────────────────────────────────────
# openmedia-uploader: S3 → 7z → Nyuu Usenet Upload Pipeline
#
# Streams MKV from S3 via mkfifo, splits into 7z parts with
# header encryption, generates 30% PAR2, uploads via Nyuu to
# both providers. Each provider gets its own nyuu run + NZB.
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
#   NZB_SERVICE_URL        NZB-Service base URL (e.g. https://nzb.nettoken.de)
#   NZB_SERVICE_TOKEN      NZB-Service JWT token
#   USENET_HOST_1/2        Usenet server hostnames
#   USENET_PORT_1/2        Usenet server ports
#   USENET_USER_1/2        Usenet usernames
#   USENET_PASS_1/2        Usenet passwords
#   USENET_SSL_1/2         Use SSL (1/0)
#   USENET_CONNS_1/2       Connections per provider
#   POSTER_NAME            Poster name in NNTP headers
# ─────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Bootstrap: fetch config from API if running in 3-var mode ────
API_ENV_FILE="/opt/openmedia/api-env.sh"
if [[ ! -f "$API_ENV_FILE" ]] && [[ -n "${API_BASE_URL:-}" ]] && [[ -n "${SERVICE_TOKEN:-}" ]] && [[ -n "${JOB_ID:-}" ]]; then
  /opt/openmedia/00-fetch-config.sh
fi
if [[ -f "$API_ENV_FILE" ]]; then
  source "$API_ENV_FILE"
fi

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
    NZB_SERVICE_URL NZB_SERVICE_TOKEN
    USENET_HOST_1 USENET_HOST_2
  )
  for var in "${required[@]}"; do
    if [[ -z "${!var:-}" ]]; then die "Missing required ENV: $var"; fi
  done
}

# ── Helper: report status to API ─────────────────────────────────
report_status() {
  local status="$1"
  local error="${2:-}"
  local body
  body=$(jq -n --arg status "$status" --arg error "$error" \
    '{status: $status, error: (if $error == "" then null else $error end)}' 2>/dev/null) || true

  curl -sf -X PATCH "${API_BASE_URL}/uploads/${JOB_ID}" \
    -H "Authorization: Bearer ${SERVICE_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$body" 2>/dev/null || true
}

# ── Helper: select 2 unique random newsgroups from pool ──────────
select_newsgroups() {
  local indices
  indices=$(shuf -i 0-$((${#NEWSGROUP_POOL[@]}-1)) -n 2)
  local groups=()
  for i in $indices; do
    groups+=("${NEWSGROUP_POOL[$i]}")
  done
  echo "${groups[0]}" "${groups[1]}"
}

# ── Helper: generate random password ─────────────────────────────
generate_password() {
  openssl rand -base64 18 | tr -d '/+=' | head -c 24
}

# ── Helper: generate UUID ────────────────────────────────────────
generate_uuid() {
  cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16
}

# ── Helper: extract media metadata via ffprobe ─────────────────
# Streams the MKV from S3 and runs ffprobe to extract video/audio/subtitle info.
# Sets global variables: METADATA_JSON (full ffprobe output) and individual fields.
extract_metadata() {
  log "Extracting media metadata via ffprobe"

  # Verify ffprobe is available (apk del --purge can remove it on ARM)
  if ! command -v ffprobe &>/dev/null; then
    log "WARN: ffprobe not found in PATH — skipping metadata extraction"
    METADATA_JSON=""
    return 0
  fi

  local probe_json
  local rclone_err ffprobe_err
  rclone_err=$(mktemp)
  ffprobe_err=$(mktemp)

  # Stream first 50MB from S3 — enough for ffprobe to read container headers.
  # Write to a temp file to avoid SIGPIPE when ffprobe exits before rclone finishes.
  local probe_file
  probe_file=$(mktemp /tmp/ffprobe-head-XXXXXX)

  log "Downloading first 50MB from S3 for ffprobe analysis..."
  if ! rclone cat ":s3:${S3_BUCKET}/${S3_KEY}" \
    --s3-provider "Other" \
    --s3-endpoint "${S3_ENDPOINT}" \
    --s3-access-key-id "${S3_ACCESS_KEY}" \
    --s3-secret-access-key "${S3_SECRET_KEY}" \
    --head 52428800 \
    2>"$rclone_err" > "$probe_file"; then
    log "WARN: rclone download for ffprobe failed — continuing without metadata"
    log "  rclone stderr: $(head -3 "$rclone_err")"
    rm -f "$rclone_err" "$ffprobe_err" "$probe_file"
    METADATA_JSON=""
    return 0
  fi

  local probe_size
  probe_size=$(stat -c%s "$probe_file" 2>/dev/null || stat -f%z "$probe_file" 2>/dev/null || echo "0")
  log "ffprobe input: ${probe_size} bytes"

  probe_json=$(ffprobe -v error -print_format json -show_format -show_streams "$probe_file" 2>"$ffprobe_err") || {
    log "WARN: ffprobe analysis failed — continuing without metadata"
    log "  ffprobe stderr: $(head -3 "$ffprobe_err")"
    rm -f "$rclone_err" "$ffprobe_err" "$probe_file"
    METADATA_JSON=""
    return 0
  }
  rm -f "$rclone_err" "$ffprobe_err" "$probe_file"

  # Validate that ffprobe produced actual JSON (not empty output)
  if [[ -z "$probe_json" ]] || ! echo "$probe_json" | jq -e '.streams' &>/dev/null; then
    log "WARN: ffprobe produced empty or invalid JSON — skipping metadata"
    METADATA_JSON=""
    return 0
  fi

  log "ffprobe OK: $(echo "$probe_json" | jq -r '[.streams[] | .codec_type + ":" + .codec_name] | join(", ")')"

  METADATA_JSON="$probe_json"

  # ── Video stream (first video track) ──
  META_VIDEO_WIDTH=$(echo "$probe_json" | jq -r '[.streams[] | select(.codec_type=="video")][0].width // empty')
  META_VIDEO_HEIGHT=$(echo "$probe_json" | jq -r '[.streams[] | select(.codec_type=="video")][0].height // empty')
  META_VIDEO_CODEC=$(echo "$probe_json" | jq -r '[.streams[] | select(.codec_type=="video")][0].codec_name // empty')
  META_VIDEO_BITRATE=$(echo "$probe_json" | jq -r '[.streams[] | select(.codec_type=="video")][0].bit_rate // empty')
  META_VIDEO_FRAMERATE=$(echo "$probe_json" | jq -r '[.streams[] | select(.codec_type=="video")][0].r_frame_rate // empty')
  META_VIDEO_PIX_FMT=$(echo "$probe_json" | jq -r '[.streams[] | select(.codec_type=="video")][0].pix_fmt // empty')
  META_VIDEO_PROFILE=$(echo "$probe_json" | jq -r '[.streams[] | select(.codec_type=="video")][0].profile // empty')

  # Color depth from pix_fmt (e.g. yuv420p10le → 10, yuv420p → 8)
  META_VIDEO_COLOR_DEPTH=8
  if [[ "$META_VIDEO_PIX_FMT" =~ 10le|10be|p010 ]]; then
    META_VIDEO_COLOR_DEPTH=10
  elif [[ "$META_VIDEO_PIX_FMT" =~ 12le|12be ]]; then
    META_VIDEO_COLOR_DEPTH=12
  fi

  # HDR detection: check for HDR side data or bt2020 color space
  local color_transfer color_primaries
  color_transfer=$(echo "$probe_json" | jq -r '[.streams[] | select(.codec_type=="video")][0].color_transfer // empty')
  color_primaries=$(echo "$probe_json" | jq -r '[.streams[] | select(.codec_type=="video")][0].color_primaries // empty')

  META_HDR=false
  META_HDR_FORMAT=""
  if [[ "$color_transfer" == "smpte2084" || "$color_transfer" == "arib-std-b67" ]]; then
    META_HDR=true
    if [[ "$color_transfer" == "smpte2084" ]]; then
      # Check side_data for Dolby Vision
      local has_dv
      has_dv=$(echo "$probe_json" | jq '[.streams[] | select(.codec_type=="video")][0].side_data_list // [] | any(.side_data_type == "DOVI configuration record")') 2>/dev/null || has_dv="false"
      if [[ "$has_dv" == "true" ]]; then
        META_HDR_FORMAT="Dolby Vision"
      else
        META_HDR_FORMAT="HDR10"
      fi
    elif [[ "$color_transfer" == "arib-std-b67" ]]; then
      META_HDR_FORMAT="HLG"
    fi
  fi

  # Framerate: convert fraction to decimal (e.g. 24000/1001 → 23.976)
  META_VIDEO_FRAMERATE_DEC=""
  if [[ "$META_VIDEO_FRAMERATE" =~ ^([0-9]+)/([0-9]+)$ ]]; then
    local num="${BASH_REMATCH[1]}"
    local den="${BASH_REMATCH[2]}"
    if [[ "$den" -gt 0 ]]; then
      META_VIDEO_FRAMERATE_DEC=$(awk "BEGIN {printf \"%.3f\", $num/$den}")
    fi
  elif [[ -n "$META_VIDEO_FRAMERATE" ]]; then
    META_VIDEO_FRAMERATE_DEC="$META_VIDEO_FRAMERATE"
  fi

  # Video bitrate: convert to kbps (ffprobe gives bps)
  META_VIDEO_BITRATE_KBPS=""
  if [[ -n "$META_VIDEO_BITRATE" && "$META_VIDEO_BITRATE" != "N/A" ]]; then
    META_VIDEO_BITRATE_KBPS=$(( META_VIDEO_BITRATE / 1000 ))
  fi

  # ── Quality tier from height ──
  META_QUALITY_TIER=""
  if [[ -n "$META_VIDEO_HEIGHT" ]]; then
    local h="$META_VIDEO_HEIGHT"
    if [[ $h -le 480 ]]; then
      META_QUALITY_TIER="480p"
    elif [[ $h -le 720 ]]; then
      META_QUALITY_TIER="720p"
    elif [[ $h -le 1080 ]]; then
      META_QUALITY_TIER="1080p"
    else
      META_QUALITY_TIER="2160p"
    fi
  fi

  # ── Audio streams ──
  META_AUDIO_CODEC=$(echo "$probe_json" | jq -r '[.streams[] | select(.codec_type=="audio")][0].codec_name // empty')
  META_AUDIO_CHANNELS=$(echo "$probe_json" | jq -r '[.streams[] | select(.codec_type=="audio")][0].channels // empty')
  META_AUDIO_BITRATE=$(echo "$probe_json" | jq -r '[.streams[] | select(.codec_type=="audio")][0].bit_rate // empty')

  # Audio channel layout string (2→"2.0", 6→"5.1", 8→"7.1")
  META_AUDIO_CHANNELS_STR=""
  case "$META_AUDIO_CHANNELS" in
    "") META_AUDIO_CHANNELS_STR="" ;;
    1) META_AUDIO_CHANNELS_STR="1.0" ;;
    2) META_AUDIO_CHANNELS_STR="2.0" ;;
    6) META_AUDIO_CHANNELS_STR="5.1" ;;
    8) META_AUDIO_CHANNELS_STR="7.1" ;;
    *) META_AUDIO_CHANNELS_STR="${META_AUDIO_CHANNELS}.0" ;;
  esac

  META_AUDIO_BITRATE_KBPS=""
  if [[ -n "$META_AUDIO_BITRATE" && "$META_AUDIO_BITRATE" != "N/A" ]]; then
    META_AUDIO_BITRATE_KBPS=$(( META_AUDIO_BITRATE / 1000 ))
  fi

  # Audio languages from all audio streams
  META_AUDIO_LANGUAGES=$(echo "$probe_json" | jq -r '[.streams[] | select(.codec_type=="audio") | .tags.language // empty] | unique | join(",")')

  # ── Subtitle languages ──
  META_SUBTITLE_LANGUAGES=$(echo "$probe_json" | jq -r '[.streams[] | select(.codec_type=="subtitle") | .tags.language // empty] | unique | join(",")')

  # ── Duration (seconds) ──
  META_DURATION=$(echo "$probe_json" | jq -r '.format.duration // empty')
  META_DURATION_INT=""
  if [[ -n "$META_DURATION" ]]; then
    META_DURATION_INT=$(awk "BEGIN {printf \"%d\", $META_DURATION}")
  fi

  # ── File size (bytes) — from S3 metadata, not ffprobe ──
  # ffprobe only sees the --head 50MB chunk, so its format.size is wrong.
  META_FILE_SIZE=$(rclone size ":s3:${S3_BUCKET}/${S3_KEY}" \
    --s3-provider "Other" \
    --s3-endpoint "${S3_ENDPOINT}" \
    --s3-access-key-id "${S3_ACCESS_KEY}" \
    --s3-secret-access-key "${S3_SECRET_KEY}" \
    --json 2>/dev/null | jq -r '.bytes // empty' || true)
  if [[ -z "$META_FILE_SIZE" ]]; then
    META_FILE_SIZE=$(echo "$probe_json" | jq -r '.format.size // empty')
  fi

  # Normalized video codec name for DB
  META_VIDEO_CODEC_NORMALIZED=""
  case "$META_VIDEO_CODEC" in
    hevc|h265) META_VIDEO_CODEC_NORMALIZED="x265" ;;
    h264|avc) META_VIDEO_CODEC_NORMALIZED="x264" ;;
    av1) META_VIDEO_CODEC_NORMALIZED="AV1" ;;
    mpeg4) META_VIDEO_CODEC_NORMALIZED="XviD" ;;
    *) META_VIDEO_CODEC_NORMALIZED="$META_VIDEO_CODEC" ;;
  esac

  # Normalized audio codec name
  META_AUDIO_CODEC_NORMALIZED=""
  case "$META_AUDIO_CODEC" in
    aac) META_AUDIO_CODEC_NORMALIZED="AAC" ;;
    ac3) META_AUDIO_CODEC_NORMALIZED="AC3" ;;
    eac3) META_AUDIO_CODEC_NORMALIZED="EAC3" ;;
    dts) META_AUDIO_CODEC_NORMALIZED="DTS" ;;
    truehd) META_AUDIO_CODEC_NORMALIZED="TrueHD" ;;
    flac) META_AUDIO_CODEC_NORMALIZED="FLAC" ;;
    opus) META_AUDIO_CODEC_NORMALIZED="Opus" ;;
    *) META_AUDIO_CODEC_NORMALIZED="$META_AUDIO_CODEC" ;;
  esac

  log "Metadata: ${META_VIDEO_WIDTH}x${META_VIDEO_HEIGHT} ${META_VIDEO_CODEC_NORMALIZED} ${META_QUALITY_TIER}"
  log "  Video: ${META_VIDEO_BITRATE_KBPS:-?}kbps ${META_VIDEO_FRAMERATE_DEC:-?}fps ${META_VIDEO_COLOR_DEPTH}bit HDR=${META_HDR}"
  log "  Audio: ${META_AUDIO_CODEC_NORMALIZED} ${META_AUDIO_CHANNELS_STR} ${META_AUDIO_BITRATE_KBPS:-?}kbps lang=${META_AUDIO_LANGUAGES}"
  log "  Subs:  ${META_SUBTITLE_LANGUAGES:-none}"
  log "  Duration: ${META_DURATION_INT:-?}s  Size: ${META_FILE_SIZE:-?} bytes"
}

# ── Helper: hash NZB and upload to NZB-Service ──────────────────
# Calculates sha256 hash of the NZB file, then uploads it to the
# NZB-Service (openmedia-nzb) via HTTP PUT.
# Outputs the hash (used as the NzbFile identifier in the DB).
upload_nzb_to_nzb_service() {
  local nzb_file="$1"

  # Calculate sha256 hash of the NZB file
  local nzb_hash
  nzb_hash=$(sha256sum "$nzb_file" | cut -d' ' -f1)
  log "NZB hash: ${nzb_hash}"

  # Upload to NZB-Service
  local nzb_service_url="${NZB_SERVICE_URL:-https://nzb.nettoken.de}"
  local upload_url="${nzb_service_url}/files/${nzb_hash}"

  log "Uploading NZB to NZB-Service: ${upload_url}"
  local http_code
  local attempt
  local max_attempts=3

  for attempt in 1 2 3; do
    http_code=$(curl -sf -o /dev/null -w "%{http_code}" -X PUT \
      -H "Authorization: Bearer ${NZB_SERVICE_TOKEN}" \
      -H "Content-Type: application/octet-stream" \
      --data-binary "@${nzb_file}" \
      "${upload_url}" 2>/dev/null) || true

    if [[ "$http_code" == "200" || "$http_code" == "201" ]]; then
      log "NZB uploaded to NZB-Service: ${nzb_hash}"
      break
    fi

    if [[ "$attempt" -lt "$max_attempts" ]]; then
      log "WARN: NZB-Service upload attempt ${attempt}/${max_attempts} returned HTTP ${http_code} — retrying in 5s"
      sleep 5
    else
      log "ERROR: NZB-Service upload failed after ${max_attempts} attempts (last HTTP ${http_code})"
      log "ERROR: NZB file will be LOST when VPS is deleted — aborting upload"
      die "NZB-Service upload failed after ${max_attempts} attempts (HTTP ${http_code})"
    fi
  done

  # Return hash via global variable (not stdout — stdout would mix with log lines
  # when called from command substitution)
  NZB_HASH_RESULT="$nzb_hash"
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

  local ssl_flag=true
  [[ "$ssl" == "0" ]] && ssl_flag=false

  local nzb_path="${part_dir}/${hash}_provider${provider_num}.nzb"
  local conf_path="${part_dir}/nyuu_p${provider_num}.json"
  local poster_email="uploader-$(openssl rand -hex 4)@upload.local"

  log "Provider ${provider_num}: ${host}:${port} (ssl=${ssl}, conns=${conns})"
  log "  Group: ${group}"
  log "  NZB:   ${nzb_path}"

  # Generate Nyuu JSON config
  # NOTE: Nyuu does NOT support an "obfuscate" config key — it is silently ignored.
  # Real obfuscation is achieved via "subject" and "yenc-name" with ${rand(N)} tokens,
  # which randomize article subjects and yEnc filenames on Usenet.
  # "nzb-subject" preserves the original filename in the NZB file itself (only visible
  # to NZB holders, not to public indexers).
  cat > "$conf_path" << CONF
{
  "host": "${host}",
  "port": ${port},
  "ssl": ${ssl_flag},
  "user": "${user}",
  "password": "${pass}",
  "connections": ${conns},
  "groups": "${group}",
  "from": "${poster_email}",
  "subject": "\${rand(20)}",
  "yenc-name": "\${rand(15)}",
  "nzb-subject": "[{filenum}/{files}] - \"{filename}\" yEnc ({part}/{parts}) {filesize}",
  "out": "${nzb_path}",
  "overwrite": true,
  "nzb-password": "${password}",
  "check-connections": ${conns},
  "check-tries": 3
}
CONF

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

  nyuu -C "$conf_path" "${upload_files[@]}" 2>&1 | tee "$nyuu_log"

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

  local group1 group2
  read -r group1 group2 < <(select_newsgroups)
  log "Newsgroups: ${group1} / ${group2}"

  local poster_name="${POSTER_NAME:-$(generate_uuid)}"
  log "Poster name: ${poster_name}"

  local part_dir="${TMPDIR}/${JOB_HASH}"
  mkdir -p "$part_dir"

  # ── Step 1.5: Extract media metadata via ffprobe ─────────────
  extract_metadata

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
  rclone cat ":s3:${S3_BUCKET}/${S3_KEY}" \
    --s3-provider "Other" \
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

  # ── Step 4: Upload to both providers ───────────────────────────
  local providers_ok=0
  local providers_failed=0

  log "Starting Nyuu uploads to 2 providers (parallel)"

  # Run both providers in parallel
  local pid1 pid2
  local exit1=0 exit2=0

  upload_to_provider 1 \
    "${USENET_HOST_1}" "${USENET_PORT_1:-563}" \
    "${USENET_USER_1}" "${USENET_PASS_1}" \
    "${USENET_SSL_1:-1}" "${USENET_CONNS_1:-20}" \
    "$group1" "$password" "$part_dir" "$JOB_HASH" &
  pid1=$!

  upload_to_provider 2 \
    "${USENET_HOST_2}" "${USENET_PORT_2:-563}" \
    "${USENET_USER_2}" "${USENET_PASS_2}" \
    "${USENET_SSL_2:-1}" "${USENET_CONNS_2:-20}" \
    "$group2" "$password" "$part_dir" "$JOB_HASH" &
  pid2=$!

  # Wait for both and capture exit codes
  wait "$pid1" || exit1=$?
  wait "$pid2" || exit2=$?

  [[ $exit1 -eq 0 ]] && providers_ok=$((providers_ok + 1)) || providers_failed=$((providers_failed + 1))
  [[ $exit2 -eq 0 ]] && providers_ok=$((providers_ok + 1)) || providers_failed=$((providers_failed + 1))

  log "Upload results: ${providers_ok} succeeded, ${providers_failed} failed"

  if [[ $providers_ok -eq 0 ]]; then
    die "All providers failed. Upload cannot proceed."
  fi

  # ── Step 5: Combine NZBs into one ──────────────────────────────
  # Take the first successful provider's NZB as the primary.
  # Both have the same file list (just different servers/groups).
  local primary_nzb="${part_dir}/${JOB_HASH}_provider1.nzb"
  if [[ ! -f "$primary_nzb" ]]; then
    primary_nzb="${part_dir}/${JOB_HASH}_provider2.nzb"
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

  # ── Step 6: Hash NZB and upload to NZB-Service ─────────────────
  upload_nzb_to_nzb_service "$nzb_path"
  local nzb_hash="$NZB_HASH_RESULT"

  # ── Step 7: Report completion to API ───────────────────────────
  local elapsed=$(( $(date +%s) - start_time ))
  log "Total upload time: ${elapsed}s"

  # PATCH /uploads/:id with nzbHash, movieId, and media metadata.
  # movieId comes from the UploadJob — it tells the API which Movie
  # to link the new NzbFile entry to.
  local movie_id="${MOVIE_ID:-}"
  local patch_body

  # Build metadata object (only non-empty fields)
  local metadata_json="{}"
  if [[ -n "$METADATA_JSON" ]]; then
    metadata_json=$(jq -n \
      --arg qualityTier "${META_QUALITY_TIER:-}" \
      --argjson videoWidth "${META_VIDEO_WIDTH:-null}" \
      --argjson videoHeight "${META_VIDEO_HEIGHT:-null}" \
      --arg codec "${META_VIDEO_CODEC_NORMALIZED:-}" \
      --arg videoBitrate "${META_VIDEO_BITRATE_KBPS:-}" \
      --arg videoFramerate "${META_VIDEO_FRAMERATE_DEC:-}" \
      --argjson videoColorDepth "${META_VIDEO_COLOR_DEPTH:-null}" \
      --argjson hdr "${META_HDR:-false}" \
      --arg hdrFormat "${META_HDR_FORMAT:-}" \
      --arg audioCodec "${META_AUDIO_CODEC_NORMALIZED:-}" \
      --arg audioChannels "${META_AUDIO_CHANNELS_STR:-}" \
      --arg audioBitrate "${META_AUDIO_BITRATE_KBPS:-}" \
      --arg audioLanguages "${META_AUDIO_LANGUAGES:-}" \
      --arg subtitleLanguages "${META_SUBTITLE_LANGUAGES:-}" \
      --arg duration "${META_DURATION_INT:-}" \
      --arg fileSize "${META_FILE_SIZE:-}" \
      --arg resolution "${META_QUALITY_TIER:-}" \
      --argjson mediaInfo "$METADATA_JSON" \
      '{} |
        (if $qualityTier != "" then . + {qualityTier: $qualityTier} else . end) |
        (if $videoWidth != null then . + {videoWidth: $videoWidth} else . end) |
        (if $videoHeight != null then . + {videoHeight: $videoHeight} else . end) |
        (if $codec != "" then . + {codec: $codec} else . end) |
        (if $videoBitrate != "" then . + {videoBitrate: ($videoBitrate | tonumber)} else . end) |
        (if $videoFramerate != "" then . + {videoFramerate: $videoFramerate} else . end) |
        (if $videoColorDepth != null then . + {videoColorDepth: $videoColorDepth} else . end) |
        (if $hdr then . + {hdr: $hdr} else . end) |
        (if $hdrFormat != "" then . + {hdrFormat: $hdrFormat} else . end) |
        (if $audioCodec != "" then . + {audioCodec: $audioCodec} else . end) |
        (if $audioChannels != "" then . + {audioChannels: $audioChannels} else . end) |
        (if $audioBitrate != "" then . + {audioBitrate: ($audioBitrate | tonumber)} else . end) |
        (if $audioLanguages != "" then . + {audioLanguages: ($audioLanguages | split(","))} else . end) |
        (if $subtitleLanguages != "" then . + {subtitleLanguages: ($subtitleLanguages | split(","))} else . end) |
        (if $duration != "" then . + {duration: ($duration | tonumber)} else . end) |
        (if $fileSize != "" then . + {fileSize: ($fileSize | tonumber)} else . end) |
        (if $resolution != "" then . + {resolution: $resolution} else . end) |
        . + {mediaInfo: (if $fileSize != "" then ($mediaInfo | .format.size = $fileSize) else $mediaInfo end)}
      '
    ) || metadata_json="{}"
  fi

  patch_body=$(jq -n \
    --arg status "completed" \
    --arg nzbHash "$nzb_hash" \
    --arg movieId "$movie_id" \
    --argjson metadata "$metadata_json" \
    '{status: $status, nzbHash: $nzbHash} +
     (if $movieId != "" then {movieId: $movieId} else {} end) +
     (if $metadata != {} then {metadata: $metadata} else {} end)'
  )

  curl -sf -X PATCH "${API_BASE_URL}/uploads/${JOB_ID}" \
    -H "Authorization: Bearer ${SERVICE_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$patch_body" || log "WARN: API completion callback failed"

  log "API callback sent: status=completed, nzbHash=${nzb_hash}, movieId=${movie_id:-none}"

  # ── Step 8: Cleanup temp files ─────────────────────────────────
  rm -rf "$part_dir"
  log "Temp files cleaned up"

  # VPS deletion is handled by the API after PATCH /uploads/:id
  # — no Hetzner credentials needed in the container.

  log "=========================================="
  log "Upload completed successfully"
  log "Movie ID: ${movie_id:-none}"
  log "Parts:    ${part_count}"
  log "Providers: ${providers_ok}/${providers_failed}"
  log "Time:     ${elapsed}s"
  log "=========================================="
}

main "$@"
