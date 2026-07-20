-- lunet-dav 'store' MOCK backing (PostgreSQL 16) — THROWAWAY SCAFFOLDING.
--
-- `store` is our name for the future native lunet shared-memory / throttle / cache
-- feature tracked at https://github.com/lua-lunet/lunet/issues/103 (ngx.shared-like,
-- with inc()). It is NOT ready yet. app/store.lua is a Lua mock that implements only the
-- minimal surface we need, backed by this Postgres table so we can test against it now.
--
-- Production will use the native in-memory shared dict; this table (and app/store.lua)
-- are deleted the moment lunet#103 lands. Do NOT build real features on this table — the
-- whole point of `store` is to keep transient login-flow state OUT of Postgres.
CREATE TABLE IF NOT EXISTS store_kv (
    key        TEXT        PRIMARY KEY,
    value      JSONB       NOT NULL,
    -- Lazy TTL: reads filter out rows past expires_at; NULL = no expiry.
    expires_at TIMESTAMPTZ
);
