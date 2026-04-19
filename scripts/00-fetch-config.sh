#!/bin/bash
# ─────────────────────────────────────────────────────────────────
# Bootstrap script: Fetches config from API at container start
# Called by upload.sh before ENV validation.
#
# Requires 3 ENV vars from cloud-init:
#   API_BASE_URL, SERVICE_TOKEN, JOB_ID
#
# Backward compat: if legacy ENV vars (USENET_HOST_1) are already
# set, skip API calls entirely.
# ─────────────────────────────────────────────────────────────────
set -euo pipefail

API_ENV_FILE="/opt/openmedia/api-env.sh"

# ── Backward compatibility: legacy ENV mode ──────────────────────
if [ -n "${USENET_HOST_1:-}" ]; then
  echo "[openmedia] Legacy ENV mode — skipping config-pull"
  exit 0
fi

# ── Validate required bootstrap vars ─────────────────────────────
MISSING=""
for var in API_BASE_URL SERVICE_TOKEN JOB_ID; do
  if [ -z "${!var:-}" ]; then
    MISSING="${MISSING} ${var}"
  fi
done

if [ -n "${MISSING}" ]; then
  echo "[openmedia] ERROR: Missing required bootstrap vars:${MISSING}"
  echo "[openmedia] Cannot fetch config from API — aborting"
  exit 1
fi

# ── Fetch bootstrap config from API ──────────────────────────────
BOOTSTRAP_URL="${API_BASE_URL}/service/jobs/${JOB_ID}/bootstrap"
echo "[openmedia] Fetching config from ${BOOTSTRAP_URL}"

MAX_ATTEMPTS=3
RETRY_DELAY=5
ATTEMPT=0
RESPONSE=""
HTTP_STATUS=""

while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
  ATTEMPT=$((ATTEMPT + 1))
  echo "[openmedia] Bootstrap attempt ${ATTEMPT}/${MAX_ATTEMPTS}..."

  # Capture response body and HTTP status separately
  # Note: -s (silent) but NOT -f, so we always get the response body + status
  RESPONSE=$(curl -s --connect-timeout 10 --max-time 30 -w "\n%{http_code}" \
    -H "Authorization: Bearer ${SERVICE_TOKEN}" \
    -H "Accept: application/json" \
    "${BOOTSTRAP_URL}" 2>/dev/null) && {
    HTTP_STATUS=$(echo "${RESPONSE}" | tail -1)
    RESPONSE=$(echo "${RESPONSE}" | sed '$d')
  } || {
    # curl itself failed (DNS, connection refused, timeout)
    HTTP_STATUS=$(echo "${RESPONSE}" | tail -1)
    RESPONSE=$(echo "${RESPONSE}" | sed '$d')
    if [ -z "${HTTP_STATUS}" ] || ! [[ "${HTTP_STATUS}" =~ ^[0-9]+$ ]]; then
      HTTP_STATUS="000"
    fi
  }

  if [ "${HTTP_STATUS}" = "200" ]; then
    echo "[openmedia] Bootstrap API responded 200 OK"
    break
  fi

  if [ "${HTTP_STATUS}" = "000" ]; then
    echo "[openmedia] ERROR: curl failed (API unreachable or connection error)"
  else
    echo "[openmedia] ERROR: Bootstrap API returned HTTP ${HTTP_STATUS}"
    # Extract error field only — avoid logging full response which may contain credentials
    ERROR_MSG=$(echo "${RESPONSE}" | jq -r '.error // empty' 2>/dev/null)
    if [ -n "${ERROR_MSG}" ]; then
      echo "[openmedia] Error: ${ERROR_MSG}"
    fi
  fi

  if [ $ATTEMPT -lt $MAX_ATTEMPTS ]; then
    echo "[openmedia] Retrying in ${RETRY_DELAY}s..."
    sleep $RETRY_DELAY
  fi
done

if [ "${HTTP_STATUS}" != "200" ] || [ -z "${RESPONSE}" ]; then
  echo "[openmedia] FATAL: Bootstrap failed after ${MAX_ATTEMPTS} attempts (last HTTP: ${HTTP_STATUS})"
  echo "[openmedia] Container cannot start without config — aborting"
  exit 1
fi

# ── Parse JSON response and extract config ───────────────────────
# Upload bootstrap response shape:
#   { "job": { "id", "hash", "s3Key", "movieId" },
#     "config": { "s3AccessKey", "s3SecretKey", "s3Endpoint", "s3Bucket",
#                 "nzbServiceUrl", "nzbServiceToken",
#                 "usenetProviders": [{ "host", "port", "username", "password", "ssl", "connections" }, ...] } }

JOB_HASH=$(echo "${RESPONSE}" | jq -r '.job.hash')
S3_KEY=$(echo "${RESPONSE}" | jq -r '.job.s3Key')
MOVIE_ID=$(echo "${RESPONSE}" | jq -r '.job.movieId // empty')
S3_ACCESS_KEY=$(echo "${RESPONSE}" | jq -r '.config.s3AccessKey')
S3_SECRET_KEY=$(echo "${RESPONSE}" | jq -r '.config.s3SecretKey')
S3_ENDPOINT=$(echo "${RESPONSE}" | jq -r '.config.s3Endpoint')
S3_BUCKET=$(echo "${RESPONSE}" | jq -r '.config.s3Bucket')
NZB_SERVICE_URL=$(echo "${RESPONSE}" | jq -r '.config.nzbServiceUrl')
NZB_SERVICE_TOKEN=$(echo "${RESPONSE}" | jq -r '.config.nzbServiceToken')

# Extract usenet providers array into numbered ENV vars
USENET_PROVIDER_COUNT=$(echo "${RESPONSE}" | jq '.config.usenetProviders | length')

if [ "${USENET_PROVIDER_COUNT}" = "0" ] || [ "${USENET_PROVIDER_COUNT}" = "null" ]; then
  echo "[openmedia] FATAL: Bootstrap response has no usenet providers"
  exit 1
fi

# Validate critical fields
for var_name in JOB_HASH S3_KEY S3_ACCESS_KEY S3_SECRET_KEY S3_ENDPOINT S3_BUCKET NZB_SERVICE_URL NZB_SERVICE_TOKEN; do
  eval "val=\${${var_name}}"
  if [ -z "${val}" ] || [ "${val}" = "null" ]; then
    echo "[openmedia] FATAL: Bootstrap response missing required field: ${var_name}"
    exit 1
  fi
done

# ── Write env file for downstream scripts ────────────────────────
echo "[openmedia] Writing config to ${API_ENV_FILE}"
mkdir -p "$(dirname "${API_ENV_FILE}")"

TMP_ENV_FILE="$(mktemp "$(dirname "${API_ENV_FILE}")/.api-env.sh.XXXXXX")"
trap 'rm -f "${TMP_ENV_FILE}"' EXIT
chmod 600 "${TMP_ENV_FILE}"

# Use printf %q to safely escape values for sourcing (handles $, !, quotes, etc.)
append_export() {
  local key="$1"
  local value="$2"
  printf 'export %s=%q\n' "${key}" "${value}" >> "${TMP_ENV_FILE}"
}

append_export JOB_HASH "${JOB_HASH}"
append_export S3_KEY "${S3_KEY}"
append_export MOVIE_ID "${MOVIE_ID}"
append_export S3_ACCESS_KEY "${S3_ACCESS_KEY}"
append_export S3_SECRET_KEY "${S3_SECRET_KEY}"
append_export S3_ENDPOINT "${S3_ENDPOINT}"
append_export S3_BUCKET "${S3_BUCKET}"
append_export NZB_SERVICE_URL "${NZB_SERVICE_URL}"
append_export NZB_SERVICE_TOKEN "${NZB_SERVICE_TOKEN}"

# Flatten usenet providers array into numbered ENV vars (contiguous numbering)
VALID_PROVIDER_COUNT=0
for i in $(seq 0 $((USENET_PROVIDER_COUNT - 1))); do
  HOST=$(echo "${RESPONSE}" | jq -r ".config.usenetProviders[$i].host")
  PORT=$(echo "${RESPONSE}" | jq -r ".config.usenetProviders[$i].port")
  USER=$(echo "${RESPONSE}" | jq -r ".config.usenetProviders[$i].username")
  PASS=$(echo "${RESPONSE}" | jq -r ".config.usenetProviders[$i].password")
  SSL=$(echo "${RESPONSE}" | jq -r ".config.usenetProviders[$i].ssl")
  CONNS=$(echo "${RESPONSE}" | jq -r ".config.usenetProviders[$i].connections")

  # Validate required provider fields
  if [ -z "${HOST}" ] || [ "${HOST}" = "null" ]; then
    echo "[openmedia] WARN: Provider $((i + 1)) has no host — skipping"
    continue
  fi
  if [ -z "${USER}" ] || [ "${USER}" = "null" ]; then
    echo "[openmedia] WARN: Provider $((i + 1)) has no username — skipping"
    continue
  fi

  VALID_PROVIDER_COUNT=$((VALID_PROVIDER_COUNT + 1))
  append_export "USENET_HOST_${VALID_PROVIDER_COUNT}" "${HOST}"
  append_export "USENET_PORT_${VALID_PROVIDER_COUNT}" "${PORT}"
  append_export "USENET_USER_${VALID_PROVIDER_COUNT}" "${USER}"
  append_export "USENET_PASS_${VALID_PROVIDER_COUNT}" "${PASS}"
  append_export "USENET_SSL_${VALID_PROVIDER_COUNT}" "${SSL}"
  append_export "USENET_CONNS_${VALID_PROVIDER_COUNT}" "${CONNS}"
done

if [ "${VALID_PROVIDER_COUNT}" -eq 0 ]; then
  echo "[openmedia] FATAL: No valid usenet providers after validation"
  rm -f "${TMP_ENV_FILE}"
  exit 1
fi

mv -f "${TMP_ENV_FILE}" "${API_ENV_FILE}"
trap - EXIT

echo "[openmedia] Config-pull complete"
echo "[openmedia]   Job Hash:  ${JOB_HASH:0:16}..."
echo "[openmedia]   S3 Key:    ${S3_KEY}"
echo "[openmedia]   S3 Bucket: ${S3_BUCKET}"
echo "[openmedia]   Movie ID:  ${MOVIE_ID:-none}"
echo "[openmedia]   Usenet:    ${USENET_PROVIDER_COUNT} provider(s)"
