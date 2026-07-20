# lunet-dav docs

A NextCloud-Enterprise-31 work-alike WebDAV server on the `lunet` chassis, backed by an
S3-compatible object store (MinIO locally, Scaleway/AWS/legacy SAN in prod) and PostgreSQL 16.

**Status:** design + spec + compat suite only. No server code yet. The `specs/dav/*.hurl`
suite is deliberately RED and defines the v0.1.0 compatibility contract (Red/Green TDD).

## Read in this order

1. [`reference/nextcloud-webdav-basic-v31.md`](reference/nextcloud-webdav-basic-v31.md)
   — captured upstream nc E31 WebDAV behaviour we emulate.
2. [`DESIGN.md`](DESIGN.md) — architecture: content-addressed immutable S3 storage,
   Postgres CAS metadata, the 2-D op-log, identity/`OC-FileId`, LCD S3 profiles, network posture.
3. [`SPEC-v0.1.0.md`](SPEC-v0.1.0.md) — the exact, testable wire contract per method.

## Related files

- [`../sql/dav_schema.sql`](../sql/dav_schema.sql) — the `dav_files` metadata table.
- [`../.env.dav.example`](../.env.dav.example) — S3 + Postgres + network config.
- [`../specs/dav/`](../specs/dav/) — Hurl 8.x compatibility tests.
- [`../specs/run-dav-tests-hurl.sh`](../specs/run-dav-tests-hurl.sh) — the DAV test runner.

## MVP scope (v0.1.0)

In: `OPTIONS`, `PROPFIND`, `PUT`, `GET`, `HEAD`, `DELETE`, `MKCOL`, `MOVE`,
`PROPPATCH` (tags only). Flat top-level "team folders". `OC-Etag`/`OC-FileId` headers.

Out (by design): users/permissions/sharing/ACLs, favourites, comments, locks, previews,
quotas, chunked upload, nested folders, `COPY` (409), folder zip download, `REPORT`.
