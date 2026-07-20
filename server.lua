-- Conduit API - RealWorld Example Application
-- Built with lunet (libuv + LuaJIT coroutine runtime)

package.path = "./app/?.lua;./lib/?.lua;./compat/?.lua;./?.lua;" .. package.path
package.cpath = "./bin/?.so;./bin/lunet/?.so;" .. package.cpath

io.stdout:setvbuf("no")

local lunet = require("lunet")
local socket = require("lunet.socket")
local http = require("http")
local ngx_context = require("ngx_context")

local config = require("config")
local router = require("router")
require("routes") -- registers all routes with the router

local env_config, config_errors = config.resolve()
if not env_config then
    print("Configuration error: missing " .. table.concat(config_errors or {}, ", "))
    os.exit(1)
end

local LISTEN_HOST = os.getenv("LUNET_HOST") or "127.0.0.1"
local LISTEN_PORT = tonumber(os.getenv("LUNET_PORT") or os.getenv("PORT")) or 8081

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

-- Mirrors nginx.conf's three locations: `/health`, `/`, and `^~ /api/`
local function handle_request(request)
    if request.method == "GET" and request.path == "/health" then
        return http.json_response(200, { status = "ok" })
    end

    if request.method == "GET" and request.path == "/" then
        local content = read_file("index.html")
        if content then
            return http.response(200, { ["Content-Type"] = "text/html" }, content)
        end
        return http.error_response(404, { "Not found" })
    end

    if not request.path:find("^/api/") then
        return http.error_response(404, { "Not found" })
    end

    local ctx = ngx_context.new_context(request)
    ctx.ctx.env_config = env_config
    router.handle(ctx)

    return http.response(ctx.status, ctx.header, ctx._get_response_body())
end

local function handle_client(client)
    local data = socket.read(client)
    if not data then
        socket.close(client)
        return
    end

    local request, parse_err = http.parse_request(data)
    if not request then
        socket.write(client, http.error_response(400, { parse_err or "Bad request" }))
        socket.close(client)
        return
    end

    local ok, response = pcall(handle_request, request)
    if not ok then
        io.stderr:write("Request error: ", tostring(response), "\n")
        response = http.error_response(500, { "Internal server error" })
    end

    socket.write(client, response)
    socket.close(client)
end

lunet.spawn(function()
    local listener, err = socket.listen("tcp", LISTEN_HOST, LISTEN_PORT)
    if not listener then
        print("Failed to listen: " .. tostring(err))
        os.exit(1)
    end

    print("Conduit API server listening on tcp://" .. LISTEN_HOST .. ":" .. LISTEN_PORT)

    while true do
        local client = socket.accept(listener)
        if client then
            lunet.spawn(function()
                handle_client(client)
            end)
        end
    end
end)
