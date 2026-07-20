-- lunet-dav auth schema (PostgreSQL 16) — SCAFFOLDING, subject to breaking changes.
-- Backs OCS user metadata (basic security: a user sees only their own details) and
-- Login Flow v2 (app-password minting via the system browser). Depends on the residual
-- `users` table from the RealWorld chassis (sql/schema.sql). See docs/SPEC-v0.1.0.md.

-- App passwords. A separate table so a user can revoke one later without touching their
-- real password. The plaintext app password is shown to the client exactly once (at the
-- end of Login Flow v2); only an Argon2 hash is stored here.
CREATE TABLE IF NOT EXISTS app_passwords (
    id            BIGSERIAL PRIMARY KEY,
    user_id       INTEGER     NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    -- Argon2id hash of the app password (via app/password.lua). Verified on Basic auth.
    password_hash TEXT        NOT NULL,
    -- Human label; defaults to the initiating User-Agent per Login Flow v2.
    name          TEXT        NOT NULL DEFAULT 'app',
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_used_at  TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_app_passwords_user ON app_passwords (user_id);

-- Login Flow v2 transient state. One row per initiated flow.
--   poll_token   : opaque token the client polls with
--   login_token  : opaque token embedded in the browser `login` URL
--   user_id      : NULL until the browser grant completes
--   app_password : plaintext app password, populated at grant, returned by /poll ONCE,
--                  then cleared (consumed). Never persisted long-term in plaintext.
--   completed_at : set at grant; polls before this return 404, after return 200 once
CREATE TABLE IF NOT EXISTS login_flow_tokens (
    id            BIGSERIAL PRIMARY KEY,
    poll_token    TEXT        NOT NULL UNIQUE,
    login_token   TEXT        NOT NULL UNIQUE,
    user_agent    TEXT,
    user_id       INTEGER     REFERENCES users(id) ON DELETE CASCADE,
    app_password  TEXT,
    completed_at  TIMESTAMPTZ,
    polled_at     TIMESTAMPTZ,          -- set when the one-time 200 is delivered
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- ~20 minute validity per upstream.
    expires_at    TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '20 minutes')
);
CREATE INDEX IF NOT EXISTS idx_login_flow_poll  ON login_flow_tokens (poll_token);
CREATE INDEX IF NOT EXISTS idx_login_flow_login ON login_flow_tokens (login_token);
