-- lunet-dav auth schema (PostgreSQL 16) — SCAFFOLDING, subject to breaking changes.
-- Backs OCS user metadata (basic security: a user sees only their own details) and
-- Login Flow v2 (app-password minting via the system browser). Depends on the residual
-- `users` table from the chassis bootstrap schema (sql/schema.sql). See docs/SPEC-v0.1.0.md.
--
-- PIVOT NOTE: transient Login Flow v2 polling state does NOT live here — that would put
-- DB pressure on incomplete/abandoned flows. It lives in lunet's shared in-process store
-- (require("lunet.lnt_shared"), see app/nc31.lua) with a TTL matching the flow timeout.
-- This table holds only the durable app-password lifecycle. The earlier
-- `login_flow_tokens` table was dropped for this reason.

-- App passwords + the Login Flow v2 lifecycle. A separate table from `users` so an app
-- credential can be revoked independently of the real password.
--
-- Lifecycle (single-row CAS transitions; see docs/SPEC-v0.1.0.md):
--   pending  : placeholder inserted at flow init. No user, no materials yet. This row's id
--              is the handle the browser grant and the poller work against.
--   ready    : grant completed (user confirmed their password in the browser). user_id +
--              password_hash written; `secret` holds the one-time plaintext for the poller.
--   collected: the poller retrieved the app password exactly once; `secret` is cleared.
-- Only a 'collected' row is a usable app password (Basic auth verifies against password_hash).
CREATE TABLE IF NOT EXISTS app_passwords (
    id            BIGSERIAL PRIMARY KEY,
    -- NULL until grant (flow init is anonymous; the user is identified in the browser).
    user_id       INTEGER     REFERENCES users(id) ON DELETE CASCADE,
    -- Argon2id hash (via app/password.lua). Verified on Basic auth. NULL until grant.
    password_hash TEXT,
    -- One-time plaintext app password, transient: set at grant, returned by /poll ONCE and
    -- then cleared. Lives only in the DB (never in `store`), only between ready and collected.
    secret        TEXT,
    status        TEXT        NOT NULL DEFAULT 'pending'
                              CHECK (status IN ('pending', 'ready', 'collected')),
    -- Human label; defaults to the initiating User-Agent per Login Flow v2.
    name          TEXT        NOT NULL DEFAULT 'app',
    ctime         TIMESTAMPTZ NOT NULL DEFAULT now(),
    mtime         TIMESTAMPTZ NOT NULL DEFAULT now(),   -- bumped on each CAS; ctime->mtime = flow duration
    last_used_at  TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_app_passwords_user ON app_passwords (user_id);

-- Example CAS transitions (parameters filled by the app):
--   grant   (pending -> ready):
--     UPDATE app_passwords SET status='ready', user_id=$2, password_hash=$3, secret=$4,
--            name=$5, mtime=now()
--      WHERE id=$1 AND status='pending' RETURNING id;
--   collect (ready -> collected):
--     WITH old AS (
--         SELECT id, secret FROM app_passwords WHERE id = $1 AND status = 'ready'
--     )
--     UPDATE app_passwords a
--        SET status = 'collected', secret = NULL, mtime = now()
--       FROM old
--      WHERE a.id = old.id
--  RETURNING old.secret, a.user_id;
