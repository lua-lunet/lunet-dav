#!/usr/bin/env bash
# Fully automated e2e run for lunet-dav.
#
#   1. Starts ephemeral Postgres 16 + MinIO (versioned bucket) via docker compose
#      (pull-only arm64 images, no mounts, no BuildKit — see e2e/docker-compose.yml).
#   2. Applies the schema and starts the lunet-dav server on a high loopback port.
#   3. Runs the in-repo compatibility suites (chassis + DAV + OCS + Login Flow v2).
#   4. Tears everything down, leaving no containers or server processes behind.
#
# Usage:  bash e2e/run-e2e.sh            (or `make e2e`)
#         KEEP_STACK=1 bash e2e/run-e2e.sh   # skip teardown for manual poking
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
COMPOSE="docker compose -f $DIR/docker-compose.yml"
PID_FILE="$ROOT/target/lunet-e2e.pid"
LOG_FILE="$ROOT/target/e2e-server.log"

# Export the entire e2e environment (set -a) so the server child process and
# psql both see it. NB: `make start` sources .env WITHOUT exporting, which is
# why this script manages its own server lifecycle.
set -a
# shellcheck source=e2e.env
. "$DIR/e2e.env"
set +a

FAILED=0

stop_server() {
    local pid
    [ -f "$PID_FILE" ] || return 0
    pid="$(cat "$PID_FILE")"
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        for _ in $(seq 1 10); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.5
        done
        kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
    # Backstop: lunet-run forks once at startup, so a stale pid file can name
    # the exited parent. Reap whatever still holds our port.
    local port_pid
    port_pid="$(lsof -nP -tiTCP:"$LUNET_PORT" -sTCP:LISTEN 2>/dev/null || true)"
    if [ -n "$port_pid" ] && ps -o command= -p "$port_pid" 2>/dev/null | grep -q "lunet-run"; then
        kill "$port_pid" 2>/dev/null || true
        sleep 1
        kill -9 "$port_pid" 2>/dev/null || true
    fi
}

cleanup() {
    stop_server
    if [ "${KEEP_STACK:-0}" != "1" ]; then
        $COMPOSE down --remove-orphans >/dev/null 2>&1 || true
    else
        echo "KEEP_STACK=1: leaving compose stack and containers running."
        echo "  MinIO console: http://127.0.0.1:19001 (minioadmin/minioadmin)"
        echo "  Postgres:      127.0.0.1:55432 (postgres/postgres)"
    fi
}
trap cleanup EXIT

step() { printf '\n=== e2e: %s ===\n' "$*"; }

# Pre-flight: a stale server (crashed prior run) would answer the health check
# with the wrong backend wiring and poison every suite. Refuse to start.
if lsof -nP -iTCP:"$LUNET_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    stop_server   # try to reap our own stale pid file first
    if lsof -nP -iTCP:"$LUNET_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
        echo "ERROR: port $LUNET_PORT is already in use:"
        lsof -nP -iTCP:"$LUNET_PORT" -sTCP:LISTEN
        echo "Kill the stale process (or change LUNET_PORT in e2e/e2e.env) and retry."
        exit 1
    fi
fi

step "starting infrastructure (postgres + minio, versioned bucket)"
$COMPOSE up -d --wait postgres minio
$COMPOSE run --rm minio-init

step "waiting for postgres to accept connections"
for _ in $(seq 1 30); do
    if PGPASSWORD="$PGPASSWORD" psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -c 'SELECT 1' >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

step "applying schema"
PGPASSWORD="$PGPASSWORD" psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
    -v ON_ERROR_STOP=1 -q \
    -f "$ROOT/sql/schema.sql" \
    -f "$ROOT/sql/auth_schema.sql" \
    -f "$ROOT/sql/dav_schema.sql"

step "starting lunet-dav server on $LUNET_HOST:$LUNET_PORT"
mkdir -p "$ROOT/target"
(cd "$ROOT" && nohup ./bin/lunet-run server.lua > "$LOG_FILE" 2>&1 & echo $! > "$PID_FILE")
for _ in $(seq 1 20); do
    if curl -fsS "http://$LUNET_HOST:$LUNET_PORT/health" >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done
curl -fsS "http://$LUNET_HOST:$LUNET_PORT/health" >/dev/null || {
    echo "ERROR: server failed to start; log follows:"; cat "$LOG_FILE"; exit 1;
}
# lunet-run forks once at startup, so $! recorded the exited parent. Re-resolve
# the real pid from the listening socket now that the server is up.
lsof -nP -tiTCP:"$LUNET_PORT" -sTCP:LISTEN > "$PID_FILE"

HOST_URL="http://$LUNET_HOST:$LUNET_PORT"

step "chassis auth/profile suite"
HOST="$HOST_URL" bash "$ROOT/specs/run-chassis-tests-hurl.sh" || FAILED=1

step "NC31 compat suite (dav + ocs + loginflow)"
HOST="$HOST_URL" bash "$ROOT/specs/run-compat-tests-hurl.sh" || FAILED=1

step "verifying file bytes really landed in MinIO (non-negotiable)"
MC_ENV="MC_HOST_local=http://minioadmin:minioadmin@127.0.0.1:9000"
OBJECT_COUNT="$($COMPOSE exec -T -e "$MC_ENV" minio mc ls local/lunet-dav --recursive 2>/dev/null | wc -l | tr -d ' ')"
echo "objects in bucket: $OBJECT_COUNT"
# The suites PUT the "hello\n" fixture; its content-addressed key must exist.
KNOWN_KEY="_landing/5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"
KNOWN_SHA="${KNOWN_KEY#_landing/}"
if [ "$OBJECT_COUNT" -eq 0 ]; then
    echo "ERROR: MinIO bucket is empty after the compat suites — bytes did not reach S3."
    FAILED=1
elif ! $COMPOSE exec -T -e "$MC_ENV" minio mc stat "local/lunet-dav/$KNOWN_KEY" >/dev/null 2>&1; then
    echo "ERROR: known content-addressed key $KNOWN_KEY missing from MinIO."
    FAILED=1
else
    STORED_SHA="$(
        $COMPOSE exec -T -e "$MC_ENV" minio mc cat "local/lunet-dav/$KNOWN_KEY" \
            | shasum -a 256 \
            | awk '{print $1}'
    )"
    if [ "$STORED_SHA" != "$KNOWN_SHA" ]; then
        echo "ERROR: MinIO object $KNOWN_KEY has SHA-256 $STORED_SHA, expected $KNOWN_SHA."
        FAILED=1
    else
        echo "MinIO object byte verification: OK"
    fi

    VERSION_COUNT="$(
        $COMPOSE exec -T -e "$MC_ENV" minio mc ls --versions "local/lunet-dav/$KNOWN_KEY" \
            | wc -l \
            | tr -d ' '
    )"
    if [ "$VERSION_COUNT" -ne 1 ]; then
        echo "ERROR: $KNOWN_KEY has $VERSION_COUNT retained versions; identical bytes were not deduplicated."
        FAILED=1
    else
        echo "MinIO content deduplication verification: OK"
    fi
fi

if [ "$FAILED" -ne 0 ]; then
    step "RESULT: FAILED"
    exit 1
fi
step "RESULT: OK"
