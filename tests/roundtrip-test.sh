#!/bin/bash
# ─────────────────────────────────────────────────────────────────
# openmedia-uploader: Full Roundtrip Test
#
# End-to-end proof: create test file → upload to Usenet via Docker
# → download via SABnzbd → extract password-protected 7z → verify
# byte-identity (sha256 matches).
#
# Usage: ./roundtrip-test.sh [--skip-upload] [--skip-propagation]
#
# Options:
#   --skip-upload       Skip upload phase (reuse existing NZB)
#   --skip-propagation  Skip propagation wait (use recent articles)
#
# Prerequisites:
#   - Docker with linux/amd64 emulation support
#   - .env with real Usenet provider credentials
#   - Port 18080 free for SABnzbd
#
# Environment:
#   All USENET_* vars from .env are required for upload phase.
# ─────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UPLOADER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_FILE="$SCRIPT_DIR/test-roundtrip.bin"
SHA256_FILE="$SCRIPT_DIR/test-roundtrip.sha256"
RESULTS_FILE="$SCRIPT_DIR/roundtrip-results.md"
NZB_DIR="$SCRIPT_DIR/nzb-output"
SABNZBD_DC="$SCRIPT_DIR/docker-compose.sabnzbd.yml"
SABNZBD_API="http://localhost:18080/api"
SABNZBD_KEY="9be6f773f852420e82b9200d50ac4978"
SABNZBD_COMPLETE="$SCRIPT_DIR/sabnzbd-downloads/complete"
SABNZBD_NZB_BACKUP="$SCRIPT_DIR/sabnzbd-downloads/nzb_backup"

# Test parameters
TEST_FILE_SIZE_MB=25
PROPAGATION_WAIT_MIN=10
DOWNLOAD_TIMEOUT_MIN=30
EXTRACTION_TIMEOUT_MIN=10

# Helpers
log() { echo "[$(date '+%H:%M:%S')] [ROUNDTRIP] $*"; }
die() { log "FATAL: $*" >&2; exit 1; }
elapsed() {
  local start=$1 label=$2
  local sec=$(( $(date +%s) - start ))
  log "${label}: ${sec}s ($(( sec / 60 ))m $(( sec % 60 ))s)"
  echo "$sec"
}

# ── Parse arguments ──────────────────────────────────────────────
SKIP_UPLOAD=false
SKIP_PROPAGATION=false
for arg in "$@"; do
  case "$arg" in
    --skip-upload) SKIP_UPLOAD=true ;;
    --skip-propagation) SKIP_PROPAGATION=true ;;
    *) die "Unknown argument: $arg" ;;
  esac
done

# ── Load environment ─────────────────────────────────────────────
if [[ -f "$UPLOADER_DIR/.env" ]]; then
  set -a
  source "$UPLOADER_DIR/.env"
  set +a
  log "Loaded .env from $UPLOADER_DIR"
else
  die "No .env found at $UPLOADER_DIR"
fi

# ── Phase 1: Prepare test file ───────────────────────────────────
log "=========================================="
log "Phase 1: Prepare test file"
log "=========================================="

PHASE1_START=$(date +%s)

if [[ ! -f "$TEST_FILE" ]]; then
  log "Creating ${TEST_FILE_SIZE_MB}MB test file: $TEST_FILE"
  dd if=/dev/urandom of="$TEST_FILE" bs=1M count="$TEST_FILE_SIZE_MB" status=progress
else
  log "Test file already exists: $TEST_FILE ($(du -h "$TEST_FILE" | cut -f1))"
fi

ORIGINAL_SHA256=$(sha256sum "$TEST_FILE" | cut -d' ' -f1)
echo "$ORIGINAL_SHA256  $(basename "$TEST_FILE")" > "$SHA256_FILE"
log "Original SHA256: $ORIGINAL_SHA256"

PHASE1_SEC=$(elapsed "$PHASE1_START" "Phase 1")

# ── Phase 2: Upload to Usenet ────────────────────────────────────
log "=========================================="
log "Phase 2: Upload to Usenet"
log "=========================================="

PHASE2_START=$(date +%s)
JOB_HASH="roundtrip-$(date +%s)"
NZB_OUTPUT_DIR="$SCRIPT_DIR/tmp-roundtrip/$JOB_HASH"

if [[ "$SKIP_UPLOAD" == true ]]; then
  log "Skipping upload (--skip-upload). Looking for existing NZB..."
  # Try to find the most recent NZB in nzb-output or tmp-roundtrip
  NZB_FILE=$(find "$SCRIPT_DIR" -name "*.nzb" -newer "$TEST_FILE" -type f 2>/dev/null | head -1)
  if [[ -z "$NZB_FILE" ]]; then
    NZB_FILE=$(find "$NZB_DIR" -name "*.nzb" -type f 2>/dev/null | head -1)
  fi
  if [[ -z "$NZB_FILE" ]]; then
    die "No NZB file found for --skip-upload"
  fi
  log "Using existing NZB: $NZB_FILE"
else
  # Create a test-specific upload script that reads from local file
  # instead of S3 (since S3 creds may be dummy in test .env)
  TEST_UPLOAD_SCRIPT="$SCRIPT_DIR/tmp-roundtrip/upload-test.sh"
  mkdir -p "$(dirname "$TEST_UPLOAD_SCRIPT")"

  log "Creating test upload script (local file, no S3)"
  cat > "$TEST_UPLOAD_SCRIPT" << 'UPLOAD_EOF'
#!/bin/bash
# Test upload script: same as upload.sh but reads from local file
# instead of streaming from S3 via rclone.
set -euo pipefail

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { log "FATAL: $*" >&2; exit 1; }

PART_SIZE="250m"
PAR2_REDUNDANCY="30"
TMPDIR="/opt/openmedia/tmp"

select_newsgroups() {
  local indices
  indices=$(shuf -i 0-$((${#NEWSGROUP_POOL[@]}-1)) -n 2)
  local groups=()
  for i in $indices; do groups+=("${NEWSGROUP_POOL[$i]}"); done
  echo "${groups[0]}" "${groups[1]}"
}

NEWSGROUP_POOL=(
  "alt.binaries.misc" "alt.binaries.flowed" "alt.binaries.iso"
  "alt.binaries.test" "alt.binaries.a51" "alt.binaries.mom"
  "alt.binaries.bloaf" "alt.binaries.boneless" "alt.binaries.multimedia"
)

JOB_HASH="${JOB_HASH:?}"
LOCAL_FILE="${LOCAL_FILE:?}"
PASSWORD="${PASSWORD:?}"
TMPDIR="${TMPDIR:-/opt/openmedia/tmp}"

part_dir="${TMPDIR}/${JOB_HASH}"
mkdir -p "$part_dir"

# ── 7z compression with split + header encryption ──────────────
log "Starting 7z compression (parts=${PART_SIZE}, header-encrypted)"
7z a "${part_dir}/${JOB_HASH}.7z" \
  -p"${PASSWORD}" \
  -mhe=on \
  -mx0 \
  -v"${PART_SIZE}" \
  -t7z \
  "${LOCAL_FILE}"

part_count=$(find "$part_dir" -name "${JOB_HASH}.7z.*" | wc -l)
log "7z done: ${part_count} parts"

# ── PAR2 generation ────────────────────────────────────────────
log "Generating PAR2 (redundancy=${PAR2_REDUNDANCY}%)"
par2create -r"${PAR2_REDUNDANCY}" -q \
  "${part_dir}/${JOB_HASH}.par2" "${part_dir}/${JOB_HASH}.7z."*
par2_count=$(find "$part_dir" \( -name "${JOB_HASH}.par2" -o -name "${JOB_HASH}.vol*.par2" \) | wc -l)
log "PAR2 done: ${par2_count} files"

# ── Upload to providers via Nyuu ──────────────────────────────
upload_to_provider() {
  local pnum="$1" host="$2" port="${3:-563}" user="$4" pass="$5"
  local ssl="${6:-1}" conns="${7:-10}" group="$8" pw="$9" pdir="${10}" hash="${11}"
  local ssl_flag=true; [[ "$ssl" == "0" ]] && ssl_flag=false
  local nzb_path="${pdir}/${hash}_provider${pnum}.nzb"
  local conf_path="${pdir}/nyuu_p${pnum}.json"
  local poster_email="uploader-$(openssl rand -hex 4)@upload.local"
  log "Provider ${pnum}: ${host}:${port} (ssl=${ssl_flag}, conns=${conns}, group=${group})"

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
  "nzb-password": "${pw}",
  "check-connections": 0,
  "ssl-ciphers": "AES128-GCM-SHA256",
  "post-chunk-size": 0
}
CONF

  local upload_files=()
  while IFS= read -r -d '' file; do upload_files+=("$file"); done < <(
    find "$pdir" -maxdepth 1 \( -name "${hash}.7z.*" -o -name "${hash}.par2" -o -name "${hash}.vol*.par2" \) -print0 | sort -z
  )
  log "  Uploading ${#upload_files[@]} files to provider ${pnum}"
  nyuu -C "$conf_path" "${upload_files[@]}" 2>&1 | tee "${pdir}/nyuu_provider${pnum}.log" || {
    log "WARN: Provider ${pnum} failed"; return 1;
  }
  log "Provider ${pnum}: upload complete"
  return 0
}

# ── Upload to both providers ───────────────────────────────────
group1="" group2=""
read -r group1 group2 < <(select_newsgroups)
log "Newsgroups: ${group1} / ${group2}"

providers_ok=0
for p in 1 2; do
  host_var="USENET_HOST_${p}"; port_var="USENET_PORT_${p:-563}"
  user_var="USENET_USER_${p}"; pass_var="USENET_PASS_${p}"
  ssl_var="USENET_SSL_${p:-1}"; conns_var="USENET_CONNS_${p:-10}"
  if upload_to_provider "$p" \
    "${!host_var}" "${!port_var:-563}" \
    "${!user_var}" "${!pass_var}" \
    "${!ssl_var:-1}" "${!conns_var:-10}" \
    "$(eval echo \"\$group${p}\")" "$PASSWORD" "$part_dir" "$JOB_HASH"; then
    providers_ok=$((providers_ok + 1))
  fi
done

log "Upload results: ${providers_ok}/2 providers succeeded"
[[ $providers_ok -eq 0 ]] && die "All providers failed"

# Copy the first successful NZB as primary
for p in 1 2; do
  nzb="${part_dir}/${JOB_HASH}_provider${p}.nzb"
  if [[ -f "$nzb" ]]; then
    cp "$nzb" "${part_dir}/${JOB_HASH}.nzb"
    log "Primary NZB: ${part_dir}/${JOB_HASH}.nzb"
    break
  fi
done
UPLOAD_EOF
  chmod +x "$TEST_UPLOAD_SCRIPT"

  # Generate password
  PASSWORD=$(openssl rand -base64 18 | tr -d '/+=' | head -c 24)
  log "Generated password for this run: (hidden, length=${#PASSWORD})"

  # Run the upload container
  mkdir -p "$NZB_OUTPUT_DIR"

  log "Running upload container (platform=linux/amd64)..."
  log "  JOB_HASH=$JOB_HASH"
  log "  File will be mounted at /data/test-roundtrip.bin"

  # We need to run the upload inside the container.
  # Mount: test file at /data/test-roundtrip.bin, upload script, and tmp dir
  docker run --rm \
    --platform linux/amd64 \
    -e JOB_HASH="$JOB_HASH" \
    -e LOCAL_FILE="/data/test-roundtrip.bin" \
    -e PASSWORD="$PASSWORD" \
    -e "USENET_HOST_1=${USENET_HOST_1}" \
    -e "USENET_PORT_1=${USENET_PORT_1:-563}" \
    -e "USENET_USER_1=${USENET_USER_1}" \
    -e "USENET_PASS_1=${USENET_PASS_1}" \
    -e "USENET_SSL_1=${USENET_SSL_1:-1}" \
    -e "USENET_CONNS_1=${USENET_CONNS_1:-10}" \
    -e "USENET_HOST_2=${USENET_HOST_2}" \
    -e "USENET_PORT_2=${USENET_PORT_2:-563}" \
    -e "USENET_USER_2=${USENET_USER_2}" \
    -e "USENET_PASS_2=${USENET_PASS_2}" \
    -e "USENET_SSL_2=${USENET_SSL_2:-1}" \
    -e "USENET_CONNS_2=${USENET_CONNS_2:-10}" \
    -v "$TEST_FILE:/data/test-roundtrip.bin:ro" \
    -v "$TEST_UPLOAD_SCRIPT:/opt/openmedia/upload-test.sh:ro" \
    -v "$NZB_OUTPUT_DIR:/opt/openmedia/tmp" \
    --entrypoint /bin/bash \
    openmedia-uploader:roundtrip-test \
    -c '/opt/openmedia/upload-test.sh 2>&1' \
    2>&1 | tee "$NZB_OUTPUT_DIR/container.log"

  UPLOAD_EXIT=${PIPESTATUS[0]}
  if [[ $UPLOAD_EXIT -ne 0 ]]; then
    log "Upload container exited with code $UPLOAD_EXIT"
    # Check if any NZB was produced despite errors
  fi

  # Find the generated NZB
  NZB_FILE=$(find "$NZB_OUTPUT_DIR" -name "${JOB_HASH}.nzb" -type f 2>/dev/null | head -1)
  if [[ -z "$NZB_FILE" ]]; then
    # Try provider NZBs
    NZB_FILE=$(find "$NZB_OUTPUT_DIR" -name "${JOB_HASH}_provider*.nzb" -type f 2>/dev/null | head -1)
  fi
  if [[ -z "$NZB_FILE" ]]; then
    die "No NZB file produced by upload container"
  fi

  # Copy NZB to accessible location
  mkdir -p "$NZB_DIR"
  cp "$NZB_FILE" "$NZB_DIR/roundtrip-${JOB_HASH}.nzb"
  NZB_FILE="$NZB_DIR/roundtrip-${JOB_HASH}.nzb"

  log "NZB produced: $NZB_FILE ($(stat -f%z "$NZB_FILE" 2>/dev/null || stat -c%s "$NZB_FILE") bytes)"

  # Save password for this run
  echo "$PASSWORD" > "$NZB_DIR/roundtrip-${JOB_HASH}.password"
  log "Password saved to $NZB_DIR/roundtrip-${JOB_HASH}.password"

  # Verify NZB has password meta tag
  if grep -q 'meta type="password"' "$NZB_FILE"; then
    log "NZB contains <meta type=\"password\"> tag ✅"
  else
    log "WARNING: NZB does NOT contain password meta tag ❌"
  fi
fi

PHASE2_SEC=$(elapsed "$PHASE2_START" "Phase 2 (upload)")

# ── Phase 3: Wait for propagation ────────────────────────────────
log "=========================================="
log "Phase 3: Wait for Usenet propagation"
log "=========================================="

PHASE3_START=$(date +%s)

if [[ "$SKIP_PROPAGATION" == true ]]; then
  log "Skipping propagation wait (--skip-propagation)"
else
  PROPAGATION_SEC=$(( PROPAGATION_WAIT_MIN * 60 ))
  log "Waiting ${PROPAGATION_WAIT_MIN} minutes for articles to propagate..."
  for i in $(seq 1 "$PROPAGATION_WAIT_MIN"); do
    log "  Propagation wait: ${i}/${PROPAGATION_WAIT_MIN} minutes"
    sleep 60
  done
  log "Propagation wait complete"
fi

PHASE3_SEC=$(elapsed "$PHASE3_START" "Phase 3 (propagation)")

# ── Phase 4: Download via SABnzbd ────────────────────────────────
log "=========================================="
log "Phase 4: Download via SABnzbd"
log "=========================================="

PHASE4_START=$(date +%s)

# Start SABnzbd
log "Starting SABnzbd..."
cd "$SCRIPT_DIR"
docker compose -f "$SABNZBD_DC" up -d 2>&1

# Wait for SABnzbd to be ready
log "Waiting for SABnzbd to start..."
for i in $(seq 1 30); do
  if curl -sf "${SABNZBD_API}?mode=version&output=json&apikey=${SABNZBD_KEY}" >/dev/null 2>&1; then
    SAB_VERSION=$(curl -sf "${SABNZBD_API}?mode=version&output=json&apikey=${SABNZBD_KEY}" 2>/dev/null | jq -r '.version' 2>/dev/null || echo "unknown")
    log "SABnzbd ready (version: ${SAB_VERSION})"
    break
  fi
  if [[ $i -eq 30 ]]; then
    die "SABnzbd did not start within 30 seconds"
  fi
  sleep 1
done

# Clean up old downloads to avoid confusion
log "Cleaning up old SABnzbd downloads..."
curl -sf "${SABNZBD_API}?mode=history&output=json&apikey=${SABNZBD_KEY}" 2>/dev/null | \
  jq -r '.history.slots[]?.nzo_id // empty' 2>/dev/null | while read -r nzo_id; do
  curl -sf "${SABNZBD_API}?mode=history&name=delete&del_files=1&value=${nzo_id}&output=json&apikey=${SABNZBD_KEY}" >/dev/null 2>&1 || true
done

# Remove old completed files
rm -rf "$SABNZBD_COMPLETE"/* 2>/dev/null || true
rm -rf "$SABNZBD_NZB_BACKUP"/* 2>/dev/null || true

# Submit NZB to SABnzbd
log "Submitting NZB to SABnzbd: $NZB_FILE"
NZB_BASENAME=$(basename "$NZB_FILE")

# Copy NZB to SABnzbd's nzb_backup dir for local file submission
cp "$NZB_FILE" "$SABNZBD_NZB_BACKUP/$NZB_BASENAME"

# Submit via API (use nzbname to set a clear job name)
JOB_NAME="roundtrip-${JOB_HASH}"
SUBMIT_RESULT=$(curl -sf "${SABNZBD_API}?mode=addlocalfile&name=/downloads/nzb_backup/${NZB_BASENAME}&nzbname=${JOB_NAME}&pp=3&output=json&apikey=${SABNZBD_KEY}" 2>&1)
log "Submit result: $SUBMIT_RESULT"

NZO_ID=$(echo "$SUBMIT_RESULT" | jq -r '.nzo_ids[0] // empty' 2>/dev/null)
if [[ -z "$NZO_ID" ]]; then
  # Try alternate submission: base64 encode
  log "Trying base64 NZB submission..."
  NZB_B64=$(base64 < "$NZB_FILE")
  SUBMIT_RESULT=$(curl -sf "${SABNZBD_API}?mode=addfile&output=json&apikey=${SABNZBD_KEY}" \
    -F "nzbfile=@${NZB_FILE};filename=${NZB_BASENAME}" 2>&1)
  log "Submit result: $SUBMIT_RESULT"
  NZO_ID=$(echo "$SUBMIT_RESULT" | jq -r '.nzo_ids[0] // empty' 2>/dev/null)
fi

if [[ -z "$NZO_ID" ]]; then
  die "Failed to submit NZB to SABnzbd"
fi
log "SABnzbd job ID: $NZO_ID"

# Monitor download progress
DOWNLOAD_TIMEOUT_SEC=$(( DOWNLOAD_TIMEOUT_MIN * 60 ))
DOWNLOAD_START=$(date +%s)
DOWNLOAD_COMPLETE=false

log "Monitoring download (timeout: ${DOWNLOAD_TIMEOUT_MIN}m)..."
while true; do
  NOW=$(date +%s)
  ELAPSED=$(( NOW - DOWNLOAD_START ))
  if [[ $ELAPSED -gt $DOWNLOAD_TIMEOUT_SEC ]]; then
    log "Download timeout after ${DOWNLOAD_TIMEOUT_MIN} minutes"
    break
  fi

  # Check queue (active downloads)
  QUEUE=$(curl -sf "${SABNZBD_API}?mode=queue&output=json&apikey=${SABNZBD_KEY}" 2>/dev/null)
  QUEUE_STATUS=$(echo "$QUEUE" | jq -r '.queue.status // "unknown"' 2>/dev/null)
  QUEUE_SLOTS=$(echo "$QUEUE" | jq '.queue.slots | length' 2>/dev/null)

  if [[ "$QUEUE_SLOTS" == "0" ]]; then
    # Check history for our job
    HISTORY=$(curl -sf "${SABNZBD_API}?mode=history&output=json&apikey=${SABNZBD_KEY}" 2>/dev/null)
    JOB_STATUS=$(echo "$HISTORY" | jq -r ".history.slots[] | select(.nzo_id == \"$NZO_ID\") | .status" 2>/dev/null | head -1)

    if [[ -n "$JOB_STATUS" ]]; then
      log "Job status: $JOB_STATUS (after ${ELAPSED}s)"

      if [[ "$JOB_STATUS" == "Completed" ]]; then
        DOWNLOAD_COMPLETE=true
        log "Download + extraction completed ✅"
        break
      elif [[ "$JOB_STATUS" == "Failed" ]]; then
        FAIL_MSG=$(echo "$HISTORY" | jq -r ".history.slots[] | select(.nzo_id == \"$NZO_ID\") | .fail_message" 2>/dev/null | head -1)
        log "Job FAILED: $FAIL_MSG"
        break
      fi
    fi
  else
    # Still downloading
    PROGRESS=$(echo "$QUEUE" | jq -r '.queue.slots[0] | "\(.filename): \(.status) \(.sizeleft) / \(.size)"' 2>/dev/null)
    log "  Downloading: $PROGRESS"
  fi

  sleep 5
done

PHASE4_SEC=$(elapsed "$PHASE4_START" "Phase 4 (download)")

# ── Phase 5: Verify byte-identity ────────────────────────────────
log "=========================================="
log "Phase 5: Verify byte-identity"
log "=========================================="

PHASE5_START=$(date +%s)

# Find the extracted file
EXTRACTED_FILE=$(find "$SABNZBD_COMPLETE" -type f -name "*.bin" -o -name "*.mkv" -o -name "*.mp4" -o -name "roundtrip*" 2>/dev/null | head -1)

if [[ -z "$EXTRACTED_FILE" ]]; then
  # Look for any file in complete dir
  EXTRACTED_FILE=$(find "$SABNZBD_COMPLETE" -type f ! -name "*.nzb" 2>/dev/null | head -1)
fi

if [[ -z "$EXTRACTED_FILE" ]]; then
  log "No extracted file found in $SABNZBD_COMPLETE"
  log "Contents of complete dir:"
  find "$SABNZBD_COMPLETE" -type f 2>/dev/null | while read -r f; do log "  $f"; done

  # Check for _FAILED_ prefix
  FAILED_DIR=$(find "$SABNZBD_COMPLETE" -maxdepth 1 -name "_FAILED_*" -type d 2>/dev/null | head -1)
  if [[ -n "$FAILED_DIR" ]]; then
    log "Found FAILED directory: $FAILED_DIR"
    find "$FAILED_DIR" -type f 2>/dev/null | while read -r f; do log "  $f"; done
  fi

  VERDICT="FAIL"
  FAIL_REASON="No extracted file found"
else
  log "Found extracted file: $EXTRACTED_FILE"
  log "Extracted file size: $(du -h "$EXTRACTED_FILE" | cut -f1)"

  EXTRACTED_SHA256=$(sha256sum "$EXTRACTED_FILE" | cut -d' ' -f1)
  log "Extracted SHA256: $EXTRACTED_SHA256"
  log "Original  SHA256: $ORIGINAL_SHA256"

  if [[ "$EXTRACTED_SHA256" == "$ORIGINAL_SHA256" ]]; then
    VERDICT="PASS"
    log "✅ SHA256 MATCH — byte-identical! Pipeline proven!"
  else
    VERDICT="FAIL"
    FAIL_REASON="SHA256 mismatch: original=$ORIGINAL_SHA256 extracted=$EXTRACTED_SHA256"
    log "❌ SHA256 MISMATCH"
    log "  Original:  $ORIGINAL_SHA256"
    log "  Extracted: $EXTRACTED_SHA256"
  fi
fi

PHASE5_SEC=$(elapsed "$PHASE5_START" "Phase 5 (verification)")

# ── Phase 6: Get SABnzbd history details ─────────────────────────
log "=========================================="
log "Phase 6: SABnzbd history details"
log "=========================================="

HISTORY=$(curl -sf "${SABNZBD_API}?mode=history&output=json&apikey=${SABNZBD_KEY}" 2>/dev/null)
JOB_DETAILS=$(echo "$HISTORY" | jq ".history.slots[] | select(.nzo_id == \"$NZO_ID\")" 2>/dev/null)

if [[ -n "$JOB_DETAILS" ]]; then
  log "SABnzbd job details:"
  echo "$JOB_DETAILS" | jq '{status, name, size, download_time, postproc_time, fail_message, stage_log}' 2>/dev/null | while read -r line; do log "  $line"; done
fi

# ── Document results ─────────────────────────────────────────────
log "=========================================="
log "Writing results to $RESULTS_FILE"
log "=========================================="

TOTAL_SEC=$(( PHASE1_SEC + PHASE2_SEC + PHASE3_SEC + PHASE4_SEC + PHASE5_SEC ))

cat > "$RESULTS_FILE" << EOF
# Roundtrip Test Results

**Date:** $(date '+%Y-%m-%d %H:%M:%S')
**Verdict:** ${VERDICT}

## Test Configuration

| Parameter | Value |
|-----------|-------|
| Test file | $(basename "$TEST_FILE") |
| File size | ${TEST_FILE_SIZE_MB}MB |
| Job hash | ${JOB_HASH} |
| NZB file | $(basename "$NZB_FILE" 2>/dev/null || echo "N/A") |
| SABnzbd version | ${SAB_VERSION:-unknown} |
| Docker platform | linux/amd64 |

## Timing

| Phase | Duration |
|-------|----------|
| Phase 1: Prepare test file | ${PHASE1_SEC}s |
| Phase 2: Upload to Usenet | ${PHASE2_SEC}s |
| Phase 3: Propagation wait | ${PHASE3_SEC}s |
| Phase 4: Download via SABnzbd | ${PHASE4_SEC}s |
| Phase 5: Verify byte-identity | ${PHASE5_SEC}s |
| **Total** | **${TOTAL_SEC}s** |

## SHA256 Verification

| File | SHA256 |
|------|--------|
| Original | \`${ORIGINAL_SHA256}\` |
| Extracted | \`${EXTRACTED_SHA256:-N/A}\` |
| **Match** | **$([[ "$EXTRACTED_SHA256" == "$ORIGINAL_SHA256" ]] && echo "✅ YES" || echo "❌ NO")** |

## Upload Details

- NZB file: $(basename "$NZB_FILE" 2>/dev/null || echo "N/A")
- NZB size: $(stat -f%z "$NZB_FILE" 2>/dev/null || stat -c%s "$NZB_FILE" 2>/dev/null || echo "N/A") bytes
- Password meta tag: $(grep -q 'meta type="password"' "$NZB_FILE" 2>/dev/null && echo "✅ Present" || echo "❌ Missing")

## SABnzbd Download Details

$(if [[ -n "$JOB_DETAILS" ]]; then
  echo '```json'
  echo "$JOB_DETAILS" | jq '{status, name, size, download_time, postproc_time, fail_message}' 2>/dev/null || echo "Error parsing details"
  echo '```'
else
  echo "No SABnzbd job details available"
fi)

## Result

$(if [[ "$VERDICT" == "PASS" ]]; then
  echo "**✅ PASS — Pipeline proven end-to-end!**"
  echo ""
  echo "The full roundtrip completed successfully:"
  echo "1. Test file created (${TEST_FILE_SIZE_MB}MB random data)"
  echo "2. Uploaded to Usenet via Nyuu (obfuscated subjects + yEnc names)"
  echo "3. Downloaded via SABnzbd"
  echo "4. Extracted password-protected 7z archive (password from NZB meta tag)"
  echo "5. **SHA256 of extracted file matches original — byte-identical**"
else
  echo "**❌ FAIL — Pipeline test failed**"
  echo ""
  echo "Failure reason: ${FAIL_REASON:-unknown}"
  echo ""
  echo "### Investigation Notes"
  echo ""
  echo "- Check SABnzbd history for error details"
  echo "- Verify articles have propagated (may need longer wait)"
  echo "- Check NZB file for correct password meta tag"
  echo "- Verify all Nyuu uploads succeeded"
fi)

## Environment

- Upload image: openmedia-uploader:roundtrip-test (rebuilt with T01 obfuscation fix)
- SABnzbd: lscr.io/linuxserver/sabnzbd:latest
- S3 bypass: test file mounted directly (no S3 dependency for this test)
- Providers: EasyUsenet (Abavia), Eweka (Omicron)
EOF

log "Results written to $RESULTS_FILE"

# ── Cleanup ──────────────────────────────────────────────────────
log "=========================================="
log "Cleanup"
log "=========================================="

# Stop SABnzbd
cd "$SCRIPT_DIR"
docker compose -f "$SABNZBD_DC" down 2>&1 || true
log "SABnzbd stopped"

# Print final verdict
echo ""
log "=========================================="
if [[ "$VERDICT" == "PASS" ]]; then
  log "✅ ROUNDTRIP TEST PASSED"
else
  log "❌ ROUNDTRIP TEST FAILED"
fi
log "=========================================="
log "Results: $RESULTS_FILE"
echo ""

exit $([[ "$VERDICT" == "PASS" ]] && echo 0 || echo 1)
