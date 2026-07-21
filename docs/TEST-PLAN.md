# lunet-dav — Test Plan (v0.1.0)

> **Scaffolding.** This plan, like the spec, is provisional and subject to u-turns and
> fully breaking changes during the 0.x.y alpha (see [`../AGENTS.md`](../AGENTS.md)).

Two layers, both **RED until the server exists** (Red/Green TDD):

1. **Unit tests** — pure Lua logic, no network/DB/S3. Fast, deterministic, run first.
2. **Compatibility (integration) tests** — Hurl 8.x against a running server + MinIO + PG.
   These are the *contract*; a feature is "done" when its hurl file goes green.

The linear build order is: make a unit go green → make its hurl file go green → next.

---

## 1. Unit test suite

### 1.1 Harness
- Framework: **busted** (standard LuaJIT-compatible), run via `mise exec -- busted`.
- Location: `spec/unit/*_spec.lua` (mirrors `app/` and `lib/` module names).
- No DB/S3/socket access in unit tests. Anything touching those is exercised only through
  the hurl layer, or through an injected **fake** (see §1.3).
- Determinism: token/randomness seams accept an injected generator so tests assert exact
  values (e.g. a stub returning `"tok_fixed"`); time seams accept an injected clock.

### 1.2 Units under test (function → cases)

**Identity / headers** (`app/dav_identity.lua`, planned)
- `oc_fileid(id, pad_width, instance_id)`:
  - 259, 8, "oczn5x60nrdu" → `"00000259oczn5x60nrdu"`.
  - 1 → `"00000001oczn5x60nrdu"`; a 9-digit id → no truncation (documents overflow choice).
- `quote_etag(raw)` → wraps once, idempotent on already-quoted input.

**Path model** (`app/dav_path.lua`, planned)
- `parse("/remote.php/dav/files/bob/team/a.txt")` → `{user="bob", collection="team", name="a.txt"}`.
- root, single-file (`/…/bob/a.txt`), and collection-only forms.
- reserved: name/collection starting `_` → rejected with a `reserved` reason.
- nested: `/…/bob/a/b/c.txt` (>1 level) → rejected with a `nested` reason.
- slash-in-name and empty-name edge cases.

**Content addressing** (`lib/crypto.lua` + `app/dav_store.lua`, planned)
- `sha256_hex("hello\n")` == `5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03`.
- `object_key(sha)` == `"_landing/" .. sha`.

**Op-log & tags** (`app/dav_oplog.lua`, planned)
- `append_row(log, {ts,who,type,data})` returns a rectangular 4-col row (shape check).
- `replay_tags(log)`:
  - `[]` → `{}`.
  - set red, set urgent → `{red, urgent}`.
  - set red, set urgent, unset urgent → `{red}`.
  - unset before set (no-op) → `{}`.
  - **order matters**: set A, unset A, set A → `{A}`.
- `oplog_json(log)` → JSON array of `[ts,who,type,data]` rows (for `lnt:oplog`).

**CAS SQL** (`app/dav_repo.lua`, planned — string-building only, no execution)
- Builds an `UPDATE … SET version = version + 1 … WHERE id=$ AND version=$ RETURNING …`.
- asserts the `version` guard and `RETURNING mtime, etag` are present.
- `interpret_result(rowcount)` → `ok` vs `cas_conflict` (0 rows → 412).

**PROPFIND XML** (`app/dav_xml.lua`, planned)
- `parse_propfind(body)` → the set of requested prop {ns,name} pairs; namespace prefixes
  resolved from the declarations (`d`,`oc`,`nc`,`lnt`).
- `build_multistatus(entries, requested)` → 207 doc with `d:response`/`d:propstat`, and
  unsupported props placed in a `404` propstat.
- `build_error("COPY…")` → `d:error` doc with `s:message`.

**OCS** (`app/ocs.lua`, planned)
- `envelope(status, statuscode, message, data)` → correct nested shape; `status` derives
  from statuscode (`200`→"ok", else "failure").
- `project_user(user_row)` → `{id, display-name, email, enabled, quota}` with `id` and
  `display-name` = username and `quota` = the unlimited placeholder.
- `http_status_for(statuscode)` mirrors 200/997/403/998 → 200/401/403/400.

**Login Flow v2** (`app/loginflow.lua`, planned)
- `new_tokens(gen)` → distinct opaque `poll_token`/`login_token` from the injected gen.
- `init_response(base, poll_token, login_token)` → `{poll:{token,endpoint}, login}` with
  `endpoint == base .. "/login/v2/poll"` and `login` embedding the login token.
- `poll_result(row)`:
  - `completed_at == nil` → `pending` (→404).
  - completed, `polled_at == nil` → `{server, loginName, appPassword}` (→200), marks consumed.
  - completed, `polled_at ~= nil` → `pending` (→404, one-time semantics).

**App passwords** (`app/app_password.lua`, planned)
- `verify(user_rows, presented)` → true iff any row's Argon2 hash matches (uses real
  `app/password.lua`; a known hash/plaintext fixture pair).
- non-match and empty-list → false.

**store mock** (`app/store.lua`, exists — the lunet#103 stand-in)
- `set`/`get` round-trip a JSON value; `get` on absent key → nil (no error).
- lazy TTL: a key set with a past-equivalent short TTL is absent after expiry.
- `add` → true when absent, false when a live entry exists (single-flight).
- `incr` → creates with `init+delta`, then accumulates; used for throttle counters.
- `delete` removes the entry.
- **not-implemented guard**: any unmocked member (e.g. `store.expire(...)`) raises
  "not implemented in the Lua mock (see lunet#103)".
- These run against a real Postgres (the mock's backing) rather than through a fake, since
  the mock *is* the thing under test; they double as the store hurl contract at unit level.

### 1.3 Fakes / seams
- **Fake S3 client**: in-memory `{put, get, head, delete, get_bucket_versioning}` returning
  canned version ids; lets store logic be unit-tested without MinIO.
- **DB seam**: repo modules build SQL + params and take a `query` function; unit tests pass
  a spy that records SQL/params and returns canned rows. No real Postgres in unit tests.
- **Clock / token generator**: injected; default to real impls in production wiring.

---

## 2. Compatibility (hurl) test suite

Runner: [`../specs/run-compat-tests-hurl.sh`](../specs/run-compat-tests-hurl.sh) (globs
`specs/dav`, `specs/ocs`, `specs/loginflow`). Prereqs when green-phase begins: server on
loopback, a MinIO bucket with **versioning enabled**, and a migrated Postgres.

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
| `specs/dav/08_proppatch_tags.hurl` | tag set/unset via op-log replay; favorite → 403 |
| `specs/dav/09_lnt_debug.hurl` | lnt debug props (unstable) |
| `specs/dav/10_errors.hurl` | cross-cutting status codes |
| `specs/loginflow/00_flow_v2.hurl` | init → poll(404) → grant → poll(200) → poll(404) |
| `specs/loginflow/01_errors.hurl` | bad login-token 404, bad creds 403, unknown poll 404 |
| `specs/ocs/00_current_user.hurl` | /cloud/user + /cloud/users/{self} 200 + envelope |
| `specs/ocs/01_forbidden_and_headers.hurl` | other user 403, missing header 997, xml 998 |
| `specs/ocs/02_no_auth.hurl` | no Basic auth → 401/997 |
| `specs/store/00_store_mock.hurl` | store mock: set/get, add single-flight, incr, delete, TTL expiry (via `[Options] delay`) |
| `specs/chassis/auth.hurl`, `errors_auth.hurl`, `profiles.hurl`, `errors_profiles.hurl` | retained chassis auth/profiles |

### 2.2 Cross-surface end-to-end
The OCS and Login Flow files chain the full real path within a single file (Hurl captures
are per-file): register a user (residual `/api/users`) → Login Flow v2 to mint an app
password → use `[BasicAuth] loginName: appPassword` against OCS. This is the exact sequence
a native client performs, so the happy-path files double as an integration smoke test.

### 2.3 Fixtures & conventions
- `{{uid}}` (unique per run) namespaces users/collections to avoid cross-run collisions.
- Known digest: `sha256("hello\n") = 5891b5b5…be03`.
- XML asserted via `xpath` with `local-name()` to avoid namespace-prefix binding.
- Login/app tokens are **captured**, never hard-coded (the server mints them).
