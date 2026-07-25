# lunet-dav — Test Plan (v0.1.0)

> **Alpha.** This plan, like the spec, is provisional and subject to u-turns and fully
> breaking changes during the 0.x.y alpha (see [`../AGENTS.md`](../AGENTS.md)).

Two layers:

1. **Unit tests** — pure Lua logic, no network/DB/S3. Fast, deterministic, run first.
2. **Compatibility (integration) tests** — Hurl 8.x against a running server + MinIO +
   PG. These are the *contract*; a feature is "done" when its hurl file goes green.

The linear build order is: make a unit go green → make its hurl file go green → next.

---

## 1. Unit test suite

### 1.1 Harness
- Framework: **busted** (standard LuaJIT-compatible), run via `mise exec -- busted`.
- Location: `spec/unit/*_spec.lua` (mirrors `app/` and `lib/` module names).
- No DB/S3/socket access in unit tests. Anything touching those is exercised only
  through the hurl layer, or through an injected **fake** (see §1.3).
- Determinism: token/randomness seams accept an injected generator so tests assert
  exact values (e.g. a stub returning `"tok_fixed"`); time seams accept an injected
  clock.

### 1.2 Units under test (function → cases)

**Behavior configuration** (`app/behavior.lua`)
- `resolve(overrides)` layering: defaults < `.env` < real env vars.
- Defaults reproduce the v0.1.0 wire contract (`DAV_EMIT_HASH_HEADER=on-request`,
  `S3_API_PROFILE=lcd`, empty passthrough allowlist, `_landing/`, pad width 8,
  instance id `oczn5x60nrdu`, `DAV_MAX_UPLOAD_BYTES` 512 MiB).
- Coercion: `DAV_FILEID_PAD_WIDTH` to number; `DAV_PUT_PASSTHROUGH_HEADERS` comma-list
  to a trimmed set (empty string → empty set).
- Enum validation: bad `S3_API_PROFILE` / `DAV_EMIT_HASH_HEADER` values rejected with
  a named error; unknown keys rejected.

**HTTP request reader** (`lib/http.lua` + `spec/unit/http_spec.lua`)
- `read_request(client, opts)` with a fake `lunet.socket`:
  - fragmented request (headers in 2 chunks, body in 3) → correct body.
  - `Expect: 100-continue` → `100 Continue` written before body reads.
  - `Transfer-Encoding: chunked` → 501.
  - PUT without `Content-Length` → 411.
  - `Content-Length` > `opts.max_body_bytes` → 413.
  - mid-body EOF → 400 truncation error.
  - header block > 64 KB → 400.
  - GET with no body → empty body string.

**PROPFIND / PROPPATCH XML** (`app/dav_xml.lua` + `spec/unit/dav_xml_spec.lua`)
- `parse_propfind(body)` → the set of requested prop {ns,name} pairs; namespace
  prefixes resolved from the declarations (`d`,`oc`,`nc`,`lnt`); `allprop` and empty
  body both yield the default set.
- `parse_propertyupdate(body)` → `{set=[{ns,name,value/tags}], remove=[{ns,name}]}`
  with namespace-aware parsing.
- Malformed XML → nil + error message.

**Identity / headers** (`app/dav_identity.lua`, planned)
- `oc_fileid(id, pad_width, instance_id)`:
  - 259, 8, "oczn5x60nrdu" → `"00000259oczn5x60nrdu"`.
  - 1 → `"00000001oczn5x60nrdu"`; a 9-digit id → no truncation (documents overflow
    choice).
- `quote_etag(raw)` → wraps once, idempotent on already-quoted input.

**PUT response header policy** (`app/nc31.lua` seams, planned `app/dav_headers.lua`)
- hash header: `on-request` emits only when the request carries `X-Hash: sha256`;
  `always` emits unconditionally; `never` suppresses.
- passthrough: allowlisted names present in the harvested upstream table are copied
  verbatim; names absent from the harvest are skipped; empty allowlist copies nothing.
- non-allowlisted upstream headers never appear.

**Path model** (`app/dav_path.lua`, planned)
- `parse("/remote.php/dav/files/bob/team/a.txt")` → `{user="bob", collection="team", name="a.txt"}`.
- root, single-file (`/…/bob/a.txt`), and collection-only forms.
- reserved: name/collection starting `_` → rejected with a `reserved` reason.
- nested: `/…/bob/a/b/c.txt` (>1 level) → rejected with a `nested` reason.
- slash-in-name and empty-name edge cases.

**Content addressing** (`lib/crypto.lua` + `app/dav_store.lua`, planned)
- `sha256_hex("hello\n")` == `5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03`.
- `object_key(sha, prefix)` == `prefix .. sha` (default prefix `_landing/`).

**S3 capability profiles** (`lib/s3.lua` + `spec/unit/s3_spec.lua`)
- `profile("lcd")` → no checksum request headers, no harvest, no follow-up.
- `profile("minio" | "minio-enterprise")` → PUT carries
  `x-amz-checksum-sha256` (base64 of the raw sha256); harvest extracts
  `x-amz-checksum-sha256` from PutObject/HeadObject response headers; follow-up
  HeadObject fires only when the profile advertises checksums and the PUT response
  omitted the header.
- Request construction remains path-style + SigV4 for all profiles (string-building
  only; no sockets in unit tests).

**Op-log & tags** (`app/dav_oplog.lua`, planned)
- `append_row(info, {ts,who,type,data})` appends a 4-element row to `info.oplog`.
- `fold_tags(requested, stored)`:
  - identical sets → no ops appended.
  - added tags → one `set-label` op each; removed tags → one `unset-label` op each.
  - result set is exactly the requested set.
- `oplog_json(info)` → JSON array of `[ts,who,type,data]` rows (for `lnt:oplog`).

**CAS SQL** (`app/dav_repo.lua`, planned — string-building only, no execution)
- Builds an `UPDATE … SET version = version + 1 … WHERE id=$ AND version=$ RETURNING …`.
- asserts the `version` guard and `RETURNING mtime, etag` are present.
- `interpret_result(rowcount)` → `ok` vs `cas_conflict` (0 rows → 412).

**OCS** (`app/ocs.lua`, planned)
- `envelope(status, statuscode, message, data)` → correct nested shape; `status`
  derives from statuscode (`200`→"ok", else "failure").
- `project_user(user_row)` → `{id, display-name, email, enabled, quota}` with `id` and
  `display-name` = username and `quota` = the unlimited placeholder.
- `http_status_for(statuscode)` mirrors 200/997/403/998 → 200/401/403/400.

**Login Flow v2** (`app/loginflow.lua`, planned)
- `new_tokens(gen)` → distinct opaque `poll_token`/`login_token` from the injected gen.
- `init_response(base, poll_token, login_token)` → `{poll:{token,endpoint}, login}`
  with `endpoint == base .. "/login/v2/poll"` and `login` embedding the login token.
- `poll_result(row)`:
  - `completed_at == nil` → `pending` (→404).
  - completed, `polled_at == nil` → `{server, loginName, appPassword}` (→200), marks
    consumed.
  - completed, `polled_at ~= nil` → `pending` (→404, one-time semantics).

**App passwords** (`app/app_password.lua`, planned)
- `verify(user_rows, presented)` → true iff any row's Argon2 hash matches (uses real
  `app/password.lua`; a known hash/plaintext fixture pair).
- non-match and empty-list → false.

**shared store JSON boundary** (`app/nc31.lua`'s `store_set_json`/`store_get_json`, exists)
- `lunet.lnt_shared` itself is a real, upstream-tested native library (v0.4.3+); we
  don't re-test its CRUD/TTL semantics. What we do unit-test is our JSON
  encode/decode boundary:
- `store_set_json` round-trips a Lua table through `cjson.encode` into the store.
- `store_get_json` on an absent key returns `nil, nil` (translates the store's
  `nil, "not found"` so call sites don't treat "absent" as an error).
- `store_get_json` on any other error passes the error through unchanged.
- These can run against a real `lunet.lnt_shared` dict (fast, in-process, no DB)
  rather than a fake, since the boundary logic is what's under test.

### 1.3 Fakes / seams
- **Fake S3 client**: in-memory `{put, get, head, get_bucket_versioning}` returning
  canned version ids / checksums; lets store logic be unit-tested without MinIO.
- **DB seam**: repo modules build SQL + params and take a `query` function; unit tests
  pass a spy that records SQL/params and returns canned rows. No real Postgres in unit
  tests.
- **Clock / token generator**: injected; default to real impls in production wiring.
- **Env seam**: `behavior.resolve` takes an explicit overrides table in tests instead
  of touching process env.

---

## 2. Compatibility (hurl) test suite

Runner: [`../specs/run-compat-tests-hurl.sh`](../specs/run-compat-tests-hurl.sh)
(globs `specs/dav`, `specs/ocs`, `specs/loginflow`). Prereqs: server on loopback, a
MinIO bucket with **versioning enabled** (the server refuses to start without it, and
file bytes are stored in S3 — not Postgres), and a migrated Postgres. `make e2e`
provisions all of this ephemerally and additionally hard-gates that PUT bytes really
landed in the bucket (object count > 0 and the known `"hello\n"` digest key present).

### 2.1 Inventory
| File | Covers |
|------|--------|
| `specs/dav/00_options.hurl` | OPTIONS capabilities |
| `specs/dav/01_mkcol.hurl` | MKCOL create / 405 / 403 reserved / 409 nested |
| `specs/dav/02_put.hurl` | PUT create/overwrite, OC-FileId stability, X-Hash, 409s |
| `specs/dav/03_get_head.hurl` | GET/HEAD bytes+headers, 404, folder-GET 501 |
| `specs/dav/04_propfind.hurl` | 207 Depth 0/1, props, quota, Depth:infinity 403, 404 |
| `specs/dav/05_move.hurl` | rename/move (stable id), Overwrite F/T, reserved dest |
| `specs/dav/06_copy_unsupported.hurl` | COPY → 409 d:error |
| `specs/dav/07_delete.hurl` | file + recursive collection delete, 404 |
| `specs/dav/08_proppatch_tags.hurl` | tag set/unset folding; favorite → 403 |
| `specs/dav/09_lnt_debug.hurl` | lnt debug props (unstable) |
| `specs/dav/10_errors.hurl` | cross-cutting status codes |
| `specs/dav/12_root_files.hurl` | root-level files, percent-decoded paths |
| `specs/config/put_headers.hurl` | `DAV_EMIT_HASH_HEADER=always` + passthrough allowlist + persisted upstream checksum (e2e second pass, non-default env) |
| `specs/loginflow/00_flow_v2.hurl` | init → poll(404) → grant → poll(200) → poll(404) |
| `specs/loginflow/01_errors.hurl` | bad login-token 404, bad creds 403, unknown poll 404 |
| `specs/ocs/00_current_user.hurl` | /cloud/user + /cloud/users/{self} 200 + envelope |
| `specs/ocs/01_forbidden_and_headers.hurl` | other user 403, missing header 997, xml 998 |
| `specs/ocs/02_no_auth.hurl` | no Basic auth → 401/997 |
| `specs/chassis/auth.hurl`, `errors_auth.hurl`, `profiles.hurl`, `errors_profiles.hurl` | retained chassis auth/profiles |

`specs/config/put_headers.hurl` runs as a second e2e pass against a server started
with `S3_API_PROFILE=minio`, `DAV_EMIT_HASH_HEADER=always`, and
`DAV_PUT_PASSTHROUGH_HEADERS=x-amz-version-id,x-amz-checksum-sha256`. It is kept out
of the default compat glob: under defaults its assertions fail by design. All other
suites run under defaults, which reproduce the v0.1.0 wire contract exactly.

### 2.2 Cross-surface end-to-end
The OCS and Login Flow files chain the full real path within a single file (Hurl
captures are per-file): register a user (residual `/api/users`) → Login Flow v2 to
mint an app password → use `[BasicAuth] loginName: appPassword` against OCS. This is
the exact sequence a native client performs, so the happy-path files double as an
integration smoke test.

### 2.3 Automated e2e (`make e2e`)
[`../e2e/run-e2e.sh`](../e2e/run-e2e.sh) is the fully automated wrapper: it brings up
ephemeral Postgres 16 + MinIO (versioned bucket) via
[`../e2e/docker-compose.yml`](../e2e/docker-compose.yml) — pull-only linux/arm64
images on colima, no mounts, no BuildKit — applies the schema, starts the server on a
high loopback port (18081), runs the chassis suite and the full compat suite, then:

- **Transport probe:** a POSIX-sh `/dev/tcp` fragmented PUT with `Expect:
  100-continue` — headers sent, `sleep 0.3`, body sent — followed by a GET that
  asserts the sha256 matches the sent bytes. Exercises the bounded HTTP reader and
  100-continue handling end-to-end.
- **MinIO byte gate:** hard-gates that PUT bytes really landed in MinIO (object count,
  known content-addressed key, byte-for-byte sha, single retained version).
- **Secret-null assertion:** after a Login Flow v2 poll, psql asserts the
  `app_passwords.secret` column is `NULL` for the collected row.

Environment lives in [`../e2e/e2e.env`](../e2e/e2e.env) and is exported wholesale so
the server child process actually sees it.

### 2.4 Fixtures & conventions
- `{{uid}}` (unique per run) namespaces users/collections to avoid cross-run
  collisions.
- Known digest: `sha256("hello\n") = 5891b5b5…be03`.
- XML asserted via `xpath` with `local-name()` to avoid namespace-prefix binding.
- Login/app tokens are **captured**, never hard-coded (the server mints them).
