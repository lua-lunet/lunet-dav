#!/usr/bin/env bash
# Full NC E31 work-alike compatibility suite: WebDAV + Login Flow v2 + OCS.
# Red/Green TDD — RED until the server is implemented. Encodes the v0.1.0 contract.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
HOST="${HOST:-http://localhost:8081}"
USER_NAME="${DAV_USER:-test}"
UID_VAL="${UID_VAL:-$(date +%s)$$}"

echo "Running Hurl compat suite against $HOST (user=$USER_NAME uid=$UID_VAL)"

FILES=("$@")
if [ ${#FILES[@]} -eq 0 ]; then
  FILES=("$DIR"/loginflow/*.hurl "$DIR"/ocs/*.hurl "$DIR"/dav/*.hurl)
fi

hurl --test \
  --jobs 1 \
  --variable "host=$HOST" \
  --variable "user=$USER_NAME" \
  --variable "uid=$UID_VAL" \
  "${FILES[@]}"
