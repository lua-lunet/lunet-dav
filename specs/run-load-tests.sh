#!/usr/bin/env sh
# Read-dominated load test for NC31 emulator surfaces.
# Readers hit OCS current-user + DAV GET; writers PUT file content at low rate.
set -u

HOST="${HOST:-http://127.0.0.1:8081}"
DURATION="${DURATION:-8s}"
TMP="${TMPDIR:-/tmp}/loadtest.$$"

command -v hey >/dev/null 2>&1 || { echo "ERROR: hey is not installed (brew install hey)"; exit 1; }

mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

UID_VAL="load$(date +%s)$$"
USER_NAME="load_${UID_VAL}"
EMAIL="${USER_NAME}@test.com"

curl -s -X POST "$HOST/api/users" -H 'Content-Type: application/json' \
  -d "{\"user\":{\"username\":\"$USER_NAME\",\"email\":\"$EMAIL\",\"password\":\"password123\"}}" >/dev/null

FLOW_JSON="$TMP/flow.json"
curl -s -X POST "$HOST/index.php/login/v2" -H 'User-Agent: lunet-load/0.1' > "$FLOW_JSON"
POLL_TOKEN=$(sed -n 's/.*"token":"\([^"]*\)".*/\1/p' "$FLOW_JSON" | head -n1)
LOGIN_TOKEN=$(sed -n 's/.*"login":"[^"]*token=\([^"]*\)".*/\1/p' "$FLOW_JSON")
[ -n "$POLL_TOKEN" ] || { echo "ERROR: could not obtain poll token"; exit 1; }
[ -n "$LOGIN_TOKEN" ] || { echo "ERROR: could not obtain login token"; exit 1; }

curl -s -X POST "$HOST/login/v2/grant" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "token=$LOGIN_TOKEN&loginName=$USER_NAME&password=password123" >/dev/null

POLL_JSON="$TMP/poll.json"
curl -s -X POST "$HOST/login/v2/poll" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "token=$POLL_TOKEN" > "$POLL_JSON"
APP_PASSWORD=$(sed -n 's/.*"appPassword":"\([^"]*\)".*/\1/p' "$POLL_JSON")
[ -n "$APP_PASSWORD" ] || { echo "ERROR: could not obtain app password"; exit 1; }

BASIC_B64=$(printf "%s:%s" "$USER_NAME" "$APP_PASSWORD" | base64 | tr -d '\n')

COLL="load_${UID_VAL}"
FILE_URL="$HOST/remote.php/dav/files/$USER_NAME/$COLL/a.txt"
mkdir -p "$TMP"
printf "hello\n" > "$TMP/put.txt"

curl -s -X MKCOL "$HOST/remote.php/dav/files/$USER_NAME/$COLL" -H "Authorization: Basic $BASIC_B64" >/dev/null
curl -s -X PUT "$FILE_URL" -H "Authorization: Basic $BASIC_B64" --data-binary @"$TMP/put.txt" >/dev/null

codes() {
    grep -E '^[[:space:]]+\[[0-9]+\]' "$1" | awk '{printf "%s%s ", $1, $2}'
}

FAILED=0
for C in 1 2 4 8 16 32 64; do
    W=$((C / 8))
    [ "$W" -lt 1 ] && W=1

    hey -z "$DURATION" -c "$C" \
      -H 'OCS-APIRequest: true' -H "Authorization: Basic $BASIC_B64" \
      "$HOST/ocs/v2.php/cloud/user?format=json" > "$TMP/ocs.out" 2>&1 &
    P1=$!

    hey -z "$DURATION" -c "$C" \
      -H "Authorization: Basic $BASIC_B64" \
      "$FILE_URL" > "$TMP/dav-get.out" 2>&1 &
    P2=$!

    hey -z "$DURATION" -q 6 -c "$W" -m PUT \
      -H "Authorization: Basic $BASIC_B64" \
      -H 'Content-Type: text/plain' \
      -D "$TMP/put.txt" \
      "$FILE_URL" > "$TMP/dav-put.out" 2>&1 &
    P3=$!

    wait "$P1" "$P2" "$P3"

    echo "readers=$C writers=$W | ocs: $(codes "$TMP/ocs.out")| dav-get: $(codes "$TMP/dav-get.out")| dav-put: $(codes "$TMP/dav-put.out")"

    if grep -hE '^[[:space:]]+\[5[0-9][0-9]\]' "$TMP"/*.out | grep -v '\[503\]' >/dev/null; then
        FAILED=1
    fi
done

if [ "$FAILED" -ne 0 ]; then
    echo "FAIL: server returned 5xx other than 503 under load"
    exit 1
fi
echo "OK: no unexpected 5xx; overload (if any) shed as 503"
