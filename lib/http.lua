-- HTTP parsing and response building helpers for Lunet

local http = {}

local socket = require("lunet.socket")

local BODY_METHODS = { PUT = true, PROPPATCH = true }
local MAX_HEADER_BYTES = 64 * 1024

-- Parse query string into table
function http.parse_query_string(query)
    if not query or query == "" then return {} end
    local params = {}
    for k, v in query:gmatch("([^&=]+)=([^&=]*)") do
        params[http.url_decode(k)] = http.url_decode(v)
    end
    return params
end

-- URL decode
function http.url_decode(str)
    str = str:gsub("+", " ")
    return str:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end)
end

-- Parse HTTP headers from a block of "Key: value" lines separated by \r\n
function http.parse_headers(raw)
    local headers = {}
    for line in (raw .. "\r\n"):gmatch("(.-)\r\n") do
        if line == "" then break end
        local colon = line:find(":")
        if colon then
            local key = line:sub(1, colon - 1):lower()
            local value = line:sub(colon + 1):gsub("^%s+", ""):gsub("%s+$", "")
            headers[key] = value
        end
    end
    return headers
end

-- Parse HTTP request
function http.parse_request(raw)
    -- Find end of headers (blank line = double CRLF)
    local header_end = raw:find("\r\n\r\n", 1, true)
    if not header_end then return nil, "Incomplete headers" end

    local head = raw:sub(1, header_end - 1)
    local body = raw:sub(header_end + 4)

    local first_line, headers_raw = head:match("^([^\r\n]*)\r\n(.*)$")
    first_line = first_line or head
    headers_raw = headers_raw or ""

    local method, path, version = first_line:match("^(%w+)%s+([^%s]+)%s+([^\r\n]*)")
    if not method then return nil, "Invalid HTTP request" end
    method = method:upper()

    -- Separate path and query string
    local query_string = ""
    local query_start = path:find("?")
    if query_start then
        query_string = path:sub(query_start + 1)
        path = path:sub(1, query_start - 1)
    end

    local headers = http.parse_headers(headers_raw)
    local query_params = http.parse_query_string(query_string)
    
    return {
        method = method,
        path = path,
        version = version,
        headers = headers,
        body = body,
        query_params = query_params,
        query_string = query_string
    }, nil
end

function http.read_request(client, opts)
    opts = opts or {}
    local max_body = opts.max_body_bytes

    local buf = ""
    local header_end
    while true do
        local chunk, err = socket.read(client)
        if not chunk then
            return nil, { status = 400, message = err or "connection closed" }
        end
        buf = buf .. chunk
        header_end = buf:find("\r\n\r\n", 1, true)
        if header_end then
            if header_end + 3 > MAX_HEADER_BYTES then
                return nil, { status = 400, message = "header block too large" }
            end
            break
        end
        if #buf > MAX_HEADER_BYTES then
            return nil, { status = 400, message = "header block too large" }
        end
    end

    local head = buf:sub(1, header_end - 1)
    local leftover = buf:sub(header_end + 4)

    local req, parse_err = http.parse_request(head .. "\r\n\r\n")
    if not req then
        return nil, { status = 400, message = parse_err or "invalid request" }
    end

    local te = req.headers["transfer-encoding"]
    if te and te:lower() ~= "identity" then
        return nil, { status = 501, message = "Transfer-Encoding not supported" }
    end

    local expect = req.headers["expect"]
    if expect and expect:lower() == "100-continue" then
        socket.write(client, "HTTP/1.1 100 Continue\r\n\r\n")
    end

    local cl = req.headers["content-length"]
    if cl then
        local n = tonumber(cl)
        if not n or n < 0 then
            return nil, { status = 400, message = "invalid Content-Length" }
        end
        if max_body and n > max_body then
            return nil, { status = 413, message = "payload too large" }
        end
        local body_parts = {}
        local remaining = n
        if #leftover > 0 then
            if #leftover >= remaining then
                body_parts[1] = leftover:sub(1, remaining)
                remaining = 0
            else
                body_parts[1] = leftover
                remaining = remaining - #leftover
            end
        end
        while remaining > 0 do
            local chunk, err = socket.read(client)
            if not chunk then
                return nil, { status = 400, message = "truncated body" }
            end
            if #chunk >= remaining then
                body_parts[#body_parts + 1] = chunk:sub(1, remaining)
                remaining = 0
            else
                body_parts[#body_parts + 1] = chunk
                remaining = remaining - #chunk
            end
        end
        req.body = table.concat(body_parts)
    elseif BODY_METHODS[req.method] then
        return nil, { status = 411, message = "Content-Length required" }
    else
        req.body = leftover
    end

    return req, nil
end

-- Build HTTP response
function http.response(status, headers, body)
    local status_text = {
        [200] = "OK",
        [201] = "Created",
        [204] = "No Content",
        [400] = "Bad Request",
        [401] = "Unauthorized",
        [403] = "Forbidden",
        [404] = "Not Found",
        [405] = "Method Not Allowed",
        [409] = "Conflict",
        [412] = "Precondition Failed",
        [429] = "Too Many Requests",
        [422] = "Unprocessable Entity",
        [500] = "Internal Server Error",
        [501] = "Not Implemented",
        [207] = "Multi-Status"
    }
    
    local status_line = string.format("HTTP/1.1 %d %s", status, status_text[status] or "Unknown")
    
    headers = headers or {}
    local has_connection = headers["connection"] ~= nil or headers["Connection"] ~= nil
    local has_content_type = headers["content-type"] ~= nil or headers["Content-Type"] ~= nil
    local has_content_length = headers["content-length"] ~= nil or headers["Content-Length"] ~= nil
    -- Add default headers
    if not has_connection then
        headers["connection"] = "close"
    end
    if not has_content_type then
        headers["content-type"] = "application/json"
    end
    
    -- Build header lines
    local header_lines = {status_line}
    for k, v in pairs(headers) do
        header_lines[#header_lines + 1] = string.format("%s: %s", k, tostring(v))
    end
    
    body = body or ""
    if not has_content_length then
        header_lines[#header_lines + 1] = string.format("Content-Length: %d", #body)
    end
    
    return table.concat(header_lines, "\r\n") .. "\r\n\r\n" .. body
end

-- JSON response helper
function http.json_response(status, data)
    local json = require("cjson")
    local body = json.encode(data)
    return http.response(status, { ["Content-Type"] = "application/json" }, body)
end

-- Error response helper
function http.error_response(status, data)
    return http.json_response(status, { errors = data })
end

return http
