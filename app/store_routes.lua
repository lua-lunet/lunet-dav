-- ============================================================================
--  TEST-ONLY SHIM for the `store` MOCK. THROWAWAY SCAFFOLDING.
-- ============================================================================
-- Exposes app/store.lua (the lunet#103 mock) over HTTP so specs/store/*.hurl can prove the
-- minimal surface works. These endpoints exist ONLY to test the mock and must never be
-- reachable in a real deployment. They carry over as the contract for the scope we use when
-- the native lunet#103 shared store replaces the mock. Deleted alongside app/store.lua then.
--
-- Namespaced under /api/_store/ because the server only dispatches /api/ paths.

local router = require("router")
local json = require("cjson")
local web = require("web")
local store = require("store")

local function read_json(ngx)
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if not body then return nil, "missing body" end
    local ok, data = pcall(json.decode, body)
    if not ok or type(data) ~= "table" then return nil, "invalid JSON" end
    return data, nil
end

router.route("POST", "/api/_store/set", function(env_config, ngx, _)
    local d, err = read_json(ngx)
    if not d then return web.error_response(400, { err }) end
    local ok, serr = store.set(env_config, d.key, d.value, d.ttl)
    if not ok then return web.error_response(500, { serr }) end
    return web.json_response(200, { ok = true })
end)

router.route("GET", "/api/_store/get", function(env_config, ngx, _)
    local key = ngx.var.arg_key
    local value, err = store.get(env_config, key)
    if err then return web.error_response(500, { err }) end
    if value == nil then return web.json_response(404, { found = false }) end
    return web.json_response(200, { found = true, value = value })
end)

router.route("POST", "/api/_store/add", function(env_config, ngx, _)
    local d, err = read_json(ngx)
    if not d then return web.error_response(400, { err }) end
    local added, serr = store.add(env_config, d.key, d.value, d.ttl)
    if serr then return web.error_response(500, { serr }) end
    return web.json_response(200, { added = added })
end)

router.route("POST", "/api/_store/incr", function(env_config, ngx, _)
    local d, err = read_json(ngx)
    if not d then return web.error_response(400, { err }) end
    local value, serr = store.incr(env_config, d.key, d.delta, d.init, d.ttl)
    if serr then return web.error_response(500, { serr }) end
    return web.json_response(200, { value = value })
end)

router.route("POST", "/api/_store/delete", function(env_config, ngx, _)
    local d, err = read_json(ngx)
    if not d then return web.error_response(400, { err }) end
    local ok, serr = store.delete(env_config, d.key)
    if not ok then return web.error_response(500, { serr }) end
    return web.json_response(200, { ok = true })
end)
