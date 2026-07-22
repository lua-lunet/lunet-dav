# lunet-dav

Local emulator for selected **NextCloud Enterprise 31** surfaces:

- WebDAV file API (`/remote.php/dav/files/...`)
- OCS user API (`/ocs/v2.php/cloud/...`)
- Login Flow v2 (`/index.php/login/v2`, `/login/v2/...`)

This repository is alpha scaffolding (`0.x.y`, intentionally breaking). The scope and schema are provisional and can be rewritten as implementation converges.

## Runtime

- LuaJIT server on `lunet` (`server.lua`)
- PostgreSQL 16 metadata schema (`sql/*.sql`)
- S3-compatible object store target for DAV object bytes (MinIO locally)

## Current layout

```text
app/                  # runtime modules
docs/                 # design/spec/reference docs
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
make load-test
make lint
make stop
```

## Notes

- The `specs/chassis/*` tests are temporary bootstrap coverage for reused auth/user primitives.
- NC31 work-alike behavior is defined by `specs/dav/*`, `specs/ocs/*`, and `specs/loginflow/*`.
