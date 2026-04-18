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
# IMPORTANT: --purge removes transitive dependencies and nukes ffmpeg on ARM.
# Reinstall ffmpeg after cleanup to guarantee ffprobe is available.
RUN apk add --no-cache python3 make g++ \
 && npm install -g nyuu --production \
 && apk del --no-network --purge python3 make g++ 2>/dev/null; true

# Reinstall ffmpeg — apk del --purge above can remove it as a transitive dep on ARM
RUN apk add --no-cache ffmpeg

# ── Create working directory ────────────────────────────────────
RUN mkdir -p /opt/openmedia/tmp

# ── Bootstrap script: fetches config from API at boot ────────────
COPY scripts/00-fetch-config.sh /opt/openmedia/00-fetch-config.sh
RUN chmod +x /opt/openmedia/00-fetch-config.sh

# ── Entrypoint script: the upload pipeline ──────────────────────
COPY scripts/upload.sh /opt/openmedia/upload.sh
RUN chmod +x /opt/openmedia/upload.sh

# ── Nyuu config template ───────────────────────────────────────
COPY templates/nyuu.conf.template /opt/openmedia/nyuu.conf.template

WORKDIR /opt/openmedia
ENTRYPOINT ["/opt/openmedia/upload.sh"]
