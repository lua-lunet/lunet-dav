#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
COMPOSE="docker compose -f $DIR/docker-compose.yml"
IMAGE_TAG="${DOCKER_SMOKE_IMAGE:-lunet-dav:smoke}"
CONTAINER_NAME="lunet-dav-smoke"

cleanup() {
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    if [ "${KEEP_STACK:-0}" != "1" ]; then
        $COMPOSE down --remove-orphans >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

step() { printf '\n=== docker-smoke: %s ===\n' "$*"; }

step "building image"
docker build -t "$IMAGE_TAG" "$ROOT"

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

step "RESULT: OK"
