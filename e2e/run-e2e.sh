#!/usr/bin/env bash
# Fully automated e2e run for lunet-dav.
#
#   1. Starts ephemeral Postgres 16 + MinIO (versioned bucket) via docker compose
#      (pull-only multi-arch images, no mounts, no BuildKit — see e2e/docker-compose.yml).
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
    if [ -f "$PID_FILE" ]; then
        pid="$(cat "$PID_FILE")"
        if kill -0 "$pid" 2>/dev/null; then
            if ps -o command= -p "$pid" 2>/dev/null | grep -q "lunet-run"; then
                kill "$pid" 2>/dev/null || true
                for _ in $(seq 1 10); do
                    kill -0 "$pid" 2>/dev/null || break
                    sleep 0.5
                done
                kill -9 "$pid" 2>/dev/null || true
            fi
        fi
        rm -f "$PID_FILE"
    fi
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

trap cleanup EXIT

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
start_server() {
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
    # lunet-run forks once at startup, so $! recorded the exited parent.
    # Re-resolve the real pid from the listening socket now that it is up.
    local listener_pid
    listener_pid="$(lsof -nP -tiTCP:"$LUNET_PORT" -sTCP:LISTEN 2>/dev/null || true)"
    if [ -z "$listener_pid" ]; then
        echo "ERROR: health check passed but no listener on port $LUNET_PORT"
        exit 1
    fi
    if ! ps -o command= -p "$listener_pid" 2>/dev/null | grep -q "lunet-run"; then
        echo "ERROR: listener on port $LUNET_PORT is not lunet-run (PID $listener_pid)"
        exit 1
    fi
    echo "$listener_pid" > "$PID_FILE"
}
start_server

HOST_URL="http://$LUNET_HOST:$LUNET_PORT"

step "chassis auth/profile suite"
HOST="$HOST_URL" bash "$ROOT/specs/run-chassis-tests-hurl.sh" || FAILED=1

step "NC31 compat suite (dav + ocs + loginflow)"
HOST="$HOST_URL" bash "$ROOT/specs/run-compat-tests-hurl.sh" || FAILED=1

step "well-formedness gate: unknown-namespace props in PROPFIND/PROPPATCH responses"
if [ "$FAILED" -eq 0 ]; then
    WF_TMP="$(mktemp)"
    trap 'rm -f "$WF_TMP"' RETURN
    
    PROPFIND_BODY='<?xml version="1.0"?><d:propfind xmlns:d="DAV:" xmlns:ua="http://example.test/a" xmlns:ub="http://example.test/b"><d:prop><d:getetag/><ua:alpha-prop/><ub:beta-prop/></d:prop></d:propfind>'
    curl -fsS -u test:test -X PROPFIND \
        -H "Depth: 0" \
        -H "Content-Type: application/xml" \
        --data "$PROPFIND_BODY" \
        "$HOST_URL/remote.php/dav/files/test/wf_$(date +%s)$$" \
        -o "$WF_TMP" 2>/dev/null || true
    
    if [ -s "$WF_TMP" ]; then
        if xmllint --noout "$WF_TMP" 2>&1 | grep -q "namespace error"; then
            echo "ERROR: PROPFIND response has undeclared namespace prefixes"
            xmllint --noout "$WF_TMP" 2>&1
            FAILED=1
        else
            echo "well-formedness gate: PROPFIND response OK"
        fi
    fi
    
    PROPPATCH_BODY='<?xml version="1.0"?><d:propertyupdate xmlns:d="DAV:" xmlns:unk="http://example.test/unknown"><d:set><d:prop><unk:mystery>val</unk:mystery></d:prop></d:set></d:propertyupdate>'
    curl -fsS -u test:test -X PROPPATCH \
        -H "Content-Type: application/xml" \
        --data "$PROPPATCH_BODY" \
        "$HOST_URL/remote.php/dav/files/test/wf_$(date +%s)$$/dummy.txt" \
        -o "$WF_TMP" 2>/dev/null || true
    
    if [ -s "$WF_TMP" ]; then
        if xmllint --noout "$WF_TMP" 2>&1 | grep -q "namespace error"; then
            echo "ERROR: PROPPATCH response has undeclared namespace prefixes"
            xmllint --noout "$WF_TMP" 2>&1
            FAILED=1
        else
            echo "well-formedness gate: PROPPATCH response OK"
        fi
    fi
    
    rm -f "$WF_TMP"
fi

step "transport probe: fragmented PUT via /dev/tcp with 100-continue"
PROBE_UID="probe$(date +%s)$$"
PROBE_COL="/remote.php/dav/files/test/$PROBE_UID"
PROBE_PATH="$PROBE_COL/fragmented.txt"
curl -fsS -u test:test -X MKCOL "$HOST_URL$PROBE_COL" >/dev/null || {
    echo "ERROR: MKCOL for transport probe failed"
    FAILED=1
}
if [ "$FAILED" -eq 0 ]; then
    PROBE_EXPECTED_SHA="$(printf 'hello\n' | shasum -a 256 | awk '{print $1}')"
    (
        exec 3<>"/dev/tcp/$LUNET_HOST/$LUNET_PORT"
        printf 'PUT %s HTTP/1.1\r\nHost: %s:%s\r\nAuthorization: Basic dGVzdDp0ZXN0\r\nExpect: 100-continue\r\nContent-Length: 6\r\n\r\n' \
            "$PROBE_PATH" "$LUNET_HOST" "$LUNET_PORT" >&3
        sleep 0.3
        printf 'hello\n' >&3
        exec 3>&-
    ) || {
        echo "ERROR: /dev/tcp PUT failed"
        FAILED=1
    }
    if [ "$FAILED" -eq 0 ]; then
        PROBE_TMP="$(mktemp)"
        curl -fsS -u test:test -o "$PROBE_TMP" "$HOST_URL$PROBE_PATH" 2>/dev/null || {
            echo "ERROR: GET after transport probe failed"
            rm -f "$PROBE_TMP"
            FAILED=1
        }
        if [ "$FAILED" -eq 0 ]; then
            PROBE_GOT_SHA="$(shasum -a 256 "$PROBE_TMP" | awk '{print $1}')"
            rm -f "$PROBE_TMP"
            if [ "$PROBE_GOT_SHA" != "$PROBE_EXPECTED_SHA" ]; then
                echo "ERROR: transport probe SHA mismatch: got $PROBE_GOT_SHA, expected $PROBE_EXPECTED_SHA"
                FAILED=1
            else
                echo "transport probe: fragmented PUT with 100-continue OK"
            fi
        fi
    fi
fi

step "transport probe: fragmented POST /login/v2/poll via /dev/tcp (delayed body)"
if [ "$FAILED" -eq 0 ]; then
    PROBE_TMP="$(mktemp)"
    (
        exec 3<>"/dev/tcp/$LUNET_HOST/$LUNET_PORT"
        printf 'POST /login/v2/poll HTTP/1.1\r\nHost: %s:%s\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 18\r\nConnection: close\r\n\r\n' \
            "$LUNET_HOST" "$LUNET_PORT" >&3
        sleep 0.3
        printf 'token=unknownprobe' >&3
        cat <&3
        exec 3>&-
    ) > "$PROBE_TMP" 2>&1 || true
    PROBE_STATUS="$(head -n1 "$PROBE_TMP" | awk '{print $2}')"
    rm -f "$PROBE_TMP"
    if [ "$PROBE_STATUS" != "404" ]; then
        echo "ERROR: fragmented POST probe: expected 404, got '$PROBE_STATUS'"
        FAILED=1
    else
        echo "transport probe: fragmented POST body read OK (404 pending)"
    fi
fi

step "transport probe: fragmented PROPFIND via /dev/tcp (split prop list)"
if [ "$FAILED" -eq 0 ]; then
    PROPFIND_BODY='<?xml version="1.0"?><propfind xmlns="DAV:"><prop><getcontentlength/></prop></propfind>'
    PROPFIND_CL="${#PROPFIND_BODY}"
    PROBE_TMP="$(mktemp)"
    (
        exec 3<>"/dev/tcp/$LUNET_HOST/$LUNET_PORT"
        printf 'PROPFIND /remote.php/dav/files/test HTTP/1.1\r\nHost: %s:%s\r\nAuthorization: Basic dGVzdDp0ZXN0\r\nDepth: 0\r\nContent-Type: application/xml\r\nContent-Length: %s\r\nConnection: close\r\n\r\n' \
            "$LUNET_HOST" "$LUNET_PORT" "$PROPFIND_CL" >&3
        sleep 0.3
        printf '%s' "$PROPFIND_BODY" >&3
        cat <&3
        exec 3>&-
    ) > "$PROBE_TMP" 2>&1 || true
    PROPFIND_STATUS="$(head -n1 "$PROBE_TMP" | awk '{print $2}')"
    if [ "$PROPFIND_STATUS" != "207" ]; then
        echo "ERROR: fragmented PROPFIND probe: expected 207, got '$PROPFIND_STATUS'"
        cat "$PROBE_TMP"
        rm -f "$PROBE_TMP"
        FAILED=1
    elif ! grep -q "getcontentlength" "$PROBE_TMP"; then
        echo "ERROR: fragmented PROPFIND probe: 207 but missing requested prop"
        cat "$PROBE_TMP"
        rm -f "$PROBE_TMP"
        FAILED=1
    else
        echo "transport probe: fragmented PROPFIND body read OK (207 with requested prop)"
        rm -f "$PROBE_TMP"
    fi
fi

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

step "two-session SQL repro: atomic claim with FOR UPDATE (item023)"
if [ "$FAILED" -eq 0 ]; then
    TEST_ID="999999"
    TEST_SECRET="test_secret_123"
    PGPASSWORD="$PGPASSWORD" psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 -q <<EOF
INSERT INTO app_passwords (id, user_id, secret, status, ctime, mtime)
VALUES ($TEST_ID, 1, '$TEST_SECRET', 'ready', now(), now());
EOF
    
    # Session A: BEGIN; SELECT FOR UPDATE + pg_sleep(2) + UPDATE + COMMIT
    (
        PGPASSWORD="$PGPASSWORD" psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 -q <<EOF
BEGIN;
SELECT id, secret, user_id FROM app_passwords WHERE id = $TEST_ID AND status = 'ready' FOR UPDATE;
SELECT pg_sleep(2);
UPDATE app_passwords SET status = 'collected', secret = NULL, mtime = now() WHERE id = $TEST_ID;
COMMIT;
EOF
    ) > "$ROOT/target/session_a.out" 2>&1 &
    SESSION_A_PID=$!
    
    # Wait for session A to start and acquire the lock
    sleep 0.5
    
    # Session B: same FOR UPDATE shape (should block, then return ZERO rows after A commits)
    (
        PGPASSWORD="$PGPASSWORD" psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 -q <<EOF
SELECT id, secret, user_id FROM app_passwords WHERE id = $TEST_ID AND status = 'ready' FOR UPDATE;
EOF
    ) > "$ROOT/target/session_b.out" 2>&1 &
    SESSION_B_PID=$!
    
    wait $SESSION_A_PID
    wait $SESSION_B_PID
    
    # Session B should return ZERO rows (status='collected' after A commits)
    if grep -q "$TEST_SECRET" "$ROOT/target/session_b.out"; then
        echo "ERROR: session B returned the secret (FOR UPDATE failed)"
        cat "$ROOT/target/session_b.out"
        FAILED=1
    else
        echo "two-session SQL repro: session B returned ZERO rows (OK)"
    fi
    
    rm -f "$ROOT/target/session_a.out" "$ROOT/target/session_b.out"
fi

step "concurrent poll: exactly one 200 + one 404 (item023)"
if [ "$FAILED" -eq 0 ]; then
    # Create a fresh user + flow for the concurrent-poll test
    CONC_UID="conc$(date +%s)$$"
    curl -fsS -X POST "$HOST_URL/api/users" \
        -H "Content-Type: application/json" \
        -d "{\"user\":{\"username\":\"$CONC_UID\",\"email\":\"${CONC_UID}@test.com\",\"password\":\"password123\"}}" \
        >/dev/null || { echo "ERROR: concurrent-poll user create failed"; FAILED=1; }
    
    if [ "$FAILED" -eq 0 ]; then
        INIT_RESP="$(curl -fsS -X POST "$HOST_URL/index.php/login/v2" -H "User-Agent: concurrent-test")"
        CONC_POLL_TOKEN="$(echo "$INIT_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['poll']['token'])" 2>/dev/null)"
        CONC_LOGIN_TOKEN="$(echo "$INIT_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['login'].split('token=')[1])" 2>/dev/null)"
        
        if [ -z "$CONC_POLL_TOKEN" ] || [ -z "$CONC_LOGIN_TOKEN" ]; then
            echo "ERROR: concurrent-poll init failed"
            FAILED=1
        else
            # Grant the flow
            curl -fsS -X POST "$HOST_URL/login/v2/grant" \
                -d "token=$CONC_LOGIN_TOKEN&loginName=$CONC_UID&password=password123" \
                >/dev/null || { echo "ERROR: concurrent-poll grant failed"; FAILED=1; }
        fi
    fi
    
    if [ "$FAILED" -eq 0 ]; then
        # Two concurrent polls
        CONC_TMP1="$(mktemp)"
        CONC_TMP2="$(mktemp)"
        curl -sS -o "$CONC_TMP1" -w "%{http_code}" -X POST "$HOST_URL/login/v2/poll" -d "token=$CONC_POLL_TOKEN" > "$CONC_TMP1.status" &
        CURL1_PID=$!
        curl -sS -o "$CONC_TMP2" -w "%{http_code}" -X POST "$HOST_URL/login/v2/poll" -d "token=$CONC_POLL_TOKEN" > "$CONC_TMP2.status" &
        CURL2_PID=$!
        wait $CURL1_PID
        wait $CURL2_PID
        
        STATUS1="$(cat "$CONC_TMP1.status")"
        STATUS2="$(cat "$CONC_TMP2.status")"
        
        # Exactly one 200 and one 404
        if [ "$STATUS1" = "200" ] && [ "$STATUS2" = "404" ]; then
            echo "concurrent poll: one 200 + one 404 (OK)"
        elif [ "$STATUS1" = "404" ] && [ "$STATUS2" = "200" ]; then
            echo "concurrent poll: one 200 + one 404 (OK)"
        else
            echo "ERROR: concurrent poll expected one 200 + one 404, got $STATUS1 + $STATUS2"
            FAILED=1
        fi
        
        rm -f "$CONC_TMP1" "$CONC_TMP2" "$CONC_TMP1.status" "$CONC_TMP2.status"
    fi
fi

step "verifying collected app-password secrets are nulled (item005)"
LEAKED="$(PGPASSWORD="$PGPASSWORD" psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -tAc "SELECT count(*) FROM app_passwords WHERE status='collected' AND secret IS NOT NULL" 2>/dev/null)"
echo "collected rows with non-null secret: $LEAKED"
if [ "$LEAKED" != "0" ]; then
    echo "ERROR: $LEAKED collected app_passwords still have non-null secret."
    FAILED=1
fi

step "behavior-config suite (minio profile, hash always, passthrough)"
# Second pass against a server with non-default behavior env (real env vars
# win over e2e.env per docs/DESIGN.md §7 layering). specs/config/* is not in
# the default compat glob: those assertions fail under defaults by design.
stop_server
export S3_API_PROFILE=minio
export DAV_EMIT_HASH_HEADER=always
export DAV_PUT_PASSTHROUGH_HEADERS=x-amz-version-id,x-amz-checksum-sha256
start_server
hurl --test \
  --jobs 1 \
  --variable "host=$HOST_URL" \
  --variable "user=test" \
  --variable "uid=cfg$(date +%s)$$" \
  "$ROOT"/specs/config/*.hurl || FAILED=1

if [ "$FAILED" -ne 0 ]; then
    step "RESULT: FAILED"
    exit 1
fi
step "RESULT: OK"
