# lunet-dav

Local emulator for selected **NextCloud Enterprise 31** surfaces:

- WebDAV file API (`/remote.php/dav/files/...`)
- OCS user API (`/ocs/v2.php/cloud/...`)
- Login Flow v2 (`/index.php/login/v2`, `/login/v2/...`)

This repository is alpha scaffolding (`0.x.y`, intentionally breaking). The scope and schema are provisional and can be rewritten as implementation converges.

## Runtime

- LuaJIT server on `lunet` (`server.lua`)
- PostgreSQL 16 metadata schema (`sql/*.sql`)
- S3-compatible object store for DAV file bytes (MinIO locally): content-addressed
  keys (`_landing/<sha256>`), mandatory bucket versioning (server refuses to start
  otherwise), SigV4 over plain lunet sockets on the uv loop (`lib/s3.lua` — no C
  driver, no worker pool). A running MinIO with a versioned bucket is therefore a
  prerequisite for `make start`; `make e2e-up` provides one (adjust `S3_ENDPOINT`).

## Current layout

```text
app/                  # runtime modules
docs/                 # design/spec/reference docs
e2e/                  # automated e2e harness (compose infra + runner + litmus)
specs/dav/            # NC31 WebDAV hurl contract
specs/ocs/            # OCS hurl contract
specs/loginflow/      # Login Flow v2 hurl contract
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
                  # schema, server on a high port, all hurl suites, litmus
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
suite, and then runs [litmus](https://github.com/notroj/litmus) — the standard
third-party WebDAV interoperability suite. Litmus is advisory except for a
pass-rate floor on its `basic` suite: lunet-dav's flat-namespace subset (no nested
collections, no COPY, no locks) makes a full litmus pass impossible by design
(see `docs/DESIGN.md` §1). `KEEP_STACK=1 make e2e` keeps the containers up
afterwards for manual inspection. Litmus builds once into `target/litmus/`
(needs `brew install neon autoconf automake`).

## Notes

- The `specs/chassis/*` tests are temporary bootstrap coverage for reused auth/user primitives.
- NC31 work-alike behavior is defined by `specs/dav/*`, `specs/ocs/*`, and `specs/loginflow/*`.
