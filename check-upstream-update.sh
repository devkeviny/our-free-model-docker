#!/usr/bin/env bash
set -eo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/Ebony-Vinyl/dsh-our-free-model.git}"
TARGET_REF="${UPSTREAM_REF:-main}"

echo "========================================================"
echo " Our Free Model - Upstream Version Audit"
echo "========================================================"
echo "Target Repository: $UPSTREAM_REPO"
echo "Tracked Ref:       $TARGET_REF"
echo "--------------------------------------------------------"

# 1. Determine currently deployed commit SHA
DEPLOYED_SHA=""
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^our-free-model$"; then
    DEPLOYED_SHA=$(docker exec our-free-model cat /app/upstream_sha.txt 2>/dev/null || true)
fi

if [ -z "$DEPLOYED_SHA" ] && [ -f ".deployed_sha" ]; then
    DEPLOYED_SHA=$(cat .deployed_sha)
fi

if [ -n "$DEPLOYED_SHA" ]; then
    echo "Currently Deployed SHA:  $DEPLOYED_SHA"
else
    echo "Currently Deployed SHA:  (Container not running or not yet deployed)"
fi

# 2. Query upstream remote repository
echo -n "Fetching upstream remote SHA... "
LATEST_REMOTE_SHA=$(git ls-remote "$UPSTREAM_REPO" "refs/heads/$TARGET_REF" 2>/dev/null | awk '{print $1}')

if [ -z "$LATEST_REMOTE_SHA" ]; then
    # Try fetching as a tag or raw ref
    LATEST_REMOTE_SHA=$(git ls-remote "$UPSTREAM_REPO" "$TARGET_REF" 2>/dev/null | head -n 1 | awk '{print $1}')
fi

if [ -z "$LATEST_REMOTE_SHA" ]; then
    echo "FAILED"
    echo "Warning: Could not fetch remote ref from $UPSTREAM_REPO. Check network connectivity."
    exit 1
fi
echo "DONE"
echo "Upstream Latest SHA:     $LATEST_REMOTE_SHA"
echo "--------------------------------------------------------"

# 3. Compare and report status
if [ -z "$DEPLOYED_SHA" ]; then
    echo "Status: READY TO DEPLOY"
    echo "Initial build will clone commit $LATEST_REMOTE_SHA."
elif [ "$DEPLOYED_SHA" = "$LATEST_REMOTE_SHA" ]; then
    echo "Status: [OK] UP-TO-DATE"
    echo "Your deployment is running the exact latest commit from upstream."
else
    echo "Status: [UPDATE AVAILABLE]"
    echo "The upstream repository has new updates available!"
    echo ""
    echo "How to update:"
    echo "1. On Coolify: Click 'Redeploy' (with Clear Cache or updated CACHEBUST env)."
    echo "2. Via CLI: Run 'docker compose build --build-arg CACHEBUST=\$(date +%s) && docker compose up -d'"
fi
echo "========================================================"
