-- Router module for OpenResty/LuaJIT
-- Provides routing with :param extraction and JSON responses

local json = require("cjson")
-- Empty collections (tagList, articles, comments, tags) must encode as [] not {}
json.encode_empty_table_as_object(false)

local router = {}

-- Routes table - populated by route() function
local routes = {}

-- Add a route to the router
-- @param method: HTTP method (GET, POST, etc.)
-- @param path: URL path pattern (e.g., "/users/:id")
-- @param handler: function(env_config, ngx, params) returning { status, body }
function router.route(method, path, handler)
    table.insert(routes, {
        method = method:upper(),
        pattern = path,
        handler = handler
    })
end

-- Match a path against a pattern and extract parameters
-- @param pattern: route pattern (e.g., "/users/:id/posts/:post_id")
-- @param path: request path (e.g., "/users/123/posts/456")
-- @return params: table of parameters, or nil if no match
local function match_pattern(pattern, path)
    local pattern_parts = {}
    for part in pattern:gmatch("[^/]+") do
        table.insert(pattern_parts, part)
    end

    local path_parts = {}
    for part in path:gmatch("[^/]+") do
        table.insert(path_parts, part)
    end

    if #pattern_parts ~= #path_parts then
        return nil
    end

    local params = {}
    for i, pp in ipairs(pattern_parts) do
        if pp:sub(1, 1) == ":" then
            params[pp:sub(2)] = path_parts[i]
        elseif pp ~= path_parts[i] then
            return nil
        end
    end

    return params
end

-- Find a matching route
-- @param method: HTTP method
-- @param path: request path
-- @return route: route table, or nil
-- @return params: parameters table, or nil
function router.match(method, path)
    for _, route in ipairs(routes) do
        if route.method == method:upper() then
            local params = match_pattern(route.pattern, path)
            if params then
                return route, params
            end
        end
    end
    return nil, nil
end

-- Handle a request: dispatch to the matching route and write the JSON response
function router.handle(ngx)
    local method = ngx.req.get_method()
    local path = ngx.var.uri

    local route, params = router.match(method, path)
    if not route then
        ngx.status = 404
        ngx.header["Content-Type"] = "application/json"
        ngx.say(json.encode({ error = "Not found", path = path }))
        return
    end

    local status = 200
    local result
    local ok, handler_result = pcall(route.handler, ngx.ctx.env_config, ngx, params)
    if ok then
        result = handler_result
        if type(result) == "table" and result.status then
            status = result.status
            result = result.body or result
        end
    else
        ngx.log(ngx.ERR, "Handler error for ", method, " ", path, ": ", tostring(handler_result))
        status = 500
        result = { error = "Internal server error" }
    end

    ngx.status = status
    ngx.header["Content-Type"] = "application/json"

    if status == 204 then
        ngx.say("")
        return
    end

    if type(result) == "string" then
        ngx.say(result)
        return
    end

    local encode_ok, encoded = pcall(json.encode, result)
    if not encode_ok then
        ngx.log(ngx.ERR, "JSON encode error for ", method, " ", path, ": ", tostring(encoded))
        ngx.status = 500
        ngx.say('{"error":"Internal server error"}')
        return
    end
    ngx.say(encoded)
end

return router
