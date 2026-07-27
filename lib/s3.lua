-- Minimal S3 client: SigV4 over a plain lunet socket on the libuv loop.
--
-- Deliberately LCD (docs/DESIGN.md §6): PutObject, HeadObject, GetObject,
-- GetBucketVersioning — classic operations only, path-style addressing,
-- SigV4 signing. No SDK, no C driver, no worker pool: every request is a
-- coroutine-suspending socket write/read on the uv loop, same as the server's
-- own accept path. Plain HTTP only (local MinIO emulator target); TLS is a
-- future concern for real S3 endpoints.
--
-- All functions must be called from inside a lunet coroutine.

local socket = require("lunet.socket")
local crypto = require("lib.crypto")

local s3 = {}

local EMPTY_SHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

-- Upstream capability profile (docs/DESIGN.md §6). Anything other than an
-- explicit checksum-capable profile resolves to lcd: fewest features, no
-- extra request headers, no follow-up round trips.
local function capabilities(cfg)
    local name = (cfg.behavior and cfg.behavior.S3_API_PROFILE) or "lcd"
    if name == "minio" or name == "minio-enterprise" then
        return { name = name, checksum = true }
    end
    return { name = "lcd", checksum = false }
end

local function hex_to_raw(hexstr)
    return (hexstr:gsub("..", function(cc) return string.char(tonumber(cc, 16)) end))
end

-- RFC 3986 unreserved characters; everything else percent-encoded.
local function uri_encode(str, keep_slash)
    return (str:gsub("[^%w%-%._~" .. (keep_slash and "/" or "") .. "]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

local function hex(raw)
    return (raw:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

-- Parse "http://host:port" (the only scheme supported).
local function parse_endpoint(endpoint)
    local host, port = endpoint:match("^http://([^:/]+):?(%d*)$")
    if not host then
        return nil, nil, "unsupported S3 endpoint (need http://host[:port]): " .. tostring(endpoint)
    end
    return host, tonumber(port) or 80, nil
end

-- Build the SigV4 Authorization header and required x-amz-* headers.
-- query: sorted-key list of {k, v} pairs (values already plain; encoded here).
local function sign_v4(cfg, method, canonical_uri, query, payload_sha, amz_date, extra_signed)
    local date = amz_date:sub(1, 8)
    local host, port = parse_endpoint(cfg.S3_ENDPOINT)
    local host_header = host .. ((port ~= 80) and (":" .. port) or "")

    local query_parts = {}
    for _, kv in ipairs(query) do
        query_parts[#query_parts + 1] = uri_encode(kv[1]) .. "=" .. uri_encode(kv[2])
    end
    local canonical_query = table.concat(query_parts, "&")

    local headers_to_sign = {
        ["host"] = host_header,
        ["x-amz-content-sha256"] = payload_sha,
        ["x-amz-date"] = amz_date,
    }
    for _, h in ipairs(extra_signed or {}) do
        headers_to_sign[h[1]:lower()] = h[2]
    end

    local sorted_keys = {}
    for k in pairs(headers_to_sign) do
        sorted_keys[#sorted_keys + 1] = k
    end
    table.sort(sorted_keys)

    local canonical_parts = {}
    for _, k in ipairs(sorted_keys) do
        canonical_parts[#canonical_parts + 1] = k .. ":" .. headers_to_sign[k]
    end
    local canonical_headers = table.concat(canonical_parts, "\n") .. "\n"
    local signed_headers = table.concat(sorted_keys, ";")

    local canonical_request = table.concat({
        method, canonical_uri, canonical_query, canonical_headers, signed_headers, payload_sha,
    }, "\n")

    local scope = date .. "/" .. cfg.S3_REGION .. "/s3/aws4_request"
    local string_to_sign = table.concat({
        "AWS4-HMAC-SHA256", amz_date, scope, crypto.sha256_hex(canonical_request),
    }, "\n")

    local k_date = crypto.hmac_sha256_full(date, "AWS4" .. cfg.S3_SECRET_ACCESS_KEY)
    local k_region = crypto.hmac_sha256_full(cfg.S3_REGION, k_date)
    local k_service = crypto.hmac_sha256_full("s3", k_region)
    local k_signing = crypto.hmac_sha256_full("aws4_request", k_service)
    local signature = hex(crypto.hmac_sha256_full(string_to_sign, k_signing))

    local authorization = "AWS4-HMAC-SHA256 Credential=" .. cfg.S3_ACCESS_KEY_ID .. "/" .. scope
        .. ", SignedHeaders=" .. signed_headers
        .. ", Signature=" .. signature

    return {
        host = host_header,
        authorization = authorization,
        canonical_query = canonical_query,
        signed_keys = sorted_keys,
        header_values = headers_to_sign,
    }
end

-- Read a full HTTP/1.1 response from conn. Relies on Content-Length when
-- present, else reads to EOF (we always send Connection: close).
local MAX_CHUNKED_DECODED = 512 * 1024 * 1024

local function decode_chunked(conn, initial)
    local buf = initial
    local decoded = 0
    local parts = {}

    local function read_more()
        local chunk, err = socket.read(conn)
        if not chunk then
            return nil, "S3 connection error mid-body: " .. (err or "closed")
        end
        buf = buf .. chunk
        return true
    end

    local function read_line()
        while true do
            local pos = buf:find("\r\n", 1, true)
            if pos then
                local line = buf:sub(1, pos - 1)
                buf = buf:sub(pos + 2)
                return line
            end
            local ok, err = read_more()
            if not ok then return nil, err end
        end
    end

    local function read_exact(n)
        while #buf < n do
            local ok, err = read_more()
            if not ok then return nil, err end
        end
        local data = buf:sub(1, n)
        buf = buf:sub(n + 1)
        return data
    end

    while true do
        local size_line, lerr = read_line()
        if not size_line then return nil, lerr end

        if #size_line > 32 then
            return nil, "malformed chunked encoding: size line too long"
        end

        local size_str = size_line:match("^([^;]+)")
        local chunk_size = tonumber(size_str, 16)
        if not chunk_size then
            return nil, "malformed chunked encoding"
        end

        if chunk_size == 0 then
            while true do
                local trailer, terr = read_line()
                if not trailer then return nil, terr end
                if trailer == "" then break end
            end
            break
        end

        decoded = decoded + chunk_size
        if decoded > MAX_CHUNKED_DECODED then
            return nil, "chunked body exceeds maximum size"
        end

        local data, derr = read_exact(chunk_size)
        if not data then return nil, derr end
        parts[#parts + 1] = data

        local crlf, cerr = read_exact(2)
        if not crlf then return nil, cerr end
        if crlf ~= "\r\n" then
            return nil, "malformed chunked encoding: missing CRLF"
        end
    end

    return table.concat(parts)
end

local function read_response(conn, expect_body)
    local buf = ""
    local header_end
    while true do
        header_end = buf:find("\r\n\r\n", 1, true)
        if header_end then break end
        local chunk, err = socket.read(conn)
        if not chunk then
            return nil, "S3 connection closed before response headers" .. (err and (": " .. err) or "")
        end
        buf = buf .. chunk
    end

    local head = buf:sub(1, header_end - 1)
    local body = buf:sub(header_end + 4)

    local status = tonumber(head:match("^HTTP/1%.%d (%d+)"))
    if not status then
        return nil, "malformed S3 response status line"
    end
    local headers = {}
    for k, v in head:gmatch("\r\n([^:\r\n]+):%s*([^\r\n]*)") do
        headers[k:lower()] = v
    end

    local content_length = tonumber(headers["content-length"])
    if not expect_body then
        return { status = status, headers = headers, body = "" }
    end

    local te = headers["transfer-encoding"]
    if te then
        if te:lower() ~= "chunked" then
            return nil, "unsupported transfer-encoding: " .. te
        end
        local decoded, derr = decode_chunked(conn, body)
        if not decoded then return nil, derr end
        return { status = status, headers = headers, body = decoded }
    end

    if content_length then
        if content_length > MAX_CHUNKED_DECODED then
            return nil, "S3 response too large"
        end
        while #body < content_length do
            local chunk, err = socket.read(conn)
            if not chunk then
                return nil, string.format(
                    "S3 connection closed before complete response body: expected %d bytes, received %d%s",
                    content_length,
                    #body,
                    err and (" (" .. err .. ")") or ""
                )
            end
            body = body .. chunk
        end
        body = body:sub(1, content_length)
    else
        while true do
            local chunk, err = socket.read(conn)
            if not chunk then
                if err then
                    return nil, "S3 connection error mid-body: " .. err
                end
                break
            end
            body = body .. chunk
        end
    end

    return { status = status, headers = headers, body = body }
end

-- One signed request/response cycle. query is a sorted list of {k, v} pairs.
-- extra_headers: optional list of {name, value} pairs; any x-amz-* entry is
-- folded into the SigV4 canonical request (AWS requires all x-amz-* headers
-- on the wire to be signed). content_type, when given, is also signed.
local function request(cfg, method, key, query, body, content_type, extra_headers)
    local host, port, perr = parse_endpoint(cfg.S3_ENDPOINT)
    if not host then return nil, perr end

    -- Path-style addressing: /<bucket>/<key>. (The only mode MinIO on an IP
    -- endpoint supports; virtual-host style is not implemented.)
    local canonical_uri = "/" .. uri_encode(cfg.S3_BUCKET) .. (key and ("/" .. uri_encode(key, true)) or "")

    body = body or ""
    local payload_sha = (#body > 0) and crypto.sha256_hex(body) or EMPTY_SHA256
    local amz_date = os.date("!%Y%m%dT%H%M%SZ")

    local extra_signed = {}
    if content_type then
        extra_signed[#extra_signed + 1] = { "content-type", content_type }
    end
    for _, h in ipairs(extra_headers or {}) do
        extra_signed[#extra_signed + 1] = { h[1]:lower(), h[2] }
    end

    local sig = sign_v4(cfg, method, canonical_uri, query, payload_sha, amz_date, extra_signed)

    local path = canonical_uri
    if sig.canonical_query ~= "" then
        path = path .. "?" .. sig.canonical_query
    end

    local req = {
        method .. " " .. path .. " HTTP/1.1",
        "Authorization: " .. sig.authorization,
    }
    for _, name in ipairs(sig.signed_keys) do
        req[#req + 1] = name .. ": " .. sig.header_values[name]
    end
    req[#req + 1] = "Content-Length: " .. #body
    req[#req + 1] = "Connection: close"
    if method == "PUT" then
        -- Content-addressed objects are immutable: first writer wins atomically.
        req[#req + 1] = "If-None-Match: *"
    end
    local wire = table.concat(req, "\r\n") .. "\r\n\r\n" .. body

    local conn, cerr = socket.connect(host, port)
    if not conn then
        return nil, "S3 connect to " .. host .. ":" .. port .. " failed: " .. tostring(cerr)
    end

    -- socket.write returns nil on success, an error string on failure.
    local werr = socket.write(conn, wire)
    if werr then
        socket.close(conn)
        return nil, "S3 write failed: " .. tostring(werr)
    end

    local response, rerr = read_response(conn, method ~= "HEAD")
    socket.close(conn)
    if not response then return nil, rerr end
    return response
end

local function fail(op, response)
    local snippet = (response.body or ""):gsub("%s+", " "):sub(1, 200)
    return nil, "S3 " .. op .. " failed: HTTP " .. response.status .. " " .. snippet
end

-- PutObject. Returns { version_id, etag, checksum_sha256 } (etag unquoted;
-- checksum_sha256 only under a checksum-capable profile, base64 as upstream
-- sent it). Under such a profile the request carries
-- x-amz-checksum-sha256, so the upstream verifies the transfer itself and
-- rejects corrupted bytes.
function s3.put_object(cfg, key, body, content_type)
    local caps = capabilities(cfg)
    local extra_headers
    if caps.checksum then
        extra_headers = {
            { "x-amz-checksum-sha256", crypto.base64_encode(hex_to_raw(crypto.sha256_hex(body or ""))) },
        }
    end
    local response, err = request(cfg, "PUT", key, {}, body, content_type, extra_headers)
    if not response then return nil, err end
    if response.status == 409 or response.status == 412 then
        local existing, herr = s3.head_object(cfg, key)
        if existing or herr then return existing, herr end
    end
    if response.status ~= 200 then return fail("PutObject " .. key, response) end
    local etag = (response.headers["etag"] or ""):gsub('"', "")
    local version_id = response.headers["x-amz-version-id"]
    if not version_id or version_id == "" then
        return nil, "S3 PutObject returned no x-amz-version-id (bucket versioning disabled?)"
    end
    local checksum
    if caps.checksum then
        checksum = response.headers["x-amz-checksum-sha256"]
    end
    if caps.checksum and (not checksum or checksum == "") then
        -- The profile advertises checksums but the PUT response omitted the
        -- header: one HeadObject follow-up harvests it (a coroutine-suspended
        -- round trip; it blocks no other request).
        local head = s3.head_object(cfg, key)
        if head then checksum = head.checksum_sha256 end
    end
    return { version_id = version_id, etag = etag, checksum_sha256 = checksum }
end

-- HeadObject. Returns nil without an error when the key does not exist.
-- On success: { version_id, etag, checksum_sha256 } (checksum only when the
-- upstream sends it). Under a checksum-capable profile the request carries
-- x-amz-checksum-mode: ENABLED — without it S3/MinIO withhold the checksum
-- from the response even when one is stored. The value is case-sensitive
-- upstream; "Enabled" is silently ignored.
function s3.head_object(cfg, key)
    local extra_headers
    if capabilities(cfg).checksum then
        extra_headers = { { "x-amz-checksum-mode", "ENABLED" } }
    end
    local response, err = request(cfg, "HEAD", key, {}, nil, nil, extra_headers)
    if not response then return nil, err end
    if response.status == 404 then return nil, nil end
    if response.status ~= 200 then return fail("HeadObject " .. key, response) end
    local version_id = response.headers["x-amz-version-id"]
    if not version_id or version_id == "" then
        return nil, "S3 HeadObject returned no x-amz-version-id (bucket versioning disabled?)"
    end
    return {
        version_id = version_id,
        etag = (response.headers["etag"] or ""):gsub('"', ""),
        checksum_sha256 = response.headers["x-amz-checksum-sha256"],
    }
end

-- GetObject, pinned to a specific version when version_id is given.
-- Returns body, { etag, content_type }.
function s3.get_object(cfg, key, version_id)
    local query = {}
    if version_id and version_id ~= "" then
        query[#query + 1] = { "versionId", version_id }
    end
    local response, err = request(cfg, "GET", key, query)
    if not response then return nil, err end
    if response.status ~= 200 then return fail("GetObject " .. key, response) end
    return response.body, {
        etag = (response.headers["etag"] or ""):gsub('"', ""),
        content_type = response.headers["content-type"],
    }
end

-- GetBucketVersioning. Returns "Enabled", "Suspended", or "" (never configured).
function s3.get_bucket_versioning(cfg)
    local response, err = request(cfg, "GET", nil, { { "versioning", "" } })
    if not response then return nil, err end
    if response.status ~= 200 then return fail("GetBucketVersioning", response) end
    return response.body:match("<Status>(%a+)</Status>") or ""
end

return s3
