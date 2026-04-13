FROM node:20-alpine

# ── Install core tools ──────────────────────────────────────────
# 7z (7zip) with native encryption support (-mhe=on for header encryption)
# par2cmdline for PAR2 redundancy
# rclone for S3 streaming
# curl + jq for API callbacks
# xxd for random password/UUID generation
RUN apk add --no-cache \
    p7zip \
    par2cmdline \
    rclone \
    curl \
    jq \
    bash \
    coreutils \
    xxd \
    openssl \
    ffmpeg

# ── Install Nyuu (usenet binary poster) ────────────────────────
# Nyuu needs Python + build-base for the yencode native module compilation.
# Install build deps, compile Nyuu, then remove build deps to keep image small.
RUN apk add --no-cache python3 make g++ \
 && npm install -g nyuu --production \
 && apk del --no-network --purge python3 make g++ 2>/dev/null; true

# ── Create working directory ────────────────────────────────────
RUN mkdir -p /opt/openmedia/tmp

# ── Entrypoint script: the upload pipeline ──────────────────────
COPY scripts/upload.sh /opt/openmedia/upload.sh
RUN chmod +x /opt/openmedia/upload.sh

# ── Nyuu config template ───────────────────────────────────────
COPY templates/nyuu.conf.template /opt/openmedia/nyuu.conf.template

WORKDIR /opt/openmedia
ENTRYPOINT ["/opt/openmedia/upload.sh"]
