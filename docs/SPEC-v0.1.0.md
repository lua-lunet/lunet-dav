# lunet-dav — v0.1.0 Wire Spec

The precise, testable contract enforced by the compat suites under `specs/`. Behaviour
mirrors NextCloud Enterprise 31 for the subset we implement. Everything here is what a
client on the wire observes.

> **Alpha.** Every decision below is provisional and subject to u-turns and fully
> breaking changes during the 0.x.y alpha (see [`../AGENTS.md`](../AGENTS.md)).

This spec covers three surfaces — the complete set used against the author's NC E31 instance:
1. **WebDAV files** (`/remote.php/dav/files/...`) — see [reference](reference/nextcloud-webdav-basic-v31.md).
2. **OCS user metadata** (`/ocs/v2.php/cloud/...`) — see [reference](reference/nextcloud-ocs-user-v31.md).
3. **Login Flow v2** (`/index.php/login/v2`, `/login/v2/...`) — see [reference](reference/nextcloud-loginflow-v2-v31.md).

## WebDAV files

- **Base path:** `/remote.php/dav/files/{user}/{path}`
- **`{user}`:** any token; from Basic auth or the path. Not validated in v0.1.0.
- **`{path}`:** flat — either `` (root), `{collection}`, `{name}`, or `{collection}/{name}`.
- **Auth:** `Authorization: Basic ...` parsed; username → `oplog.who`. Password ignored
  in v0.1.0. The chassis JWT/user machinery (`users` table, `app/jwt.lua`,
  `app/password.lua`, `app/auth_routes.lua`) is retained to gate the DAV surface in a
  later version; it is not wired into DAV requests yet.

## Identity & headers

- `OC-FileId = lpad(id, DAV_FILEID_PAD_WIDTH, "0") + DAV_INSTANCE_ID`
  → e.g. id 259 → `00000259oczn5x60nrdu`. Stable across overwrite/move.
- `OC-Etag` = the stored S3 ETag, emitted **quoted**, e.g. `"50ef2eba...a5ef"`.
- `oc:id` == `OC-FileId`; `oc:fileid` == numeric `id`.
- `X-Hash-SHA256` on PUT responses is governed by `DAV_EMIT_HASH_HEADER`:
  `on-request` (default) — present only when the request carries `X-Hash: sha256`;
  `always` — present on every PUT response; `never` — suppressed.
- When the request carries `X-OC-MTime`/`X-OC-CTime`, the response echoes
  `X-OC-MTime: accepted` / `X-OC-CTime: accepted` (the header is accepted; server
  timestamps remain authoritative).
- `DAV_PUT_PASSTHROUGH_HEADERS` (default empty): upstream response headers named in
  this allowlist and harvested from the upstream exchange are copied verbatim onto PUT
  responses; unharvested names are skipped (see Configuration).

## Configuration

Behavior keys are resolved once at startup (Lua defaults → `.env` → environment;
unknown keys rejected). Defaults reproduce this spec exactly.

| Key | Values | Default |
|-----|--------|---------|
| `DAV_INSTANCE_ID` | string | `oczn5x60nrdu` |
| `DAV_FILEID_PAD_WIDTH` | integer 1–32 | `8` |
| `S3_LANDING_PREFIX` | string | `_landing/` |
| `S3_API_PROFILE` | `lcd` \| `minio` \| `minio-enterprise` | `lcd` |
| `DAV_EMIT_HASH_HEADER` | `on-request` \| `always` \| `never` | `on-request` |
| `DAV_PUT_PASSTHROUGH_HEADERS` | comma-list of upstream header names | *(empty)* |

Under `S3_API_PROFILE=lcd` the upstream exchange is classic SigV4 only. Under a
checksum-capable profile (`minio`, `minio-enterprise`) `PutObject` additionally
carries `x-amz-checksum-sha256` (the upstream verifies the transfer), the returned
checksum is harvested — via one `HeadObject` follow-up if the PUT response omits it —
and persisted in `dav_files.info.upstream`. None of this is visible on the DAV wire
unless `DAV_PUT_PASSTHROUGH_HEADERS` names the headers.

---

## OPTIONS

`OPTIONS {base}/{path}` → **200**, headers:
- `DAV: 1` (class-1; locks are not implemented)
- `Allow: OPTIONS, GET, HEAD, PUT, DELETE, MKCOL, MOVE, PROPFIND, PROPPATCH`
- `MS-Author-Via: DAV`

---

## PUT — upload

`PUT {base}/{collection}/{name}` with raw body.

Server: sha256(body) → key `<landing-prefix><sha256>` → reuse a matching live metadata
locator or retained S3 version (`HeadObject`) → `PutObject` only when the digest is
absent (under a checksum-capable profile with `x-amz-checksum-sha256`; an upstream
checksum rejection fails the request) → upsert `dav_files` row (CAS if it exists,
INSERT if new).

Responses:
- **201 Created** — new file. Headers: `OC-FileId`, `OC-Etag`, `Content-Length: 0`,
  plus config-gated extras (see Identity & headers).
- **204 No Content** — overwrote an existing path. Same headers.
- **409 Conflict** — parent collection segment does not exist, or path is nested more
  than one level, or targets a reserved (`_`-prefixed) collection.
- **412 Precondition Failed** — CAS lost a concurrent write race.

Same content re-PUT to the same path reuses the stored S3 VersionId: sha256/key remain
unchanged, the metadata `version` bumps, and a `put` op is appended.

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

## COPY — not implemented

`COPY {base}/{src}` → **409 Conflict**, body is a DAV error XML explaining that COPY
is not implemented in v0.1.0. May arrive later as metadata-only locator reuse.

---

## PROPFIND — list / read properties

`PROPFIND {base}/{path}` with `Depth: 0` (this resource) or `Depth: 1` (resource +
direct children). Body: `d:propfind` requesting properties. Response: **207
Multi-Status** `application/xml`, a `d:multistatus` with one `d:response` per
resource. Each `d:href` is the full DAV path including the `{user}` segment.

Supported properties (others returned in `404 propstat`):

**DAV (`d:`)**: `getlastmodified` (mtime), `creationdate` (ctime, ISO 8601),
`getetag` (quoted), `getcontenttype` (files), `getcontentlength` (files),
`resourcetype` (`<d:collection/>` for collections), `displayname` (= name),
`quota-available-bytes` = `-3` (unlimited), `quota-used-bytes` = `0`.

**ownCloud (`oc:`)**: `id` (= OC-FileId), `fileid` (= numeric id),
`permissions` = `RGDNVW` (static, no sharing), `size`, `favorite` = `0` (static),
`tags` (the materialized `info.tags` set), `checksums`
(`<oc:checksum>SHA-256:<hex></oc:checksum>`).

**NextCloud (`nc:`)**: `has-preview` = `false`, `is-encrypted` = `0`,
`contained-file-count` / `contained-folder-count` (collections), `mount-type` = ``.

**lunet (`lnt:`, unstable/debug — `http://lunet.stenographer.cloud/ns`)**:
`sha256`, `s3-version-id`, `cas-version`, `collection`,
`oplog` (full op-log as a JSON array of `[ts,who,type,data]` rows),
`upstream-checksum` (harvested upstream checksum, present only under a
checksum-capable `S3_API_PROFILE`).

Missing path → **404**. `Depth: infinity` → **403** (flat namespace; not needed).

---

## PROPPATCH — set tags only

`PROPPATCH {base}/{path}` → **207 Multi-Status**.
- Setting `<oc:tags><oc:tag>x</oc:tag>...</oc:tags>` folds the requested set against
  the stored set, appends the diff as `set-label`/`unset-label` ops, and stores the
  new materialized set in one CAS write; each prop returns `200` propstat.
- `<oc:favorite>` → `403` propstat (needs a user table; `NOT IN v0.1.0`).
- Any other settable property → `403` propstat.

---

## Error body shape

WebDAV error responses (`4xx`/`5xx` other than `207`) carry a `d:error` XML document:

```xml
<?xml version="1.0" encoding="utf-8"?>
<d:error xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns">
  <s:exception>Lunet\Dav\Exception\Unsupported</s:exception>
  <s:message>COPY is not implemented in v0.1.0</s:message>
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

---

# Login Flow v2

Lets a native app mint an **app password** by sending the user to the system browser.
Two backing stores with a clean split of duties:
- **`lunet.lnt_shared`** ([`../app/nc31.lua`](../app/nc31.lua), vendored at
  [`../bin/lunet/`](../bin/lunet/) — see [`DESIGN.md`](DESIGN.md) §12.0) holds all
  **transient** flow state (token→status), TTL-matched to the flow timeout (~20 min).
  The poller hits only the shared store, never Postgres, while a flow is incomplete —
  so abandoned flows put **zero** DB pressure. If the shared store is lost (crash),
  in-flight flows are abandoned ("tough luck") — acceptable, the slow part is the
  human clicking through the browser.
- **`app_passwords`** (Postgres, [`../sql/auth_schema.sql`](../sql/auth_schema.sql))
  holds the durable app-password lifecycle via single-row CAS:
  `pending → ready → collected`.

**Secret handling:** the plaintext app password lives **only in Postgres** (the
`app_passwords.secret` column, between `ready` and `collected`). It is **never written
to** the shared store — the shared store carries only a status flag and never holds
the secret.

**Abuse:** on init we best-effort throttle via the shared store's `:incr` keyed by
client IP (TTL = flow timeout). Over a low threshold → **429**. This is deliberately
*not* strict single-flight (init is anonymous — no user to key on): we accept that
abuse can create many abandoned `pending` rows and "soak it up" rather than do
per-user bookkeeping.

## Initiate — `POST /index.php/login/v2`
Anonymous. `User-Agent` becomes the app-password `name`. On accept the server:
1. shared store `:incr("lf:init:<client-ip>", 1, 0, ttl)` — over threshold → **429**.
2. `INSERT app_passwords (status='pending', name=<User-Agent>) RETURNING id` — the handle.
3. Generates opaque `poll_token` + `login_token`.
4. shared store `:set("lf:poll:<poll_token>", json{status:'pending', app_password_id:<id>}, ttl)`
   and `:set("lf:login:<login_token>", json{app_password_id:<id>, poll_token:<poll_token>}, ttl)`
   (JSON-encoded — the shared store natively holds only strings/numbers/booleans).

Response **200** JSON:
```json
{ "poll": { "token": "<poll-token>", "endpoint": "{base}/login/v2/poll" },
  "login": "{base}/login/v2/flow?token=<login-token>" }
```

## Browser flow — `GET /login/v2/flow?token=<login-token>`
The URL the app opens in the **system browser**. **The contract is specified but no
web UI is built yet.** When built, the page is a three-step guard against a
hidden-window / already-logged-in attack:
1. **Login** — the user authenticates (they may already have a browser session).
2. **Grant warning** — "You are being asked to approve client *<User-Agent>* to access
   your data. **Close this window if you did not start this and are unsure.**"
3. **Password reconfirm** — the user re-enters their password (defeats an attacker
   driving a pre-authenticated browser off-screen). This confirmation gates the grant.

Invalid/expired `login-token` (no `lf:login:*` entry in the shared store) → **404**.

## Grant (completes the browser flow) — `POST /login/v2/grant`
What step 3 submits. Body (form-encoded): `token=<login-token>`, `loginName`, `password`.
1. Look up `lf:login:<login-token>` in the shared store → `app_password_id` (+ `poll_token`). Missing → **404**.
2. Verify `loginName`+`password` against `users` (Argon2, `app/password.lua`). Bad → **403**.
3. Mint the app password; CAS `app_passwords`: `pending → ready`, writing `user_id`,
   `password_hash` (Argon2), and `secret` (one-time plaintext), `mtime=now()`.
4. shared store `:set("lf:poll:<poll_token>", json{status:'ready', app_password_id:<id>}, ttl)`
   — flag only; the secret is **not** placed in the shared store.
- **200** — granted. **403** — bad credentials. **404** — unknown/expired login token.
> Upstream folds grant into its own web UI; we expose a discrete endpoint so the
> future browser page (and the hurl tests) have a concrete call.

## Poll — `POST {base}/login/v2/poll`
Body (form-encoded): `token=<poll-token>`. Reads the **shared store** first:
- No `lf:poll:*` entry, or `status == 'pending'` → **404** (keep polling). No DB hit.
- `status == 'ready'` → CAS `app_passwords` `ready → collected` returning `secret`;
  then shared store `:delete("lf:poll:<poll_token>")`. Response **200**, once:
```json
{ "server": "{base}", "loginName": "<user>", "appPassword": "<app-password>" }
```
- A second poll after the one-time 200 → **404** (entry gone / row already `collected`).

## Using the app password
Later OCS/DAV requests use `Authorization: Basic base64(loginName:appPassword)`,
verified against the now-`collected` row's `password_hash`.

---

# OCS API (user metadata subset)

Basic security: **a user can see only their own details.** Backed by the residual
`users` table; authenticated by Basic auth resolving an `app_passwords` row.

- Base: `/ocs/v2.php/cloud/...`. **Requires** header `OCS-APIRequest: true`.
- **Requires** `?format=json` (XML is `NOT IN v0.1.0`).
- Auth: `Authorization: Basic base64(loginName:appPassword)`. The server looks up the
  user by `loginName`, then Argon2-verifies the app password against that user's
  `app_passwords`.

## Envelope
All responses (success and failure) use the OCS v2 envelope, and the **HTTP status
mirrors `ocs.meta.statuscode`**:
```json
{ "ocs": { "meta": { "status": "ok", "statuscode": 200, "message": "OK" }, "data": { ... } } }
```

## `GET /ocs/v2.php/cloud/user`
The authenticated user's own metadata. **200**, `ocs.data` subset we can actually source:
```json
{ "id": "<username>", "display-name": "<username>", "email": "<email>",
  "enabled": true, "quota": { "quota": -3, "used": 0, "free": -3, "total": -3, "relative": 0 } }
```
- `id` and `display-name` = the username (no separate display-name column yet).
- `quota` values are the unlimited placeholder (`-3`), matching DAV quota.
- Missing/invalid Basic auth or missing `OCS-APIRequest` header → **401**,
  `ocs.meta.statuscode` `997`.

## `GET /ocs/v2.php/cloud/users/{userid}`
- If `{userid}` == authenticated username → same body as `/cloud/user` (**200**).
- If `{userid}` != authenticated username → **403**, `ocs.meta.statuscode` `403`
  (no admin role exists in v0.1.0; a default user can only see themselves).
- Unknown user (only reachable as self) → not applicable in v0.1.0.

## OCS status-code summary
| HTTP | `ocs.meta.statuscode` | Meaning |
|------|-----------------------|---------|
| 200  | 200 | success |
| 401  | 997 | not authenticated / missing `OCS-APIRequest` header |
| 403  | 403 | authenticated but forbidden (another user's details) |
| 400  | 998 | bad request (e.g. `format` other than `json`) |
