#!/usr/bin/env bash
# WebDAV compatibility (Red/Green TDD) suite for lunet-dav.
# RED until the server is implemented — this encodes the v0.1.0 compat contract.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
HOST="${HOST:-http://localhost:8081}"
USER_NAME="${DAV_USER:-test}"
# Unique per-run suffix so collections/files do not collide across runs.
UID_VAL="${UID_VAL:-$(date +%s)$$}"

echo "Running Hurl WebDAV compat tests against $HOST (user=$USER_NAME uid=$UID_VAL)"

FILES=("$@")
if [ ${#FILES[@]} -eq 0 ]; then
  FILES=("$DIR"/dav/*.hurl)
fi

hurl --test \
  --jobs 1 \
  --variable "host=$HOST" \
  --variable "user=$USER_NAME" \
  --variable "uid=$UID_VAL" \
  "${FILES[@]}"
