#!/usr/bin/env bash
# Run litmus — the standard third-party WebDAV interoperability suite
# (Joe Orton, https://github.com/notroj/litmus) — against a running lunet-dav.
#
# Litmus is ADVISORY, not a hard gate: lunet-dav deliberately implements a
# flat-namespace subset of RFC 4918 (docs/DESIGN.md §1 non-goals), so a full
# litmus pass is impossible by design. Expected failure classes:
#   * nested collections   -> MKCOL/PUT/MOVE at depth >1 return 409
#   * COPY                 -> unsupported by the content-addressed model (409)
#   * LOCK/UNLOCK (locks)  -> not implemented (litmus Class 2 tests)
#   * arbitrary dead props -> PROPPATCH accepts tags only
#
# What this script DOES enforce: litmus must build, connect, and run the
# `basic` suite with a pass-rate at or above LITMUS_BASIC_MIN_PASS (default
# 75%), so genuine wire-level regressions (broken PUT/GET/DELETE/OPTIONS)
# still fail the e2e run. The full per-test output is always printed for
# human review.
#
# Build prerequisites (macOS): brew install neon autoconf automake
# The build is cached in target/litmus/ across runs.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
HOST="${HOST:-http://127.0.0.1:18081}"
DAV_USER="${DAV_USER:-test}"
BASE_URL="$HOST/remote.php/dav/files/$DAV_USER/"
LITMUS_DIR="$ROOT/target/litmus"
LITMUS_VERSION="0.18"
LITMUS_BASIC_MIN_PASS="${LITMUS_BASIC_MIN_PASS:-75}"

build_litmus() {
    command -v autoconf >/dev/null || { echo "ERROR: autoconf missing (brew install autoconf automake)"; exit 1; }
    if ! ls /opt/homebrew/include/neon/ne_basic.h >/dev/null 2>&1 && \
       ! ls /usr/local/include/neon/ne_basic.h >/dev/null 2>&1 && \
       ! pkg-config --exists neon 2>/dev/null; then
        echo "ERROR: neon headers missing (brew install neon)"; exit 1
    fi
    echo "Building litmus $LITMUS_VERSION into $LITMUS_DIR ..."
    rm -rf "$LITMUS_DIR"
    git clone --quiet --depth 1 --branch "$LITMUS_VERSION" https://github.com/notroj/litmus "$LITMUS_DIR"
    (
        cd "$LITMUS_DIR"
        git submodule update --init --quiet
        ./autogen.sh >/dev/null
        if [ -d /opt/homebrew/include/neon ]; then
            ./configure --with-neon=/opt/homebrew >/dev/null
        else
            ./configure >/dev/null
        fi
        make >/dev/null
    )
}

# Cached build: rebuild only if the basic test binary is missing.
[ -x "$LITMUS_DIR/basic" ] || build_litmus

echo "litmus $LITMUS_VERSION against $BASE_URL"
echo "(advisory suite; flat-namespace/COPY/LOCK failures are expected — see header)"
echo

OUT="$(mktemp "${TMPDIR:-/tmp}/litmus.XXXXXX")"
trap 'rm -f "$OUT"' EXIT

# -k: keep going across suite failures; -n: no colour (log-friendly).
# Suites: basic is semi-gated (see below); the rest are informational.
# Run from LITMUS_DIR: litmus drops debug.log/child.log into its cwd.
(cd "$LITMUS_DIR" && TESTS="basic copymove props http" TESTROOT="$LITMUS_DIR" \
    "$LITMUS_DIR/litmus" -k -n "$BASE_URL") 2>&1 | tee "$OUT" || true

# Gate: the `basic` suite pass-rate must not regress below the floor.
LINE="$(grep "summary for \`basic'" "$OUT" || true)"
if [ -z "$LINE" ]; then
    echo "ERROR: litmus basic suite did not produce a summary (server unreachable?)"
    exit 1
fi
PCT="$(echo "$LINE" | sed -E 's/.* ([0-9]+)(\.[0-9]+)?%.*/\1/')"
echo
echo "litmus basic pass-rate: ${PCT}% (floor: ${LITMUS_BASIC_MIN_PASS}%)"
if [ "$PCT" -lt "$LITMUS_BASIC_MIN_PASS" ]; then
    echo "ERROR: litmus basic suite regressed below the floor."
    exit 1
fi
echo "litmus: OK (advisory suites logged above)"
