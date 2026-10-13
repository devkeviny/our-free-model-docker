# syntax=docker/dockerfile:1
FROM node:22-bookworm-slim

LABEL maintainer="devkeviny <kevinnyfonseca@gmail.com>"
LABEL description="Private, maintainable Docker deployment of Our Free Model (Ebony-Vinyl/dsh-our-free-model)"

# Build arguments for dynamic upstream cloning and pinning
ARG UPSTREAM_REPO=https://github.com/Ebony-Vinyl/dsh-our-free-model.git
ARG UPSTREAM_REF=main
ARG CACHEBUST=1

ENV NODE_ENV=production \
    PORT=18900 \
    INTERNAL_PORT=18901 \
    OFM_HOME=/data

# Install git, curl, ca-certificates
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Clone upstream repository dynamically at build time
# Cache-busting argument ensures latest upstream commits are pulled when requested
RUN echo "Fetching upstream from ${UPSTREAM_REPO} at ref ${UPSTREAM_REF} (build token: ${CACHEBUST})..." && \
    git clone --depth 1 --branch ${UPSTREAM_REF} ${UPSTREAM_REPO} /app/upstream 2>/dev/null || \
    (git clone ${UPSTREAM_REPO} /app/upstream && cd /app/upstream && git checkout ${UPSTREAM_REF}) && \
    cd /app/upstream && \
    UPSTREAM_SHA=$(git rev-parse HEAD) && \
    echo "Cloned commit: ${UPSTREAM_SHA}" && \
    echo "${UPSTREAM_SHA}" > /app/upstream_sha.txt

# Copy our custom ingress bridge and entrypoint scripts
COPY ingress.mjs /app/ingress.mjs
COPY docker-entrypoint.sh /app/docker-entrypoint.sh
RUN chmod +x /app/docker-entrypoint.sh

# Create persistent data volume directory
RUN mkdir -p /data

WORKDIR /app/upstream

EXPOSE 18900

VOLUME ["/data"]

HEALTHCHECK --interval=20s --timeout=5s --start-period=15s --retries=3 \
    CMD curl -f http://127.0.0.1:18900/health || exit 1

ENTRYPOINT ["/app/docker-entrypoint.sh"]
