# lunet-dav

Local emulator for selected **NextCloud Enterprise 31** surfaces:

- WebDAV file API (`/remote.php/dav/files/...`)
- OCS user API (`/ocs/v2.php/cloud/...`)
- Login Flow v2 (`/index.php/login/v2`, `/login/v2/...`)

This repository is alpha scaffolding (`0.x.y`, intentionally breaking). The scope and
schema are provisional and can be rewritten as implementation converges.

## Install from release

Prebuilt tarballs for **linux-amd64**, **linux-arm64**, and **macos-arm64** are published on the
[Releases page](../../releases) (tagged `v*.*.*`, marked prerelease). Download,
extract, configure:

```bash
# Pick your platform
curl -fsSLO ../../releases/latest/download/lunet-dav-v0.1.1-linux-amd64.tar.gz
# or: curl -fsSLO ../../releases/latest/download/lunet-dav-v0.1.1-linux-arm64.tar.gz
# or: curl -fsSLO ../../releases/latest/download/lunet-dav-v0.1.1-macos-arm64.tar.gz

tar -xzf lunet-dav-v0.1.1-*.tar.gz
cd lunet-dav-v0.1.1-*

cp .env.example .env
# edit .env: PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD, S3_*

make init   # checks deps (mise, hurl, lua-language-server, luarocks, lua-expat)
make start  # starts server on ${LUNET_PORT:-8081}
```

The tarball includes `bin/` (lunet-run, lunet.so, postgres.so, lnt_shared, cjson,
lxp), `server.lua`, `app/`, `lib/`, `compat/`, `sql/`, `specs/` (hurl suites for
local testing), `Makefile`, and `.env.example`.

## Runtime

- LuaJIT server on `lunet` (`server.lua`)
- PostgreSQL 16 metadata schema (`sql/*.sql`)
- S3-compatible object store for DAV file bytes (MinIO locally): content-addressed
  keys (`_landing/<sha256>`), mandatory bucket versioning (server refuses to start
  otherwise), SigV4 over plain lunet sockets on the uv loop (`lib/s3.lua` — no C
  driver, no worker pool). A running MinIO with a versioned bucket is therefore a
  prerequisite for `make start`; `make e2e-up` provides one (adjust `S3_ENDPOINT`).
- Layered behavior configuration (`app/behavior.lua`): Lua defaults → `.env` → env
  vars. Covers the upstream S3 capability profile (`S3_API_PROFILE`), checksum
  cross-check, hash-header mode (`DAV_EMIT_HASH_HEADER`), and an upstream-header
  passthrough allowlist (`DAV_PUT_PASSTHROUGH_HEADERS`). Defaults reproduce the
  v0.1.1 wire contract exactly — see `docs/DESIGN.md` §7–§8.

## Security philosophy

The spine of this solution is, wherever possible, **standard binaries with good
community security support from the latest Debian LTS release** — libuv, LuaJIT,
libexpat/LuaExpat, PostgreSQL, and friends arrive as OS packages that keep
receiving security fixes from their wider communities for the life of the LTS.
We do **not** vendor compiled third-party libraries in this repository: anything
that must be compiled locally (e.g. a thin Lua binding against an OS library) is
built at `make init` time on a dev machine, or at image-build time in the
Dockerfile, against OS-provided headers — never committed. Deployable artifacts
prefer the Debian LTS binary package (e.g. `apt install lua-expat`) over building
from source.

## Current layout

```text
app/                  # runtime modules
docs/                 # design/spec/reference docs
e2e/                  # automated e2e harness (compose infra + runner)
specs/dav/            # NC31 WebDAV hurl contract
specs/ocs/            # OCS hurl contract
specs/loginflow/      # Login Flow v2 hurl contract
specs/config/         # non-default config suites (e2e second pass)
specs/chassis/        # temporary bootstrap auth/profile tests
sql/                  # schema slices
```

## Commands

```bash
make init
make start
make test         # chassis auth/profile compatibility tests
HOST=http://127.0.0.1:8081 bash specs/run-compat-tests-hurl.sh
make e2e          # fully automated: ephemeral PG16 + MinIO (docker compose on
                  # colima, pull-only arm64 images, no mounts, no BuildKit),
                  # schema, server on a high port, all hurl suites, and a hard
                  # gate that PUT bytes really landed in the bucket
make e2e-up       # just the e2e infra (PG :55432, MinIO API :19000, console :19001)
make e2e-down
make load-test
make lint
make stop
```

## e2e suite

`make e2e` is the one-command answer to "does main actually work?". It stands up
throwaway Postgres 16 and MinIO containers (versioned bucket, MinIO web console on
http://127.0.0.1:19001 for eyeballing objects), runs every in-repo hurl contract
suite, and then verifies in MinIO itself that the bytes really landed: object count,
the known content-addressed key for the `"hello\n"` fixture, a byte-for-byte sha, and
exactly one retained version (identical content deduplicates).
`KEEP_STACK=1 make e2e` keeps the containers up afterwards for manual inspection.

## Notes

- The `specs/chassis/*` tests are temporary bootstrap coverage for reused auth/user
  primitives.
- NC31 work-alike behavior is defined by `specs/dav/*`, `specs/ocs/*`, and
  `specs/loginflow/*`.
