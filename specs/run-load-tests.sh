#!/usr/bin/env sh
# Read-dominated load test with a write stream, doubling concurrency 1 -> 64.
# Readers hit GET /api/articles and GET /api/articles/{slug} at full speed;
# writers post comments and favorites rate-limited to ~10/s per writer
# (1 writer per 8 readers), keeping the mix ~99% reads.
#
# Requires hey (https://github.com/rakyll/hey). Fails on any HTTP 500:
# under overload the server must shed load with 503, never break with 500.
#
# Usage: HOST=http://localhost:8081 sh specs/run-load-tests.sh
set -u

HOST="${HOST:-http://localhost:8081}"
DURATION="${DURATION:-8s}"
TMP="${TMPDIR:-/tmp}/loadtest.$$"

command -v hey >/dev/null 2>&1 || { echo "ERROR: hey is not installed (brew install hey)"; exit 1; }

mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

# Seed a user and an article to read and write against
UID_VAL="load$(date +%s)$$"
TOKEN=$(curl -s -X POST "$HOST/api/users" -H 'Content-Type: application/json' \
    -d "{\"user\":{\"username\":\"$UID_VAL\",\"email\":\"$UID_VAL@example.com\",\"password\":\"password123\"}}" \
    | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
[ -n "$TOKEN" ] || { echo "ERROR: could not register load-test user against $HOST"; exit 1; }

SLUG=$(curl -s -X POST "$HOST/api/articles" -H "Authorization: Token $TOKEN" -H 'Content-Type: application/json' \
    -d '{"article":{"title":"load test target","description":"d","body":"b","tagList":["load"]}}' \
    | sed -n 's/.*"slug":"\([^"]*\)".*/\1/p')
[ -n "$SLUG" ] || { echo "ERROR: could not create load-test article"; exit 1; }

printf '{"comment":{"body":"load test comment"}}' > "$TMP/comment.json"

codes() {
    # Reduce hey output to "[status] count" pairs on one line
    grep -E '^[[:space:]]+\[[0-9]+\]' "$1" | awk '{printf "%s%s ", $1, $2}'
}

FAILED=0
for C in 1 2 4 8 16 32 64; do
    W=$((C / 8))
    [ "$W" -lt 1 ] && W=1

    hey -z "$DURATION" -c "$C" "$HOST/api/articles" > "$TMP/list.out" 2>&1 &
    P1=$!
    hey -z "$DURATION" -c "$C" "$HOST/api/articles/$SLUG" > "$TMP/article.out" 2>&1 &
    P2=$!
    hey -z "$DURATION" -q 10 -c "$W" -m POST -H "Authorization: Token $TOKEN" \
        -H 'Content-Type: application/json' -D "$TMP/comment.json" \
        "$HOST/api/articles/$SLUG/comments" > "$TMP/comment.out" 2>&1 &
    P3=$!
    hey -z "$DURATION" -q 10 -c "$W" -m POST -H "Authorization: Token $TOKEN" \
        "$HOST/api/articles/$SLUG/favorite" > "$TMP/favorite.out" 2>&1 &
    P4=$!
    wait "$P1" "$P2" "$P3" "$P4"

    echo "readers=$C writers=$W | list: $(codes "$TMP/list.out")| article: $(codes "$TMP/article.out")| comment: $(codes "$TMP/comment.out")| favorite: $(codes "$TMP/favorite.out")"

    if grep -hE '^[[:space:]]+\[5[0-9][0-9]\]' "$TMP"/*.out | grep -v '\[503\]' >/dev/null; then
        FAILED=1
    fi
done

if [ "$FAILED" -ne 0 ]; then
    echo "FAIL: server returned 5xx other than 503 under load"
    exit 1
fi
echo "OK: no unexpected 5xx; overload (if any) shed as 503"
