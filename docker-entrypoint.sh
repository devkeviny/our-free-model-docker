#!/usr/bin/env bash
set -eo pipefail

DATA_DIR="${OFM_HOME:-/data}"
PORT="${PORT:-18900}"
INTERNAL_PORT="${INTERNAL_PORT:-18901}"

# Allow passing custom commands directly (e.g. docker run --rm img cat /app/upstream_sha.txt)
if [ "$#" -gt 0 ] && [ "$1" != "start" ] && [ "$1" != "--port" ]; then
    exec "$@"
fi

export PORT="$PORT"
export INTERNAL_PORT="$INTERNAL_PORT"
export OFM_HOME="$DATA_DIR"

echo "=== Starting Our Free Model Standalone Container ==="
echo "Data Directory: $DATA_DIR"
echo "External Port:  $PORT"
echo "Internal Port:  $INTERNAL_PORT"

if [ -f "/app/upstream_sha.txt" ]; then
    echo "Upstream Ref SHA: $(cat /app/upstream_sha.txt)"
fi

# Ensure data directory exists
mkdir -p "$DATA_DIR"

# Clean up stale lock file if left over from an ungraceful restart
LOCK_FILE="$DATA_DIR/service.lock"
if [ -f "$LOCK_FILE" ]; then
    echo "[init] Stale service.lock detected. Removing to allow clean startup..."
    rm -f "$LOCK_FILE"
fi

# Configure proxy environment if provided
if [ -n "$EGRESS_PROXY_URL" ]; then
    echo "[init] Configuring egress proxy: $EGRESS_PROXY_URL"
    export HTTP_PROXY="$EGRESS_PROXY_URL"
    export HTTPS_PROXY="$EGRESS_PROXY_URL"
    export ALL_PROXY="$EGRESS_PROXY_URL"
fi

# Build CLI arguments
CLI_ARGS=("--port" "$INTERNAL_PORT" "--data-dir" "$DATA_DIR")

if [ "${OFM_NO_REFRESH}" = "true" ] || [ "${OFM_NO_REFRESH}" = "1" ]; then
    echo "[init] Flag --no-refresh enabled."
    CLI_ARGS+=("--no-refresh")
fi

if [ "${OFM_PROBE}" = "true" ] || [ "${OFM_PROBE}" = "1" ]; then
    echo "[init] Flag --probe enabled."
    CLI_ARGS+=("--probe")
fi

# Start Our Free Model Standalone
echo "[init] Launching packages/standalone/cli.mjs on 127.0.0.1:$INTERNAL_PORT..."
node packages/standalone/cli.mjs "${CLI_ARGS[@]}" &
OFM_PID=$!

# Trap signals for graceful shutdown
cleanup() {
    echo "[shutdown] Received signal, stopping processes..."
    if [ -n "$INGRESS_PID" ] && kill -0 "$INGRESS_PID" 2>/dev/null; then
        kill -TERM "$INGRESS_PID" 2>/dev/null || true
    fi
    if [ -n "$OFM_PID" ] && kill -0 "$OFM_PID" 2>/dev/null; then
        kill -TERM "$OFM_PID" 2>/dev/null || true
    fi
    wait "$OFM_PID" 2>/dev/null || true
    rm -f "$LOCK_FILE"
    echo "[shutdown] Clean exit complete."
    exit 0
}
trap cleanup SIGTERM SIGINT

# Wait for standalone internal service to be ready
echo "[init] Waiting for internal standalone service readiness on 127.0.0.1:$INTERNAL_PORT/health..."
MAX_TRIES=30
COUNT=0
READY=false
while [ $COUNT -lt $MAX_TRIES ]; do
    if curl -s -f "http://127.0.0.1:$INTERNAL_PORT/health" >/dev/null 2>&1; then
        READY=true
        break
    fi
    sleep 1
    COUNT=$((COUNT + 1))
done

if [ "$READY" = "false" ]; then
    echo "[error] Standalone service failed to respond on internal port within 30s."
    kill -TERM "$OFM_PID" 2>/dev/null || true
    exit 1
fi

echo "[init] Standalone internal service is healthy!"

# Start Ingress Reverse Proxy
echo "[init] Starting ingress reverse proxy on 0.0.0.0:$PORT..."
node /app/ingress.mjs &
INGRESS_PID=$!

# Monitor child processes
wait -n "$OFM_PID" "$INGRESS_PID" || true
cleanup
