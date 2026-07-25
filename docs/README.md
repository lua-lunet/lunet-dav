# lunet-dav docs

A NextCloud-Enterprise-31 work-alike WebDAV server on the `lunet` chassis, backed by
an S3-compatible object store (MinIO locally, legacy SAN/NAS S3 front-ends in prod)
and PostgreSQL 16.

**Status:** alpha (`0.x.y`, intentionally breaking). The hurl suites under `specs/`
are the compatibility contract; the build follows linear Red/Green TDD (unit green →
hurl file green → next).

## Read in this order

1. Reference captures of upstream nc E31 behaviour we emulate:
   [WebDAV](reference/nextcloud-webdav-basic-v31.md),
   [Login Flow v2](reference/nextcloud-loginflow-v2-v31.md),
   [OCS user](reference/nextcloud-ocs-user-v31.md).
2. [`DESIGN.md`](DESIGN.md) — architecture: content-addressed immutable S3 storage,
   Postgres CAS metadata, the op-log + tags in `info` JSONB, identity/`OC-FileId`,
   S3 compatibility profiles, behavior configuration, response header policy, network
   posture, and (§12) OCS + Login Flow v2 + app passwords.
3. [`SPEC-v0.1.0.md`](SPEC-v0.1.0.md) — the exact, testable wire contract for all
   three surfaces (WebDAV, Login Flow v2, OCS) plus the behavior-configuration keys.
4. [`TEST-PLAN.md`](TEST-PLAN.md) — unit-test suite design + hurl compat inventory.

## Related files

- [`../sql/dav_schema.sql`](../sql/dav_schema.sql) — the `dav_files` metadata table.
- [`../sql/auth_schema.sql`](../sql/auth_schema.sql) — `app_passwords` (with the Login
  Flow v2 `pending→ready→collected` lifecycle).
- `require("lunet.lnt_shared")` (vendored at `bin/lunet/lnt_shared.lua` +
  `liblnt_shared.{so,dylib}`, built from `ext/lnt_shared` in the `lunet` source — see
  [`DESIGN.md`](DESIGN.md) §12.0) — the shared in-process store backing Login Flow
  v2's transient state; used via `app/nc31.lua`.
- [`../.env.dav.example`](../.env.dav.example) — S3 + Postgres + network + behavior
  config.
- [`../specs/dav/`](../specs/dav/), [`../specs/loginflow/`](../specs/loginflow/),
  [`../specs/ocs/`](../specs/ocs/) — Hurl 8.x compatibility tests.
- [`../specs/run-compat-tests-hurl.sh`](../specs/run-compat-tests-hurl.sh) — full
  runner (DAV + Login Flow + OCS); [`../specs/run-dav-tests-hurl.sh`](../specs/run-dav-tests-hurl.sh)
  runs DAV only.
- [`../AGENTS.md`](../AGENTS.md) — the 0.x.y alpha build workflow (Red/Green, pivot
  protocol).

## Feature set (v0.1.0) — the complete set used against the author's NC E31 instance

- **WebDAV files**: `OPTIONS`, `PROPFIND`, `PUT`, `GET`, `HEAD`, `DELETE`, `MKCOL`,
  `MOVE`, `PROPPATCH` (tags only). Flat top-level "team folders";
  `OC-Etag`/`OC-FileId` headers.
- **Login Flow v2**: system-browser app-password minting (init → grant → poll).
- **OCS**: `/cloud/user` + `/cloud/users/{self}` with basic security (self-only).
- **Behavior configuration**: upstream S3 capability profile, checksum cross-check,
  hash-header mode, and an upstream-header passthrough allowlist — layered Lua
  defaults → `.env` → env vars (see `DESIGN.md` §7–§8).

Out (by design): permissions/sharing/ACLs, favourites, file comments (table kept, no
routes), locks, previews, quotas, chunked upload, nested folders, `COPY` (409), folder
zip download, `REPORT`, OCS admin/other-user access, XML OCS format, Login Flow v1.
