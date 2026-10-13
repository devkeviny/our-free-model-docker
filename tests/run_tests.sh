#!/usr/bin/env bash
set -eo pipefail

RED='\033[031m'
GREEN='\033[032m'
YELLOW='\033[033m'
BLUE='\033[034m'
NC='\033[0m'

PASSED_COUNT=0
FAILED_COUNT=0

log_test() {
    echo -e "\n${BLUE}========================================================${NC}"
    echo -e "${YELLOW}TEST $1: $2${NC}"
    echo -e "${BLUE}========================================================${NC}"
}

assert_success() {
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ PASS: $1${NC}"
        PASSED_COUNT=$((PASSED_COUNT + 1))
    else
        echo -e "${RED}✗ FAIL: $1${NC}"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        exit 1
    fi
}

cd /opt/data/our-free-model-docker

# ----------------------------------------------------
# TEST 1: Build Docker image from scratch
# ----------------------------------------------------
log_test "1" "Building Docker images from scratch (ARM64 Ubuntu 24.04)"
docker compose build --no-cache
assert_success "Docker images built successfully from scratch"

# ----------------------------------------------------
# TEST 2: Initialize Standalone via Docker Compose
# ----------------------------------------------------
log_test "2" "Starting services via docker compose up -d"
docker compose down -v 2>/dev/null || true
docker compose up -d
sleep 8

# Ensure containers are reachable in containerized runners (e.g. Hermes / CI)
if docker network inspect ai-agents-net >/dev/null 2>&1; then
    docker network connect ai-agents-net our-free-model 2>/dev/null || true
    docker network connect ai-agents-net our-free-model 2>/dev/null || true
    OFM_HOST="our-free-model"
else
    OFM_HOST="127.0.0.1"
fi

docker compose ps
assert_success "Services started and running"

# ----------------------------------------------------
# TEST 3: Validate Healthcheck Endpoints
# ----------------------------------------------------
log_test "3" "Validating /health on OFM standalone"
OFM_HEALTH=$(curl -s "http://${OFM_HOST}:18900/health")
echo "OFM Health: $OFM_HEALTH"
echo "$OFM_HEALTH" | grep -q '"ok":true'
assert_success "OFM standalone /health returned ok: true"

# Check embedded proxy health if running inside container
if docker exec our-free-model pgrep -f proxy_server.py >/dev/null 2>&1; then
    EMBEDDED_PROXY_HEALTH=$(docker exec our-free-model curl -s "http://127.0.0.1:8899/health" 2>/dev/null || true)
    echo "Embedded Proxy Health: $EMBEDDED_PROXY_HEALTH"
fi

# ----------------------------------------------------
# TEST 4: Validate /v1/models
# ----------------------------------------------------
log_test "4" "Validating GET /v1/models using generated API Key"
# Extract forwardKey from container volume
API_KEY=$(docker exec our-free-model node -e '
const fs = require("fs");
try {
  const cfg = JSON.parse(fs.readFileSync("/data/settings.json", "utf8"));
  console.log(cfg.forwardKey || "");
} catch { console.log(""); }
')

if [ -z "$API_KEY" ]; then
    echo "Waiting for settings.json to generate forwardKey..."
    sleep 5
    API_KEY=$(docker exec our-free-model node -e '
    const fs = require("fs");
    const cfg = JSON.parse(fs.readFileSync("/data/settings.json", "utf8"));
    console.log(cfg.forwardKey);
    ')
fi

echo "Discovered ForwardKey: ${API_KEY:0:10}..."
MODELS_RESP=$(curl -s -H "Authorization: Bearer $API_KEY" "http://${OFM_HOST}:18900/v1/models")
MODEL_COUNT=$(echo "$MODELS_RESP" | grep -o '"id":' | wc -l)
echo "Models detected count: $MODEL_COUNT"
[ "$MODEL_COUNT" -gt 0 ]
assert_success "/v1/models returned active model roster ($MODEL_COUNT models)"

# ----------------------------------------------------
# TEST 5: OpenAI-Compatible Completion Test
# ----------------------------------------------------
log_test "5" "OpenAI-compatible completion with available free model"
CHAT_PAYLOAD='{
  "model": "liquid/lfm-2.5-2.6b:free",
  "messages": [{"role": "user", "content": "Reply with only the word OK."}],
  "max_tokens": 5
}'

CHAT_RESP=$(curl -s -X POST "http://${OFM_HOST}:18900/v1/chat/completions" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d "$CHAT_PAYLOAD")

echo "Completion Response: $CHAT_RESP"
echo "$CHAT_RESP" | grep -q 'liquid/lfm-2.5-2.6b:free'
assert_success "Real OpenAI completion test succeeded on available free model"

# ----------------------------------------------------
# TEST 6: Volume Persistence Across Container Restart
# ----------------------------------------------------
log_test "6" "Testing volume persistence across container restarts"
PREV_KEY="$API_KEY"
docker compose restart ofm
sleep 6

if docker network inspect ai-agents-net >/dev/null 2>&1; then
    docker network connect ai-agents-net our-free-model 2>/dev/null || true
fi

NEW_KEY=$(docker exec our-free-model node -e '
const fs = require("fs");
const cfg = JSON.parse(fs.readFileSync("/data/settings.json", "utf8"));
console.log(cfg.forwardKey);
')

echo "Previous Key: ${PREV_KEY:0:10}..."
echo "New Key:      ${NEW_KEY:0:10}..."
[ "$PREV_KEY" = "$NEW_KEY" ]
assert_success "API Key and data volume persisted identically across restart"

# ----------------------------------------------------
# TEST 7: Initialization with Proxy Disabled
# ----------------------------------------------------
log_test "7" "Validating initialization with proxy disabled"
PROXY_STATUS=$(curl -s "http://${PROXY_HOST}:8899/status")
echo "Proxy status: $PROXY_STATUS"
echo "$PROXY_STATUS" | grep -q '"mode": "disabled"'
assert_success "Proxy sidecar properly defaults to mode: disabled"

# ----------------------------------------------------
# TEST 8: Proxy Configuration & Connectivity
# ----------------------------------------------------
log_test "8" "Testing transparent egress forwarder via proxy port"
PROXY_FWD_STATUS=$(curl -s -x "http://${PROXY_HOST}:8899" -o /dev/null -w "%{http_code}" "http://www.gstatic.com/generate_204")
echo "Egress probe via proxy returned HTTP $PROXY_FWD_STATUS"
[ "$PROXY_FWD_STATUS" = "204" ] || [ "$PROXY_FWD_STATUS" = "200" ]
assert_success "Proxy sidecar forwards egress traffic cleanly"

# ----------------------------------------------------
# TEST 9: Simulate Dead Proxy & Fallback
# ----------------------------------------------------
log_test "9" "Simulating proxy failure and verifying fallback logic"
python3 - <<'PY'
import sys
sys.path.insert(0, '/opt/data/our-free-model-docker/proxy')
from proxy_server import SmartProxyPool
import tempfile, os

with tempfile.TemporaryDirectory() as td:
    pool = SmartProxyPool(td)
    pool.all_proxies = ["http://127.0.0.1:59999", "http://127.0.0.1:59998"]
    pool.active_proxies = list(pool.all_proxies)
    
    # 1. Quarantine first dead proxy
    pool.quarantine("http://127.0.0.1:59999", reason="simulated_timeout")
    assert len(pool.active_proxies) == 1, "Failed to remove dead proxy from active"
    assert pool.get_candidate() == "http://127.0.0.1:59998", "Failover did not pick next candidate"
    
    # 2. Quarantine second dead proxy
    pool.quarantine("http://127.0.0.1:59998", reason="simulated_refusal")
    assert len(pool.active_proxies) == 0, "Pool should have 0 active proxies"
    assert pool.get_candidate() is None, "Candidate should be None when all dead"
    print("Fallback unit test: All dead proxies quarantined, candidate safely returned None for direct fallback.")
PY
assert_success "Proxy quarantine, failover and fallback logic verified"

# ----------------------------------------------------
# TEST 10: Upstream Update Simulation
# ----------------------------------------------------
log_test "10" "Simulating upstream ref pinning and cache bust build"
docker compose build --build-arg UPSTREAM_REF=ddb451c2f24bac0b0f8b03b2473efbb1f0aefb68 --build-arg CACHEBUST=test_token ofm
CLONED_SHA=$(docker run --rm --entrypoint cat our-free-model-docker:latest /app/upstream_sha.txt | tr -d '[:space:]')
echo "Pinned build cloned SHA: $CLONED_SHA"
[ "$CLONED_SHA" = "ddb451c2f24bac0b0f8b03b2473efbb1f0aefb68" ]
assert_success "Upstream ref pinning and cache busting build verified"

# ----------------------------------------------------
# TEST 11: Confirm Zero Upstream Modification
# ----------------------------------------------------
log_test "11" "Confirming upstream repository Ebony-Vinyl/dsh-our-free-model is untouched"
# Verify local our-free-model-docker git tree contains no vendor/upstream cloned files
COMMITTED_FILES=$(git ls-files)
echo "Committed/tracked files in our-free-model-docker:"
echo "$COMMITTED_FILES"
! echo "$COMMITTED_FILES" | grep -E "dsh-our-free-model|packages/standalone/service.mjs"
assert_success "Zero upstream source code committed to private wrapper repo"

echo -e "\n${GREEN}========================================================${NC}"
echo -e "${GREEN}ALL $PASSED_COUNT TESTS PASSED SUCCESSFULLY!${NC}"
echo -e "${GREEN}========================================================${NC}"
