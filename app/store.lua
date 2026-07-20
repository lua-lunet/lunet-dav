-- ============================================================================
--  MOCK — THROWAWAY SCAFFOLDING. NOT PRODUCTION CODE.
-- ============================================================================
-- `store` is our name for the future native lunet shared-memory / throttle / cache
-- feature: https://github.com/lua-lunet/lunet/issues/103 (ngx.shared-like, with inc()).
-- That feature is NOT ready. This file is a Lua stand-in implementing ONLY the minimal
-- surface lunet-dav needs (set/get/add/incr/delete), backed by Postgres (sql/store_schema.sql)
-- purely so we can test now. Every other member of the future API raises "not implemented".
--
-- Semantics differ from the real thing (Postgres round-trips, best-effort atomicity). The
-- real feature keeps this state in shared memory to avoid DB pressure. Delete this file and
-- sql/store_schema.sql the moment lunet#103 lands; the store hurl suite carries over as the
-- contract for the scope we use. See docs/SPEC-v0.1.0.md (Login Flow v2) and docs/DESIGN.md.
--
-- Every function takes env_config as its first argument, matching app/db.lua.

local db = require("db")
local json = require("cjson")

local store = {}

-- store.set(env_config, key, value, ttl_seconds)
-- Upsert a value with an optional TTL (seconds). value is any JSON-encodable Lua value.
function store.set(env_config, key, value, ttl_seconds)
    local encoded = json.encode(value)
    local sql = [[
        INSERT INTO store_kv (key, value, expires_at)
        VALUES ($1, $2::jsonb, CASE WHEN $3::int IS NULL THEN NULL
                                    ELSE now() + make_interval(secs => $3::int) END)
        ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, expires_at = EXCLUDED.expires_at
    ]]
    local ok, err = db.query(env_config, sql, key, encoded, ttl_seconds)
    if not ok then return nil, err end
    return true, nil
end

-- store.get(env_config, key) -> value|nil, err
-- Returns nil (no error) when the key is absent or expired (lazy TTL).
function store.get(env_config, key)
    local sql = [[
        SELECT value::text AS value FROM store_kv
         WHERE key = $1 AND (expires_at IS NULL OR expires_at > now())
    ]]
    local row, err = db.query_row(env_config, sql, key)
    if err then return nil, err end
    if not row then return nil, nil end
    return json.decode(row.value), nil
end

-- store.add(env_config, key, value, ttl_seconds) -> added(boolean), err
-- Sets the value only if no live entry exists (best-effort single-flight). An expired row
-- is treated as absent and overwritten. Returns true if this call created the entry.
function store.add(env_config, key, value, ttl_seconds)
    local encoded = json.encode(value)
    local sql = [[
        INSERT INTO store_kv (key, value, expires_at)
        VALUES ($1, $2::jsonb, CASE WHEN $3::int IS NULL THEN NULL
                                    ELSE now() + make_interval(secs => $3::int) END)
        ON CONFLICT (key) DO UPDATE
            SET value = EXCLUDED.value, expires_at = EXCLUDED.expires_at
          WHERE store_kv.expires_at IS NOT NULL AND store_kv.expires_at <= now()
        RETURNING (xmax = 0) AS inserted
    ]]
    local row, err = db.query_row(env_config, sql, key, encoded, ttl_seconds)
    if err then return nil, err end
    -- No row returned => conflict on a still-live entry => not added.
    if not row then return false, nil end
    return row.inserted == true or row.inserted == "t", nil
end

-- store.incr(env_config, key, delta, init, ttl_seconds) -> value(number), err
-- Atomic-ish increment. Creates the key with `init` (default 0) + delta if absent/expired,
-- otherwise adds delta to the stored number. Used for best-effort throttling.
function store.incr(env_config, key, delta, init, ttl_seconds)
    delta = delta or 1
    init = init or 0
    local sql = [[
        INSERT INTO store_kv (key, value, expires_at)
        VALUES ($1, to_jsonb(($2::int + $3::int)),
                CASE WHEN $4::int IS NULL THEN NULL
                     ELSE now() + make_interval(secs => $4::int) END)
        ON CONFLICT (key) DO UPDATE
            SET value = to_jsonb(
                    (CASE WHEN store_kv.expires_at IS NOT NULL AND store_kv.expires_at <= now()
                          THEN $3::int ELSE (store_kv.value)::int END) + $2::int)
        RETURNING (value)::int AS value
    ]]
    local row, err = db.query_row(env_config, sql, key, delta, init, ttl_seconds)
    if err then return nil, err end
    return tonumber(row.value), nil
end

-- store.delete(env_config, key)
function store.delete(env_config, key)
    local ok, err = db.query(env_config, "DELETE FROM store_kv WHERE key = $1", key)
    if not ok then return nil, err end
    return true, nil
end

-- Everything else in the future lunet#103 API is deliberately absent: any other access
-- raises rather than silently misbehaving, so callers cannot depend on unmocked features.
setmetatable(store, {
    __index = function(_, k)
        return function()
            error("store: '" .. tostring(k) ..
                  "' is not implemented in the Lua mock (see lunet#103)", 2)
        end
    end,
})

return store
