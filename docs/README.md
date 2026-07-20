# lunet-dav docs

A NextCloud-Enterprise-31 work-alike WebDAV server on the `lunet` chassis, backed by an
S3-compatible object store (MinIO locally, Scaleway/AWS/legacy SAN in prod) and PostgreSQL 16.

**Status:** design + spec + compat suite only. No server code yet. The `specs/dav/*.hurl`
suite is deliberately RED and defines the v0.1.0 compatibility contract (Red/Green TDD).

## Read in this order

1. Reference captures of upstream nc E31 behaviour we emulate:
   [WebDAV](reference/nextcloud-webdav-basic-v31.md),
   [Login Flow v2](reference/nextcloud-loginflow-v2-v31.md),
   [OCS user](reference/nextcloud-ocs-user-v31.md).
2. [`DESIGN.md`](DESIGN.md) — architecture: content-addressed immutable S3 storage,
   Postgres CAS metadata, the 2-D op-log, identity/`OC-FileId`, LCD S3 profiles, network
   posture, and (§10) OCS + Login Flow v2 + app passwords.
3. [`SPEC-v0.1.0.md`](SPEC-v0.1.0.md) — the exact, testable wire contract for all three
   surfaces (WebDAV, Login Flow v2, OCS).
4. [`TEST-PLAN.md`](TEST-PLAN.md) — unit-test suite design + hurl compat inventory.

## Related files

- [`../sql/dav_schema.sql`](../sql/dav_schema.sql) — the `dav_files` metadata table.
- [`../sql/auth_schema.sql`](../sql/auth_schema.sql) — `app_passwords` (with the Login Flow
  v2 `pending→ready→collected` lifecycle).
- [`../app/store.lua`](../app/store.lua) + [`../sql/store_schema.sql`](../sql/store_schema.sql)
  — the `store` mock (lunet#103 stand-in) and its throwaway Postgres backing;
  [`../app/store_routes.lua`](../app/store_routes.lua) is its test-only HTTP shim.
- [`../.env.dav.example`](../.env.dav.example) — S3 + Postgres + network config.
- [`../specs/dav/`](../specs/dav/), [`../specs/loginflow/`](../specs/loginflow/),
  [`../specs/ocs/`](../specs/ocs/) — Hurl 8.x compatibility tests.
- [`../specs/run-compat-tests-hurl.sh`](../specs/run-compat-tests-hurl.sh) — full runner
  (DAV + Login Flow + OCS); [`../specs/run-dav-tests-hurl.sh`](../specs/run-dav-tests-hurl.sh)
  runs DAV only.
- [`../AGENTS.md`](../AGENTS.md) — the 0.x.y alpha build workflow (Red/Green, pivot protocol).

## Feature set (v0.1.0) — the complete set used against the author's NC E31 instance

- **WebDAV files**: `OPTIONS`, `PROPFIND`, `PUT`, `GET`, `HEAD`, `DELETE`, `MKCOL`, `MOVE`,
  `PROPPATCH` (tags only). Flat top-level "team folders"; `OC-Etag`/`OC-FileId` headers.
- **Login Flow v2**: system-browser app-password minting (init → grant → poll).
- **OCS**: `/cloud/user` + `/cloud/users/{self}` with basic security (self-only).

Out (by design): permissions/sharing/ACLs, favourites, file comments (table kept, no
routes), locks, previews, quotas, chunked upload, nested folders, `COPY` (409), folder zip
download, `REPORT`, OCS admin/other-user access, XML OCS format, Login Flow v1.
