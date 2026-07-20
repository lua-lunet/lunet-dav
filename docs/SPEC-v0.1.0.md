# lunet-dav — v0.1.0 Wire Spec

The precise, testable contract the `specs/dav/*.hurl` suite enforces. Behaviour mirrors
NextCloud Enterprise 31 (see [`reference/nextcloud-webdav-basic-v31.md`](reference/nextcloud-webdav-basic-v31.md))
for the MVP method set only. Everything here is what a client on the wire observes.

- **Base path:** `/remote.php/dav/files/{user}/{path}`
- **`{user}`:** any token; from Basic auth or the path. Not validated in v0.1.0.
- **`{path}`:** flat — either `` (root), `{collection}`, `{name}`, or `{collection}/{name}`.
- **Auth:** `Authorization: Basic ...` parsed; username → `op_log.who`. Password ignored.

## Identity & headers

- `OC-FileId = lpad(id, DAV_FILEID_PAD_WIDTH, "0") + DAV_INSTANCE_ID`
  → e.g. id 259 → `00000259oczn5x60nrdu`. Stable across overwrite/move.
- `OC-Etag` = the stored S3 ETag, emitted **quoted**, e.g. `"50ef2eba...a5ef"`.
- `oc:id` == `OC-FileId`; `oc:fileid` == numeric `id`.
- When request carries `X-Hash: sha256`, response includes `X-Hash-SHA256: <hex>`.
- When request carries `X-OC-MTime`/`X-OC-CTime`, response echoes `X-OC-MTime: accepted`
  / `X-OC-CTime: accepted` (v0.1.0 accepts the header; server timestamps still authoritative).

---

## OPTIONS

`OPTIONS {base}/{path}` → **200**, headers:
- `DAV: 1` (class-1; locks are not implemented)
- `Allow: OPTIONS, GET, HEAD, PUT, DELETE, MKCOL, MOVE, PROPFIND, PROPPATCH`
- `MS-Author-Via: DAV`

---

## PUT — upload

`PUT {base}/{collection}/{name}` with raw body.

Server: sha256(body) → key `_landing/<sha256>` → `PutObject` (versioned bucket) →
upsert `dav_files` row (CAS if it exists, INSERT if new).

Responses:
- **201 Created** — new file. Headers: `OC-FileId`, `OC-Etag`, `Content-Length: 0`.
- **204 No Content** — overwrote an existing path. Same headers.
- **409 Conflict** — parent collection segment does not exist, or path is nested more
  than one level, or targets a reserved (`_`-prefixed) collection.
- **412 Precondition Failed** — CAS lost a concurrent write race.

Same content re-PUT to the same path is a no-op-ish overwrite: sha256/key unchanged, a new
S3 VersionId may be produced, `version` bumps, a `put` op is appended.

---

## GET / HEAD — download

`GET {base}/{collection}/{name}` → **200**, body = object bytes, headers:
`Content-Type` (= `mime_type`), `Content-Length` (= `size`), `ETag` (quoted),
`Last-Modified`, `OC-FileId`. `HEAD` is identical with no body.
Missing path → **404**. `GET` on a collection (zip/tar) is `NOT IN v0.1.0` → **501**.

---

## MKCOL — create collection (flat team folder)

`MKCOL {base}/{name}`:
- **201 Created** — new top-level collection. Headers: `OC-FileId`, `OC-Etag`.
- **405 Method Not Allowed** — collection already exists.
- **403 Forbidden** — name begins with `_` (reserved).
- **409 Conflict** — nested (`MKCOL {base}/{a}/{b}`); flat namespace only.

---

## DELETE

`DELETE {base}/{path}` → **204 No Content**. On a collection, deletes contained rows
recursively (metadata). Object bytes are retained in S3 (immutable / versioned store);
only metadata rows are removed in v0.1.0. Missing path → **404**.

---

## MOVE — move / rename

`MOVE {base}/{src}` with `Destination: {absolute-url}/{dst}` and optional `Overwrite: T|F`.
Keeps the same `id`/`OC-FileId` (inode semantics); appends a `move`/`rename` op.
- **201 Created** — moved to a path that did not exist.
- **204 No Content** — overwrote an existing destination (`Overwrite: T`, the default).
- **403 Forbidden** — destination collection reserved (`_`-prefixed).
- **409 Conflict** — destination nested more than one level / parent missing.
- **412 Precondition Failed** — destination exists and `Overwrite: F`.
Success responses carry `OC-FileId` and `OC-Etag`.

---

## COPY — unsupported by design

`COPY {base}/{src}` → **409 Conflict**, body is a DAV error XML explaining that the
content-addressed store cannot represent two logical files sharing one sha256. This is a
deliberate "400-like" client error (see docs/DESIGN.md §5), not a transient failure.

---

## PROPFIND — list / read properties

`PROPFIND {base}/{path}` with `Depth: 0` (this resource) or `Depth: 1` (resource +
direct children). Body: `d:propfind` requesting properties. Response: **207 Multi-Status**
`application/xml`, a `d:multistatus` with one `d:response` per resource.

Supported properties (others returned in `404 propstat`):

**DAV (`d:`)**: `getlastmodified` (mtime), `creationdate` (ctime, ISO 8601),
`getetag` (quoted), `getcontenttype` (files), `getcontentlength` (files),
`resourcetype` (`<d:collection/>` for collections), `displayname` (= name),
`quota-available-bytes` = `-3` (unlimited), `quota-used-bytes` = `0`.

**ownCloud (`oc:`)**: `id` (= OC-FileId), `fileid` (= numeric id),
`permissions` = `RGDNVW` (static, no sharing), `size`, `favorite` = `0` (static),
`tags` (replayed from op-log set-label/unset-label, in order), `checksums`
(`<oc:checksum>SHA-256:<hex></oc:checksum>`).

**NextCloud (`nc:`)**: `has-preview` = `false`, `is-encrypted` = `0`,
`contained-file-count` / `contained-folder-count` (collections), `mount-type` = ``.

**lunet (`lnt:`, unstable/debug — `http://lunet.stenographer.cloud/ns`)**:
`sha256`, `s3-version-id`, `cas-version`, `collection`,
`oplog` (full op-log as a JSON array of `[ts,who,type,data]` rows).

Missing path → **404**. `Depth: infinity` → **403** (flat namespace; not needed).

---

## PROPPATCH — set tags only

`PROPPATCH {base}/{path}` → **207 Multi-Status**.
- Setting `<oc:tags><oc:tag>x</oc:tag>...</oc:tags>` appends `set-label`/`unset-label`
  ops so the replayed tag set matches the request; each returns `200` propstat.
- `<oc:favorite>` → `403` propstat (needs a user table; `NOT IN v0.1.0`).
- Any other settable property → `403` propstat.

---

## Error body shape

WebDAV error responses (`4xx`/`5xx` other than `207`) carry a `d:error` XML document:

```xml
<?xml version="1.0" encoding="utf-8"?>
<d:error xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns">
  <s:exception>Lunet\Dav\Exception\Unsupported</s:exception>
  <s:message>COPY is not supported: content-addressed store cannot duplicate a file</s:message>
</d:error>
```

## Status-code summary

| Code | Meaning in v0.1.0 |
|------|-------------------|
| 200  | OPTIONS, GET, HEAD |
| 201  | created (PUT new, MKCOL, MOVE to new) |
| 204  | overwrote / deleted (PUT overwrite, DELETE, MOVE overwrite) |
| 207  | PROPFIND, PROPPATCH multistatus |
| 403  | reserved name, `Depth: infinity`, forbidden PROPPATCH prop |
| 404  | missing resource |
| 405  | MKCOL on existing collection |
| 409  | nested path / missing parent / COPY unsupported |
| 412  | `Overwrite: F` on existing dest, or CAS race lost |
| 501  | folder GET (zip/tar), chunked upload, other out-of-scope methods |
