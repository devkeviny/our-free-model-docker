FROM python:3.12-slim

LABEL maintainer="devkeviny <kevinnyfonseca@gmail.com>"
LABEL description="Smart Egress Proxy Sidecar for Our Free Model"

ENV PYTHONUNBUFFERED=1 \
    PROXY_LISTEN_HOST=0.0.0.0 \
    PROXY_LISTEN_PORT=8899 \
    PROXY_DATA_DIR=/data

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY proxy_server.py /app/proxy_server.py
RUN chmod +x /app/proxy_server.py

RUN mkdir -p /data

EXPOSE 8899

VOLUME ["/data"]

HEALTHCHECK --interval=20s --timeout=5s --start-period=5s --retries=3 \
    CMD curl -f http://127.0.0.1:8899/health || exit 1

ENTRYPOINT ["python3", "/app/proxy_server.py"]
