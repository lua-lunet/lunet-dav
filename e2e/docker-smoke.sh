#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
COMPOSE="docker compose -f $DIR/docker-compose.yml"
IMAGE_TAG="${DOCKER_SMOKE_IMAGE:-lunet-dav:smoke}"
CONTAINER_NAME="lunet-dav-smoke"
BUILD_LOG="${ROOT}/target/docker-smoke-build.log"
DIGEST_FILE="${ROOT}/target/docker-smoke-digest.txt"

mkdir -p "$ROOT/target"

cleanup() {
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    if [ "${KEEP_STACK:-0}" != "1" ]; then
        $COMPOSE down --remove-orphans >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

step() { printf '\n=== docker-smoke: %s ===\n' "$*"; }

step "building image"
DOCKER_BUILDKIT=0 docker build -t "$IMAGE_TAG" "$ROOT" 2>&1 | tee "$BUILD_LOG"
docker inspect --format='{{.Id}}' "$IMAGE_TAG" > "$DIGEST_FILE"

step "starting infrastructure (postgres + minio)"
$COMPOSE up -d --wait postgres minio
$COMPOSE run --rm minio-init

step "waiting for postgres"
for _ in $(seq 1 30); do
    if PGPASSWORD=postgres psql -h 127.0.0.1 -p 55432 -U postgres -d lunet_dav -c 'SELECT 1' >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

step "applying schema"
PGPASSWORD=postgres psql -h 127.0.0.1 -p 55432 -U postgres -d lunet_dav \
    -v ON_ERROR_STOP=1 -q \
    -f "$ROOT/sql/schema.sql" \
    -f "$ROOT/sql/auth_schema.sql" \
    -f "$ROOT/sql/dav_schema.sql"

COMPOSE_NETWORK="lunet-dav-e2e_default"

step "starting lunet-dav container"
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
MINIO_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' lunet-dav-e2e-minio-1)"
POSTGRES_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' lunet-dav-e2e-postgres-1)"
docker run -d --name "$CONTAINER_NAME" \
    --network "$COMPOSE_NETWORK" \
    -e PGHOST="$POSTGRES_IP" \
    -e PGPORT=5432 \
    -e PGDATABASE=lunet_dav \
    -e PGUSER=postgres \
    -e PGPASSWORD=postgres \
    -e JWT_SECRET=e2e-only-secret-not-for-production-use \
    -e LUNET_HOST=0.0.0.0 \
    -e LUNET_PORT=8081 \
    -e DAV_INSTANCE_ID=oczn5x60nrdu \
    -e DAV_FILEID_PAD_WIDTH=8 \
    -e S3_ENDPOINT="http://${MINIO_IP}:9000" \
    -e S3_REGION=us-east-1 \
    -e S3_BUCKET=lunet-dav \
    -e S3_ACCESS_KEY_ID=minioadmin \
    -e S3_SECRET_ACCESS_KEY=minioadmin \
    -e S3_LANDING_PREFIX="_landing/" \
    -e S3_API_PROFILE=lcd \
    -p 127.0.0.1:18091:8081 \
    "$IMAGE_TAG"

HOST_URL="http://127.0.0.1:18091"

step "waiting for /health"
for _ in $(seq 1 30); do
    if curl -fsS "$HOST_URL/health" >/dev/null 2>&1; then break; fi
    sleep 0.5
done
curl -fsS "$HOST_URL/health" >/dev/null || { echo "ERROR: container /health failed"; docker logs "$CONTAINER_NAME"; exit 1; }

step "in-container lxp.lom probe"
docker exec "$CONTAINER_NAME" sh -c '
cat > /tmp/lxp-check.lua <<LUA
local lom = require("lxp.lom")
local ok, res = pcall(lom.parse, "<root><child/></root>")
if not ok then print("LXP_FAIL: " .. tostring(res)); os.exit(1) end
print("LXP_OK")
LUA
./bin/lunet-run /tmp/lxp-check.lua
' | grep -q LXP_OK || { echo "ERROR: lxp.lom probe failed in container"; exit 1; }

step "MKCOL + PROPFIND with explicit prop body (XML parse path)"
PROBE_UID="dks$(date +%s)$$"
PROBE_COL="/remote.php/dav/files/test/$PROBE_UID"
curl -fsS -u test:test -X MKCOL "$HOST_URL$PROBE_COL" >/dev/null || {
    echo "ERROR: MKCOL failed"
    docker logs "$CONTAINER_NAME" | tail -20
    exit 1
}

PROPFIND_BODY='<?xml version="1.0" encoding="UTF-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:getcontentlength/><d:displayname/><d:resourcetype/></d:prop></d:propfind>'
PROPFIND_RESP="$(mktemp)"
PROPFIND_STATUS="$(curl -s -o "$PROPFIND_RESP" -w '%{http_code}' \
    -u test:test \
    -X PROPFIND \
    -H "Depth: 0" \
    -H "Content-Type: application/xml" \
    --data-binary "$PROPFIND_BODY" \
    "$HOST_URL$PROBE_COL")"

if [ "$PROPFIND_STATUS" != "207" ]; then
    echo "ERROR: PROPFIND expected 207, got $PROPFIND_STATUS"
    cat "$PROPFIND_RESP"
    rm -f "$PROPFIND_RESP"
    docker logs "$CONTAINER_NAME" | tail -20
    exit 1
fi

if ! grep -q "getcontentlength" "$PROPFIND_RESP"; then
    echo "ERROR: PROPFIND 207 but response missing requested prop"
    cat "$PROPFIND_RESP"
    rm -f "$PROPFIND_RESP"
    exit 1
fi

rm -f "$PROPFIND_RESP"
echo "PROPFIND 207 with parseable XML: OK"

step "PUT bytes -> GET bytes identical (sha256)"
PUT_CONTENT="docker-smoke-bytes-$(date +%s)-$$"
PUT_PATH="$PROBE_COL/smoke.txt"
PUT_TMP="$(mktemp)"
curl -fsS -u test:test -X PUT --data-binary "$PUT_CONTENT" \
    -o "$PUT_TMP" -w '%{http_code}' \
    "$HOST_URL$PUT_PATH" > /dev/null || {
    echo "ERROR: PUT failed"
    rm -f "$PUT_TMP"
    docker logs "$CONTAINER_NAME" | tail -20
    exit 1
}
rm -f "$PUT_TMP"

GET_TMP="$(mktemp)"
curl -fsS -u test:test -o "$GET_TMP" "$HOST_URL$PUT_PATH" || {
    echo "ERROR: GET after PUT failed"
    rm -f "$GET_TMP"
    exit 1
}

EXPECTED_SHA="$(printf '%s' "$PUT_CONTENT" | shasum -a 256 | awk '{print $1}')"
GOT_SHA="$(shasum -a 256 "$GET_TMP" | awk '{print $1}')"
rm -f "$GET_TMP"

if [ "$EXPECTED_SHA" != "$GOT_SHA" ]; then
    echo "ERROR: PUT/GET sha256 mismatch: expected $EXPECTED_SHA, got $GOT_SHA"
    exit 1
fi
echo "PUT/GET byte verification: OK (sha256=$EXPECTED_SHA)"

step "Login Flow v2: init -> grant -> poll (appPassword present)"
LF_UID="lfsmoke$(date +%s)$$"
curl -fsS -X POST "$HOST_URL/api/users" \
    -H "Content-Type: application/json" \
    -d "{\"user\":{\"username\":\"$LF_UID\",\"email\":\"${LF_UID}@test.com\",\"password\":\"password123\"}}" \
    >/dev/null || { echo "ERROR: login-flow user create failed"; exit 1; }

INIT_RESP="$(curl -fsS -X POST "$HOST_URL/index.php/login/v2" -H "User-Agent: docker-smoke/1.0")"
LF_POLL_TOKEN="$(printf '%s' "$INIT_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['poll']['token'])")"
LF_LOGIN_TOKEN="$(printf '%s' "$INIT_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['login'].split('token=')[1])")"

if [ -z "$LF_POLL_TOKEN" ] || [ -z "$LF_LOGIN_TOKEN" ]; then
    echo "ERROR: login-flow init response missing tokens"
    echo "$INIT_RESP"
    exit 1
fi

POLL_PENDING_STATUS="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$HOST_URL/login/v2/poll" -d "token=$LF_POLL_TOKEN")"
if [ "$POLL_PENDING_STATUS" != "404" ]; then
    echo "ERROR: login-flow poll before grant expected 404, got $POLL_PENDING_STATUS"
    exit 1
fi

curl -fsS -X POST "$HOST_URL/login/v2/grant" \
    -d "token=$LF_LOGIN_TOKEN&loginName=$LF_UID&password=password123" \
    >/dev/null || { echo "ERROR: login-flow grant failed"; exit 1; }

POLL_RESP="$(mktemp)"
POLL_STATUS="$(curl -s -o "$POLL_RESP" -w '%{http_code}' -X POST "$HOST_URL/login/v2/poll" -d "token=$LF_POLL_TOKEN")"
if [ "$POLL_STATUS" != "200" ]; then
    echo "ERROR: login-flow poll after grant expected 200, got $POLL_STATUS"
    cat "$POLL_RESP"
    rm -f "$POLL_RESP"
    exit 1
fi

if ! python3 -c "import sys,json; d=json.load(open('$POLL_RESP')); assert d.get('appPassword',''), 'missing appPassword'" 2>/dev/null; then
    echo "ERROR: login-flow poll response missing appPassword"
    cat "$POLL_RESP"
    rm -f "$POLL_RESP"
    exit 1
fi
rm -f "$POLL_RESP"
echo "Login Flow v2: init->grant->poll OK (appPassword present)"

step "RESULT: OK"
