-- Per-connection ngx-like context for running OpenResty-style router/handler
-- code (router.lua, web.lua, *_routes.lua) on lunet.
--
-- Each request gets a fresh table from new_context() — never a global — so
-- concurrent requests handled by different lunet coroutines never share
-- mutable state (status/header/body buffer).

local cjson = require("cjson")

local ngx_context = {}

local LOG_LEVELS = { STDERR = 1, ERR = 2, WARN = 3, NOTICE = 4, INFO = 5, DEBUG = 6 }
local LOG_LEVEL_NAMES = {}
for name, level in pairs(LOG_LEVELS) do
    LOG_LEVEL_NAMES[level] = name
end

-- request: the table returned by lib/http.lua's parse_request
-- (method, path, headers, body, query_params, query_string)
function ngx_context.new_context(request)
    local response_body = {}

    local ctx = {
        status = 200,
        header = {},
        ctx = {},
        null = cjson.null,

        req = {
            get_method = function() return request.method end,
            get_headers = function() return request.headers end,
            read_body = function() end, -- no-op: body is already fully read
            get_body_data = function() return request.body end,
        },

        say = function(text)
            response_body[#response_body + 1] = text or ""
        end,

        log = function(level, ...)
            local args = { ... }
            for i, v in ipairs(args) do args[i] = tostring(v) end
            io.stderr:write("[", LOG_LEVEL_NAMES[level] or tostring(level), "] ", table.concat(args), "\n")
        end,
    }

    for name, level in pairs(LOG_LEVELS) do
        ctx[name] = level
    end

    ctx.var = setmetatable({ uri = request.path }, {
        __index = function(_, key)
            local arg_name = key:match("^arg_(.+)$")
            if arg_name then
                return request.query_params[arg_name]
            end
            return nil
        end,
    })

    -- Exposed so the server can read back the accumulated ngx.say() output
    function ctx._get_response_body()
        return table.concat(response_body)
    end

    return ctx
end

return ngx_context
