-- HTTP parsing and response building helpers for Lunet

local http = {}

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
        [422] = "Unprocessable Entity",
        [500] = "Internal Server Error"
    }
    
    local status_line = string.format("HTTP/1.1 %d %s", status, status_text[status] or "Unknown")
    
    headers = headers or {}
    -- Add default headers
    if not headers["connection"] then
        headers["connection"] = "close"
    end
    if not headers["content-type"] then
        headers["content-type"] = "application/json"
    end
    
    -- Build header lines
    local header_lines = {status_line}
    for k, v in pairs(headers) do
        header_lines[#header_lines + 1] = string.format("%s: %s", k, tostring(v))
    end
    
    body = body or ""
    header_lines[#header_lines + 1] = string.format("Content-Length: %d", #body)
    
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
