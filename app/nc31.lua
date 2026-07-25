local cjson = require("cjson")
local db = require("db")
local password = require("password")
local crypto = require("lib.crypto")
local s3 = require("s3")
local dav_headers = require("dav_headers")
local dav_xml = require("dav_xml")
local lnt_shared = require("lunet.lnt_shared")

local nc31 = {}

local DAV_PREFIX = "/remote.php/dav/files/"

local DAV_NS = "DAV:"
local OC_NS = "http://owncloud.org/ns"
local NC_NS = "http://nextcloud.org/ns"
local LNT_NS = "http://lunet.stenographer.cloud/ns"

-- Login Flow v2 transient state (poll/login token -> status) lives in a shared
-- in-process dict, NOT Postgres, so incomplete/abandoned flows put no DB
-- pressure. See docs/DESIGN.md §12. One named region, opened lazily and
-- reused for the life of the process.
local SHARED_STORE_NAME = "lunet_dav"
local SHARED_STORE_SIZE = 1024 * 1024 -- 1 MiB; login-flow keys only

local _shared_store
local function shared_store()
    if not _shared_store then
        _shared_store = lnt_shared.store(SHARED_STORE_NAME, SHARED_STORE_SIZE)
    end
    return _shared_store
end

-- lnt_shared only stores strings/numbers/booleans natively (see
-- lunet.lnt_shared docs); our login-flow state is a small Lua table, so
-- JSON-encode/decode at this boundary.
local function store_set_json(key, value, ttl)
    return shared_store():set(key, cjson.encode(value), ttl)
end

-- Returns the decoded value, or nil with no error when the key is absent
-- ("not found" is an expected outcome for these call sites, not a failure).
local function store_get_json(key)
    local raw, err = shared_store():get(key)
    if raw == nil then
        if err == "not found" then return nil, nil end
        return nil, err
    end
    return cjson.decode(raw), nil
end

local function now_epoch()
    return tostring(os.time())
end

local function xml_escape(s)
    s = tostring(s or "")
    s = s:gsub("&", "&amp;")
    s = s:gsub("<", "&lt;")
    s = s:gsub(">", "&gt;")
    s = s:gsub('"', "&quot;")
    return s
end

local function form_decode(body)
    local out = {}
    for k, v in (body or ""):gmatch("([^&=]+)=([^&=]*)") do
        k = k:gsub("+", " "):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
        v = v:gsub("+", " "):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
        out[k] = v
    end
    return out
end

local function base64_decode(data)
    if not data then return nil end
    local b = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    data = data:gsub("[^" .. b .. "=]", "")
    return (data:gsub(".", function(x)
        if x == "=" then return "" end
        local r, f = "", (b:find(x, 1, true) or 1) - 1
        for i = 6, 1, -1 do
            r = r .. (f % 2 ^ i - f % 2 ^ (i - 1) > 0 and "1" or "0")
        end
        return r
    end):gsub("%d%d%d?%d?%d?%d?%d?%d?", function(x)
        if #x ~= 8 then return "" end
        local c = 0
        for i = 1, 8 do
            if x:sub(i, i) == "1" then c = c + 2 ^ (8 - i) end
        end
        return string.char(c)
    end))
end

local function parse_basic_auth(headers)
    local auth = headers["authorization"]
    if not auth then return nil, nil end
    local token = auth:match("^Basic%s+(.+)$")
    if not token then return nil, nil end
    local decoded = base64_decode(token)
    if not decoded then return nil, nil end
    local user, pass = decoded:match("^([^:]+):(.*)$")
    return user, pass
end

local function make_token()
    return crypto.base64_encode(crypto.random_bytes(24), true)
end

local function oc_fileid(id, env_config)
    local bh = env_config.behavior
    return string.format("%0" .. tostring(bh.DAV_FILEID_PAD_WIDTH) .. "d", tonumber(id))
        .. bh.DAV_INSTANCE_ID
end

local function quoted_etag(raw)
    if not raw or raw == "" then raw = make_token() end
    if raw:sub(1, 1) == '"' and raw:sub(-1) == '"' then
        return raw
    end
    return '"' .. raw .. '"'
end

local function is_reserved(name)
    return name and name:sub(1, 1) == "_"
end

local function percent_decode(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function percent_encode_path(s)
    return (s:gsub("[^%w%-%.%_%~%/]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function parse_dav_path(path)
    if path:sub(1, #DAV_PREFIX) ~= DAV_PREFIX then
        return nil, "not_dav"
    end
    local rest = path:sub(#DAV_PREFIX + 1)
    local segs = {}
    for part in rest:gmatch("[^/]+") do
        local decoded = percent_decode(part)
        if decoded == "" or decoded:find("/") then
            return nil, "invalid_segment"
        end
        segs[#segs + 1] = decoded
    end
    if #segs == 0 then return nil, "missing_user" end

    local user = segs[1]
    local path_segs = {}
    for i = 2, #segs do
        path_segs[#path_segs + 1] = segs[i]
    end
    if #path_segs > 2 then
        return { user = user, nested = true, path_segs = path_segs }, nil
    end
    return {
        user = user,
        path_segs = path_segs,
        collection = path_segs[1],
        name = path_segs[2],
        is_root = (#path_segs == 0),
        is_collection = (#path_segs == 1),
        is_file = (#path_segs == 2),
    }, nil
end

local function dav_error_xml(message)
    local body = [[<?xml version="1.0" encoding="utf-8"?>
<d:error xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns"><s:exception>Lunet\Dav\Exception\Unsupported</s:exception><s:message>]]
        .. xml_escape(message) .. [[</s:message></d:error>]]
    return body
end

local function json_load(str, fallback)
    if not str then return fallback end
    local ok, parsed = pcall(cjson.decode, str)
    if ok and type(parsed) == "table" then return parsed end
    return fallback
end

local function get_dav_resource(env_config, collection, name)
    local row, err = db.query_row(env_config, [[
        SELECT id, is_collection, collection, name, sha256, s3_key, s3_version_id, etag, mime_type, size, version,
               ctime::text AS ctime, mtime::text AS mtime,
               EXTRACT(EPOCH FROM ctime)::bigint AS ctime_epoch,
               EXTRACT(EPOCH FROM mtime)::bigint AS mtime_epoch,
               info::text AS info_json
          FROM dav_files
         WHERE collection = $1 AND name = $2
    ]], collection, name)
    if not row then return nil, err end
    row.info = json_load(row.info_json, { tags = {}, oplog = {} })
    if type(row.info.tags) ~= "table" then row.info.tags = {} end
    if type(row.info.oplog) ~= "table" then row.info.oplog = {} end
    return row, nil
end

local function get_content_locator(env_config, sha)
    -- The persisted upstream checksum rides along so the reuse path can pass
    -- it through exactly like a fresh PutObject harvest (docs/DESIGN.md §8).
    return db.query_row(env_config, [[
        SELECT s3_key, s3_version_id, etag,
               info->'upstream'->>'checksum_sha256' AS checksum_sha256
          FROM dav_files
         WHERE sha256 = $1
           AND s3_bucket = $2
           AND s3_key IS NOT NULL
           AND s3_version_id IS NOT NULL
         ORDER BY id
         LIMIT 1
    ]], sha, env_config.S3_BUCKET)
end

local function list_dav_children(env_config, collection)
    local rows, err = db.query(env_config, [[
        SELECT id, is_collection, collection, name, sha256, s3_key, s3_version_id, etag, mime_type, size, version,
               ctime::text AS ctime, mtime::text AS mtime,
               EXTRACT(EPOCH FROM ctime)::bigint AS ctime_epoch,
               EXTRACT(EPOCH FROM mtime)::bigint AS mtime_epoch,
               info::text AS info_json
          FROM dav_files
         WHERE collection = $1
         ORDER BY name
    ]], collection)
    if not rows then return nil, err end
    for _, row in ipairs(rows) do
        row.info = json_load(row.info_json, { tags = {}, oplog = {} })
        if type(row.info.tags) ~= "table" then row.info.tags = {} end
        if type(row.info.oplog) ~= "table" then row.info.oplog = {} end
    end
    return rows, nil
end

local function count_children(env_config, collection)
    local row, err = db.query_row(env_config, [[
        SELECT coalesce(sum((NOT is_collection)::int), 0) AS file_count,
               coalesce(sum(is_collection::int), 0) AS folder_count
          FROM dav_files
         WHERE collection = $1
    ]], collection)
    if not row then return nil, nil, err end
    return tonumber(row.file_count) or 0, tonumber(row.folder_count) or 0, nil
end

local function dav_response_headers(row, env_config)
    local qetag = quoted_etag(row.etag or row.sha256)
    return {
        ["OC-FileId"] = oc_fileid(tonumber(row.id), env_config),
        ["OC-Etag"] = qetag,
        ["ETag"] = qetag,
    }
end

local function append_oplog(row, who, op_type, data)
    local info = row.info or { tags = {}, oplog = {} }
    info.oplog = info.oplog or {}
    info.oplog[#info.oplog + 1] = { now_epoch(), who or "anonymous", op_type, data or "" }
    return info
end

local function handle_login_v2_init(request, env_config, http)
    local agent = request.headers["user-agent"] or "app"
    local ip = request.headers["x-forwarded-for"] or "local"
    local hits, err = shared_store():incr("lf:init:" .. ip, 1, 0, 1200)
    if err then
        return http.error_response(500, { err })
    end
    if tonumber(hits) and tonumber(hits) > 100 then
        return http.json_response(429, { message = "Too many login flow initiations" })
    end

    local row, qerr = db.query_row(env_config,
        "INSERT INTO app_passwords (status, name) VALUES ('pending', $1) RETURNING id", agent)
    if not row then
        return http.error_response(500, { qerr or "failed to create app password row" })
    end
    local app_password_id = tonumber(row.id)
    local poll_token = make_token()
    local login_token = make_token()
    local ok1, se1 = store_set_json("lf:poll:" .. poll_token,
        { status = "pending", app_password_id = app_password_id }, 1200)
    if not ok1 then return http.error_response(500, { se1 }) end
    local ok2, se2 = store_set_json("lf:login:" .. login_token,
        { app_password_id = app_password_id, poll_token = poll_token }, 1200)
    if not ok2 then return http.error_response(500, { se2 }) end

    local base = "http://" .. (request.headers["host"] or "localhost:8081")
    return http.json_response(200, {
        poll = { token = poll_token, endpoint = base .. "/login/v2/poll" },
        login = base .. "/login/v2/flow?token=" .. login_token,
    })
end

local function handle_login_v2_grant(request, env_config, http)
    local form = form_decode(request.body)
    local token = form.token
    if not token then return http.json_response(404, { message = "Unknown login token" }) end
    local flow, err = store_get_json("lf:login:" .. token)
    if err then return http.error_response(500, { err }) end
    if not flow then return http.json_response(404, { message = "Unknown login token" }) end

    local user, uerr = db.get_profile_by_username(env_config, form.loginName or "")
    if uerr then return http.error_response(500, { uerr }) end
    if not user then
        return http.json_response(403, { message = "Invalid credentials" })
    end
    local full_user, fuerr = db.get_user_by_email(env_config, user.email)
    if fuerr then return http.error_response(500, { fuerr }) end
    if not full_user or not password.verify(form.password or "", full_user.password_hash, full_user.salt) then
        return http.json_response(403, { message = "Invalid credentials" })
    end

    local app_secret = make_token()
    local app_hash = password.hash(app_secret)
    if not app_hash then
        return http.error_response(500, { "failed to hash app password" })
    end

    local updated, uperr = db.query_row(env_config, [[
        UPDATE app_passwords
           SET status='ready', user_id=$2, password_hash=$3, secret=$4, mtime=now()
         WHERE id=$1 AND status='pending'
     RETURNING id
    ]], flow.app_password_id, full_user.id, app_hash, app_secret)
    if uperr then return http.error_response(500, { uperr }) end
    if not updated then
        return http.json_response(404, { message = "Unknown login token" })
    end

    local _, se = store_set_json("lf:poll:" .. flow.poll_token,
        { status = "ready", app_password_id = flow.app_password_id }, 1200)
    if se then return http.error_response(500, { se }) end

    return http.json_response(200, { granted = true })
end

local function handle_login_v2_poll(request, env_config, http)
    local token = form_decode(request.body).token
    if not token then return http.json_response(404, { message = "pending" }) end
    local state, err = store_get_json("lf:poll:" .. token)
    if err then return http.error_response(500, { err }) end
    if not state or state.status ~= "ready" then
        return http.json_response(404, { message = "pending" })
    end

    local row, qerr = db.query_row(env_config, [[
        WITH old AS (
            SELECT id, secret FROM app_passwords WHERE id = $1 AND status = 'ready'
        )
        UPDATE app_passwords a
           SET status = 'collected', secret = NULL, mtime = now()
          FROM old
         WHERE a.id = old.id
     RETURNING old.secret, a.user_id
    ]], state.app_password_id)
    if qerr then return http.error_response(500, { qerr }) end
    if not row or not row.secret then
        return http.json_response(404, { message = "pending" })
    end
    local urow, uid_err = db.get_user_by_id(env_config, row.user_id)
    if uid_err then return http.error_response(500, { uid_err }) end
    if not urow then
        return http.error_response(500, { "user disappeared during login flow" })
    end
    shared_store():delete("lf:poll:" .. token)
    local base = "http://" .. (request.headers["host"] or "localhost:8081")
    return http.json_response(200, {
        server = base,
        loginName = urow.username,
        appPassword = row.secret,
    })
end

local function ocs_envelope(statuscode, message, data)
    local status = statuscode == 200 and "ok" or "failure"
    return {
        ocs = {
            meta = { status = status, statuscode = statuscode, message = message or "", totalitems = "", itemsperpage = "" },
            data = data or cjson.null,
        }
    }
end

local function ocs_response(http_status, statuscode, message, data, http)
    return http.json_response(http_status, ocs_envelope(statuscode, message, data))
end

local function resolve_app_user(headers, env_config)
    local username, app_password = parse_basic_auth(headers)
    if not username or not app_password then
        return nil
    end
    local user, perr = db.get_profile_by_username(env_config, username)
    if perr then return nil, perr end
    if not user then return nil end
    local rows, qerr = db.query(env_config, "SELECT password_hash FROM app_passwords WHERE user_id = $1 AND status = 'collected'", user.id)
    if qerr then return nil, qerr end
    if not rows then return nil end
    for _, row in ipairs(rows) do
        if password.verify(app_password, row.password_hash, nil) then
            return user
        end
    end
    return nil
end

local function handle_ocs(request, env_config, http)
    if request.headers["ocs-apirequest"] ~= "true" then
        return ocs_response(401, 997, "Current user is not logged in", nil, http)
    end
    if request.query_params.format ~= "json" then
        return ocs_response(400, 998, "Invalid query", nil, http)
    end
    local user, auth_err = resolve_app_user(request.headers, env_config)
    if auth_err then
        return ocs_response(500, 500, auth_err, nil, http)
    end
    if not user then
        return ocs_response(401, 997, "Current user is not logged in", nil, http)
    end
    local data = {
        id = user.username,
        ["display-name"] = user.username,
        email = user.email,
        enabled = true,
        quota = { quota = -3, used = 0, free = -3, total = -3, relative = 0 },
    }
    if request.path == "/ocs/v2.php/cloud/user" then
        return ocs_response(200, 200, "OK", data, http)
    end
    local wanted = request.path:match("^/ocs/v2%.php/cloud/users/(.+)$")
    if wanted then
        if wanted ~= user.username then
            return ocs_response(403, 403, "Forbidden", nil, http)
        end
        return ocs_response(200, 200, "OK", data, http)
    end
    return nil
end

local function format_http_date(epoch)
    return os.date("!%a, %d %b %Y %H:%M:%S GMT", epoch)
end

local function format_iso8601(epoch)
    return os.date("!%Y-%m-%dT%H:%M:%SZ", epoch)
end

local function get_prop_value(ns, name, row, is_collection, env_config, child_counts)
    if ns == DAV_NS then
        if name == "getlastmodified" then
            return row.mtime_epoch and format_http_date(tonumber(row.mtime_epoch)) or nil
        elseif name == "creationdate" then
            return row.ctime_epoch and format_iso8601(tonumber(row.ctime_epoch)) or nil
        elseif name == "getetag" then
            return quoted_etag(row.etag or row.sha256)
        elseif name == "getcontenttype" then
            return is_collection and nil or (row.mime_type or "application/octet-stream")
        elseif name == "getcontentlength" then
            return is_collection and nil or tostring(row.size or 0)
        elseif name == "resourcetype" then
            return is_collection and "<d:collection/>" or ""
        elseif name == "displayname" then
            return row.name
        elseif name == "quota-available-bytes" then
            return "-3"
        elseif name == "quota-used-bytes" then
            return "0"
        end
    elseif ns == OC_NS then
        if name == "id" then
            return oc_fileid(tonumber(row.id), env_config)
        elseif name == "fileid" then
            return tostring(row.id)
        elseif name == "permissions" then
            return "RGDNVW"
        elseif name == "size" then
            return tostring(row.size or 0)
        elseif name == "favorite" then
            return "0"
        elseif name == "tags" then
            return table.concat(row.info.tags or {}, ",")
        elseif name == "checksums" then
            return row.sha256 and ("<oc:checksum>SHA-256:" .. row.sha256 .. "</oc:checksum>") or ""
        end
    elseif ns == NC_NS then
        if name == "has-preview" then
            return "false"
        elseif name == "is-encrypted" then
            return "0"
        elseif name == "contained-file-count" then
            if not is_collection then return nil end
            local counts = child_counts[row.name]
            return counts and tostring(counts.file_count) or "0"
        elseif name == "contained-folder-count" then
            if not is_collection then return nil end
            local counts = child_counts[row.name]
            return counts and tostring(counts.folder_count) or "0"
        elseif name == "mount-type" then
            return ""
        end
    elseif ns == LNT_NS then
        if name == "sha256" then
            return row.sha256 or ""
        elseif name == "s3-version-id" then
            return row.s3_version_id or ""
        elseif name == "cas-version" then
            return tostring(row.version or 0)
        elseif name == "collection" then
            return row.collection
        elseif name == "oplog" then
            return cjson.encode(row.info.oplog or {})
        elseif name == "upstream-checksum" then
            local upstream = row.info.upstream
            return (type(upstream) == "table" and upstream.checksum_sha256) or ""
        end
    end
    return nil
end

local function format_prop_xml(ns, name, value)
    local prefix
    if ns == DAV_NS then prefix = "d"
    elseif ns == OC_NS then prefix = "oc"
    elseif ns == NC_NS then prefix = "nc"
    elseif ns == LNT_NS then prefix = "lnt"
    else prefix = "x" end
    
    if name == "resourcetype" then
        return "<d:resourcetype>" .. value .. "</d:resourcetype>"
    elseif name == "checksums" then
        return "<oc:checksums>" .. value .. "</oc:checksums>"
    else
        return "<" .. prefix .. ":" .. name .. ">" .. xml_escape(value) .. "</" .. prefix .. ":" .. name .. ">"
    end
end

local function format_prop_empty(ns, name)
    local prefix
    if ns == DAV_NS then prefix = "d"
    elseif ns == OC_NS then prefix = "oc"
    elseif ns == NC_NS then prefix = "nc"
    elseif ns == LNT_NS then prefix = "lnt"
    else prefix = "x" end
    return "<" .. prefix .. ":" .. name .. "/>"
end

local function dav_propfind_xml(entries, propfind_req, env_config, user, child_counts)
    local out = {
        [[<?xml version="1.0" encoding="utf-8"?>]],
        [[<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns" xmlns:lnt="http://lunet.stenographer.cloud/ns">]]
    }
    
    for _, row in ipairs(entries) do
        local is_collection = row.is_collection == true or row.is_collection == "t"
        local name_enc = percent_encode_path(row.name)
        local href
        if row._is_root then
            href = "/remote.php/dav/files/" .. percent_encode_path(user) .. "/"
        elseif row.collection == "" then
            href = "/remote.php/dav/files/" .. percent_encode_path(user) .. "/" .. name_enc
        else
            href = "/remote.php/dav/files/" .. percent_encode_path(user) .. "/" .. percent_encode_path(row.collection) .. "/" .. name_enc
        end
        if is_collection and not row._is_root then href = href .. "/" end
        
        local props_200 = {}
        local props_404 = {}
        
        local function emit_prop(ns, name, value)
            if value == nil then
                props_404[#props_404 + 1] = { ns = ns, name = name }
            else
                props_200[#props_200 + 1] = { ns = ns, name = name, value = value }
            end
        end
        
        local props_to_emit = {}
        if propfind_req.allprop or #propfind_req.props == 0 then
            props_to_emit = {
                { ns = DAV_NS, name = "getlastmodified" },
                { ns = DAV_NS, name = "creationdate" },
                { ns = DAV_NS, name = "getetag" },
                { ns = DAV_NS, name = "getcontenttype" },
                { ns = DAV_NS, name = "getcontentlength" },
                { ns = DAV_NS, name = "resourcetype" },
                { ns = DAV_NS, name = "displayname" },
                { ns = DAV_NS, name = "quota-available-bytes" },
                { ns = DAV_NS, name = "quota-used-bytes" },
                { ns = OC_NS, name = "id" },
                { ns = OC_NS, name = "fileid" },
                { ns = OC_NS, name = "permissions" },
                { ns = OC_NS, name = "size" },
                { ns = OC_NS, name = "favorite" },
                { ns = OC_NS, name = "tags" },
                { ns = OC_NS, name = "checksums" },
                { ns = NC_NS, name = "has-preview" },
                { ns = NC_NS, name = "is-encrypted" },
                { ns = NC_NS, name = "contained-file-count" },
                { ns = NC_NS, name = "contained-folder-count" },
                { ns = NC_NS, name = "mount-type" },
            }
        else
            props_to_emit = propfind_req.props
        end
        
        for _, p in ipairs(props_to_emit) do
            local value = get_prop_value(p.ns, p.name, row, is_collection, env_config, child_counts)
            emit_prop(p.ns, p.name, value)
        end
        
        out[#out + 1] = "<d:response><d:href>" .. xml_escape(href) .. "</d:href>"
        
        if #props_200 > 0 then
            out[#out + 1] = "<d:propstat><d:prop>"
            for _, p in ipairs(props_200) do
                out[#out + 1] = format_prop_xml(p.ns, p.name, p.value)
            end
            out[#out + 1] = "</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>"
        end
        
        if #props_404 > 0 then
            out[#out + 1] = "<d:propstat><d:prop>"
            for _, p in ipairs(props_404) do
                out[#out + 1] = format_prop_empty(p.ns, p.name)
            end
            out[#out + 1] = "</d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>"
        end
        
        out[#out + 1] = "</d:response>"
    end
    
    out[#out + 1] = "</d:multistatus>"
    return table.concat(out)
end

local function handle_dav(request, env_config, http)
    local method = request.method
    local parsed, perr = parse_dav_path(request.path)
    if not parsed then
        if perr == "invalid_segment" then
            return http.response(409, { ["Content-Type"] = "application/xml" }, dav_error_xml("Invalid path segment"))
        end
        return nil, perr
    end

    if method == "OPTIONS" then
        local headers = {
            ["DAV"] = "1",
            ["Allow"] = "OPTIONS, GET, HEAD, PUT, DELETE, MKCOL, MOVE, PROPFIND, PROPPATCH",
            ["MS-Author-Via"] = "DAV",
        }
        return http.response(200, headers, "")
    end

    if parsed.nested and (method == "MKCOL" or method == "PUT" or method == "MOVE") then
        return http.response(409, { ["Content-Type"] = "application/xml" }, dav_error_xml("Nested paths are not supported"))
    end

    if method == "MKCOL" then
        if not parsed.is_collection then
            return http.response(409, { ["Content-Type"] = "application/xml" }, dav_error_xml("Nested paths are not supported"))
        end
        if is_reserved(parsed.collection) then
            return http.response(403, { ["Content-Type"] = "application/xml" }, dav_error_xml("Reserved collection prefix"))
        end
        local existing, gerr = get_dav_resource(env_config, "", parsed.collection)
        if gerr then return http.error_response(500, { gerr }) end
        if existing then
            return http.response(405, { ["Content-Type"] = "application/xml" }, dav_error_xml("Resource exists"))
        end
        local row, err = db.query_row(env_config, [[
            INSERT INTO dav_files (is_collection, collection, name, etag, info)
            VALUES (true, '', $1, $2, $3::jsonb)
            RETURNING id, etag
        ]], parsed.collection, make_token(), cjson.encode({ tags = {}, oplog = {} }))
        if not row then return http.error_response(500, { err }) end
        local headers = {
            ["OC-FileId"] = oc_fileid(tonumber(row.id), env_config),
            ["OC-Etag"] = quoted_etag(row.etag),
        }
        return http.response(201, headers, "")
    end

    if method == "PUT" then
        local parent_collection, file_name
        if parsed.is_file then
            if is_reserved(parsed.collection) then
                return http.response(403, { ["Content-Type"] = "application/xml" }, dav_error_xml("Reserved collection prefix"))
            end
            local parent, perr = get_dav_resource(env_config, "", parsed.collection)
            if perr then return http.error_response(500, { perr }) end
            if not parent or not (parent.is_collection == true or parent.is_collection == "t") then
                return http.response(409, { ["Content-Type"] = "application/xml" }, dav_error_xml("Parent collection does not exist"))
            end
            parent_collection = parsed.collection
            file_name = parsed.name
        elseif parsed.is_collection then
            if is_reserved(parsed.collection) then
                return http.response(403, { ["Content-Type"] = "application/xml" }, dav_error_xml("Reserved name prefix"))
            end
            local existing, gerr = get_dav_resource(env_config, "", parsed.collection)
            if gerr then return http.error_response(500, { gerr }) end
            if existing and (existing.is_collection == true or existing.is_collection == "t") then
                return http.response(409, { ["Content-Type"] = "application/xml" }, dav_error_xml("A collection with that name exists"))
            end
            parent_collection = ""
            file_name = parsed.collection
        else
            return http.response(409, { ["Content-Type"] = "application/xml" }, dav_error_xml("PUT requires a file path"))
        end
        local body = request.body or ""
        local sha = crypto.sha256_hex(body)
        local s3_key = env_config.behavior.S3_LANDING_PREFIX .. sha
        local mime_type = request.headers["content-type"] or "application/octet-stream"
        local who = parse_basic_auth(request.headers)

        -- Reuse the immutable locator when these bytes are already referenced.
        -- Versioned S3 would retain a full new version even at the same key, so
        -- an unconditional PutObject would not actually deduplicate storage.
        local stored, serr = get_content_locator(env_config, sha)
        if serr then return http.error_response(500, { serr }) end
        if not stored then
            -- Logical metadata can stop referencing a digest after overwrite or
            -- delete, while the immutable object version remains retained.
            stored, serr = s3.head_object(env_config, s3_key)
            if serr then return http.error_response(500, { serr }) end
        end
        if not stored then
            -- Bytes go to the object store FIRST; metadata is only written for
            -- content that is durably stored.
            stored, serr = s3.put_object(env_config, s3_key, body, mime_type)
            if not stored then return http.error_response(500, { serr }) end
        end
        local loc_key = stored.s3_key or s3_key
        local loc_version = stored.version_id or stored.s3_version_id
        if env_config.behavior.S3_API_PROFILE ~= "lcd" and not stored.checksum_sha256 then
            local head = s3.head_object(env_config, loc_key)
            if head and head.checksum_sha256 then
                stored.checksum_sha256 = head.checksum_sha256
            end
        end

        local existing, gerr = get_dav_resource(env_config, parent_collection, file_name)
        if gerr then return http.error_response(500, { gerr }) end
        local status = 201
        local row
        if existing then
            status = 204
            local info = append_oplog(existing, who, "put", file_name)
            if stored.checksum_sha256 then
                info.upstream = { checksum_sha256 = stored.checksum_sha256, stored_at = now_epoch() }
            end
            local uerr
            row, uerr = db.query_row(env_config, [[
                UPDATE dav_files
                   SET sha256=$3, s3_key=$4, s3_version_id=$5, etag=$6, mime_type=$7, size=$8,
                       version=version+1, mtime=now(), info=$9::jsonb
                 WHERE id=$1 AND collection=$2 AND version=$10
             RETURNING id, etag, sha256, version
            ]], existing.id, parent_collection, sha, loc_key, loc_version, stored.etag, mime_type, #body, cjson.encode(info), existing.version)
            if uerr then return http.error_response(500, { uerr }) end
            if not row then
                return http.response(412, { ["Content-Type"] = "application/xml" }, dav_error_xml("Write race detected"))
            end
        else
            local info = append_oplog({ info = { tags = {}, oplog = {} } }, who, "put", file_name)
            if stored.checksum_sha256 then
                info.upstream = { checksum_sha256 = stored.checksum_sha256, stored_at = now_epoch() }
            end
            local ierr
            row, ierr = db.query_row(env_config, [[
                INSERT INTO dav_files (is_collection, collection, name, sha256, s3_bucket, s3_key, s3_version_id, etag, mime_type, size, info)
                VALUES (false, $1, $2, $3, $4, $5, $6, $7, $8, $9, $10::jsonb)
                RETURNING id, etag, sha256, version
            ]], parent_collection, file_name, sha, env_config.S3_BUCKET, loc_key, loc_version, stored.etag, mime_type, #body, cjson.encode(info))
            if ierr then return http.error_response(500, { ierr }) end
            if not row then return http.error_response(500, { "failed to create file" }) end
        end
        local headers = dav_response_headers(row, env_config)
        -- The upstream table is the harvested PUT/HEAD exchange; on the
        -- metadata-reuse path only the persisted locator fields are known
        -- (docs/DESIGN.md §8: unharvested passthrough names are skipped).
        dav_headers.apply_put_policy(headers, {
            mode = env_config.behavior.DAV_EMIT_HASH_HEADER,
            requested_hash = request.headers["x-hash"] == "sha256",
            sha256 = sha,
            passthrough = env_config.behavior.DAV_PUT_PASSTHROUGH_HEADERS,
            upstream = {
                version_id = loc_version,
                etag = stored.etag,
                checksum_sha256 = stored.checksum_sha256,
            },
        })
        if request.headers["x-oc-mtime"] then
            headers["X-OC-MTime"] = "accepted"
        end
        if request.headers["x-oc-ctime"] then
            headers["X-OC-CTime"] = "accepted"
        end
        return http.response(status, headers, "")
    end

    if method == "GET" or method == "HEAD" then
        local lookup_collection, lookup_name
        if parsed.is_file then
            lookup_collection = parsed.collection
            lookup_name = parsed.name
        elseif parsed.is_collection then
            lookup_collection = ""
            lookup_name = parsed.collection
        else
            return http.response(404, { ["Content-Type"] = "application/xml" }, dav_error_xml("Not found"))
        end
        local row, gerr = get_dav_resource(env_config, lookup_collection, lookup_name)
        if gerr then return http.error_response(500, { gerr }) end
        if not row then
            return http.response(404, { ["Content-Type"] = "application/xml" }, dav_error_xml("Not found"))
        end
        if row.is_collection == true or row.is_collection == "t" then
            return http.response(501, { ["Content-Type"] = "application/xml" }, dav_error_xml("Folder downloads are not implemented"))
        end
        local headers = dav_response_headers(row, env_config)
        headers["Content-Type"] = row.mime_type or "application/octet-stream"
        headers["Content-Length"] = tostring(tonumber(row.size) or 0)
        if row.mtime_epoch then
            headers["Last-Modified"] = format_http_date(tonumber(row.mtime_epoch))
        end
        if method == "HEAD" then
            return http.response(200, headers, "")
        end
        local body, gerr = s3.get_object(env_config, row.s3_key, row.s3_version_id)
        if not body then
            return http.error_response(500, { gerr })
        end
        headers["Content-Length"] = tostring(#body)
        return http.response(200, headers, body)
    end

    if method == "DELETE" then
        local lookup_collection, lookup_name
        if parsed.is_file then
            lookup_collection = parsed.collection
            lookup_name = parsed.name
        elseif parsed.is_collection then
            lookup_collection = ""
            lookup_name = parsed.collection
        else
            return http.response(404, { ["Content-Type"] = "application/xml" }, dav_error_xml("Not found"))
        end
        local row, gerr = get_dav_resource(env_config, lookup_collection, lookup_name)
        if gerr then return http.error_response(500, { gerr }) end
        if not row then
            return http.response(404, { ["Content-Type"] = "application/xml" }, dav_error_xml("Not found"))
        end
        if row.is_collection == true or row.is_collection == "t" then
            local ok, err = db.query(env_config,
                "DELETE FROM dav_files WHERE collection = $1 OR id = $2",
                lookup_name, row.id)
            if not ok then return http.error_response(500, { err }) end
            return http.response(204, {}, "")
        end
        local deleted, derr = db.query_row(env_config,
            "DELETE FROM dav_files WHERE id = $1 AND collection = $2 AND name = $3 RETURNING id",
            row.id, lookup_collection, lookup_name)
        if not deleted and derr then return http.error_response(500, { derr }) end
        if not deleted then
            return http.response(404, { ["Content-Type"] = "application/xml" }, dav_error_xml("Not found"))
        end
        return http.response(204, {}, "")
    end

    if method == "COPY" then
        return http.response(409, { ["Content-Type"] = "application/xml" },
            dav_error_xml("COPY is not implemented in v0.1.0"))
    end

    if method == "MOVE" then
        local src_collection, src_name
        if parsed.is_file then
            src_collection = parsed.collection
            src_name = parsed.name
        elseif parsed.is_collection then
            local res, rerr = get_dav_resource(env_config, "", parsed.collection)
            if rerr then return http.error_response(500, { rerr }) end
            if not res then
                return http.response(404, { ["Content-Type"] = "application/xml" }, dav_error_xml("Source not found"))
            end
            if res.is_collection == true or res.is_collection == "t" then
                return http.response(409, { ["Content-Type"] = "application/xml" }, dav_error_xml("MOVE source must be a file"))
            end
            src_collection = ""
            src_name = parsed.collection
        else
            return http.response(409, { ["Content-Type"] = "application/xml" }, dav_error_xml("MOVE source must be a file"))
        end
        local source, serr = get_dav_resource(env_config, src_collection, src_name)
        if serr then return http.error_response(500, { serr }) end
        if not source then
            return http.response(404, { ["Content-Type"] = "application/xml" }, dav_error_xml("Source not found"))
        end
        local destination = request.headers["destination"] or ""
        local dest_path = destination:match("^https?://[^/]+(.+)$") or destination
        local dest, derr = parse_dav_path(dest_path)
        if not dest or derr then
            return http.response(409, { ["Content-Type"] = "application/xml" }, dav_error_xml("Invalid destination"))
        end
        local dest_collection, dest_name
        if dest.is_file then
            dest_collection = dest.collection
            dest_name = dest.name
        elseif dest.is_collection then
            dest_collection = ""
            dest_name = dest.collection
        else
            return http.response(409, { ["Content-Type"] = "application/xml" }, dav_error_xml("Invalid destination"))
        end
        if is_reserved(dest_collection) then
            return http.response(403, { ["Content-Type"] = "application/xml" }, dav_error_xml("Reserved collection prefix"))
        end
        if is_reserved(dest_name) then
            return http.response(403, { ["Content-Type"] = "application/xml" }, dav_error_xml("Reserved name prefix"))
        end
        if dest.is_file then
            local dest_parent, dperr = get_dav_resource(env_config, "", dest.collection)
            if dperr then return http.error_response(500, { dperr }) end
            if not dest_parent then
                return http.response(409, { ["Content-Type"] = "application/xml" }, dav_error_xml("Destination parent missing"))
            end
        end
        local existing_dest, ederr = get_dav_resource(env_config, dest_collection, dest_name)
        if ederr then return http.error_response(500, { ederr }) end
        if existing_dest and (existing_dest.is_collection == true or existing_dest.is_collection == "t") then
            return http.response(409, { ["Content-Type"] = "application/xml" }, dav_error_xml("Destination is a collection"))
        end
        local overwrite = (request.headers["overwrite"] or "T"):upper()
        if existing_dest and overwrite == "F" then
            return http.response(412, { ["Content-Type"] = "application/xml" }, dav_error_xml("Overwrite disabled"))
        end
        if dest_collection == src_collection and dest_name == src_name then
            return http.response(409, { ["Content-Type"] = "application/xml" }, dav_error_xml("cannot move a file onto itself"))
        end
        local status = existing_dest and 204 or 201
        local info = append_oplog(source, parse_basic_auth(request.headers), "move", dest_collection .. "/" .. dest_name)
        local info_json = cjson.encode(info)
        local moved
        if existing_dest then
            local err
            moved, err = db.transaction(env_config, function(tx)
                tx.query("DELETE FROM dav_files WHERE id = $1", existing_dest.id)
                local updated = tx.query_row([[
                    UPDATE dav_files
                       SET collection=$2, name=$3, version=version+1, mtime=now(), info=$4::jsonb
                     WHERE id=$1 AND version=$5
                 RETURNING id, etag, sha256
                ]], source.id, dest_collection, dest_name, info_json, source.version)
                if not updated then
                    return nil, "cas"
                end
                return updated
            end)
            if not moved then
                if err == "cas" then
                    return http.response(412, { ["Content-Type"] = "application/xml" }, dav_error_xml("Write race detected"))
                end
                return http.error_response(500, { err })
            end
        else
            local merr
            moved, merr = db.query_row(env_config, [[
                UPDATE dav_files
                   SET collection=$2, name=$3, version=version+1, mtime=now(), info=$4::jsonb
                 WHERE id=$1 AND version=$5
             RETURNING id, etag, sha256
            ]], source.id, dest_collection, dest_name, info_json, source.version)
            if merr then return http.error_response(500, { merr }) end
            if not moved then
                return http.response(412, { ["Content-Type"] = "application/xml" }, dav_error_xml("Write race detected"))
            end
        end
        local headers = dav_response_headers(moved, env_config)
        return http.response(status, headers, "")
    end

    if method == "PROPFIND" then
        local depth = (request.headers["depth"] or "0"):lower()
        if depth == "infinity" then
            return http.response(403, { ["Content-Type"] = "application/xml" }, dav_error_xml("Depth infinity is not allowed"))
        end
        local propfind_req, perr = dav_xml.parse_propfind(request.body)
        if not propfind_req then
            return http.response(400, { ["Content-Type"] = "application/xml" }, dav_error_xml("Malformed propfind body: " .. (perr or "")))
        end
        local entries = {}
        local child_counts = {}
        if parsed.is_file then
            local row, gerr = get_dav_resource(env_config, parsed.collection, parsed.name)
            if gerr then return http.error_response(500, { gerr }) end
            if not row then return http.response(404, { ["Content-Type"] = "application/xml" }, dav_error_xml("Not found")) end
            entries[1] = row
        elseif parsed.is_collection then
            local row, gerr2 = get_dav_resource(env_config, "", parsed.collection)
            if gerr2 then return http.error_response(500, { gerr2 }) end
            if row and (row.is_collection == true or row.is_collection == "t") then
                entries[1] = row
                if depth == "1" then
                    local children, cerr = list_dav_children(env_config, parsed.collection)
                    if cerr then return http.error_response(500, { cerr }) end
                    for _, child in ipairs(children or {}) do
                        entries[#entries + 1] = child
                    end
                end
                local fc, fdc, ccerr = count_children(env_config, parsed.collection)
                if ccerr then return http.error_response(500, { ccerr }) end
                child_counts[parsed.collection] = { file_count = fc, folder_count = fdc }
            elseif row then
                entries[1] = row
            else
                return http.response(404, { ["Content-Type"] = "application/xml" }, dav_error_xml("Not found"))
            end
        else
            local root_entry = {
                _is_root = true,
                id = 0,
                is_collection = true,
                collection = "",
                name = parsed.user,
                sha256 = nil,
                s3_key = nil,
                s3_version_id = nil,
                etag = nil,
                mime_type = nil,
                size = 0,
                version = 0,
                ctime = nil,
                mtime = nil,
                ctime_epoch = nil,
                mtime_epoch = nil,
                info = { tags = {}, oplog = {} },
            }
            entries[1] = root_entry
            if depth == "1" then
                local children, cerr = list_dav_children(env_config, "")
                if cerr then return http.error_response(500, { cerr }) end
                for _, child in ipairs(children or {}) do
                    entries[#entries + 1] = child
                end
            end
            local fc, fdc, ccerr = count_children(env_config, "")
            if ccerr then return http.error_response(500, { ccerr }) end
            child_counts[parsed.user] = { file_count = fc, folder_count = fdc }
        end
        local body = dav_propfind_xml(entries, propfind_req, env_config, parsed.user, child_counts)
        return http.response(207, { ["Content-Type"] = "application/xml; charset=utf-8" }, body)
    end

    if method == "PROPPATCH" then
        local lookup_collection, lookup_name
        if parsed.is_file then
            lookup_collection = parsed.collection
            lookup_name = parsed.name
        elseif parsed.is_collection then
            lookup_collection = ""
            lookup_name = parsed.collection
        else
            return http.response(404, { ["Content-Type"] = "application/xml" }, dav_error_xml("Not found"))
        end
        local row, gerr = get_dav_resource(env_config, lookup_collection, lookup_name)
        if gerr then return http.error_response(500, { gerr }) end
        if not row or (row.is_collection == true or row.is_collection == "t") then
            return http.response(404, { ["Content-Type"] = "application/xml" }, dav_error_xml("Not found"))
        end
        local body = request.body or ""
        local update, perr = dav_xml.parse_propertyupdate(body)
        if not update then
            return http.response(400, { ["Content-Type"] = "application/xml" }, dav_error_xml("Malformed XML"))
        end
        local prop_results = {}
        local has_set_tags = false
        local has_remove_tags = false
        local set_tags_value = nil
        local who = parse_basic_auth(request.headers)
        for _, op in ipairs(update.set) do
            if op.ns == OC_NS and op.name == "tags" then
                has_set_tags = true
                set_tags_value = op.tags or {}
                prop_results[#prop_results + 1] = { ns = op.ns, name = op.name, status = 200 }
            elseif op.ns == OC_NS and op.name == "favorite" then
                prop_results[#prop_results + 1] = { ns = op.ns, name = op.name, status = 403 }
            else
                prop_results[#prop_results + 1] = { ns = op.ns, name = op.name, status = 403 }
            end
        end
        for _, op in ipairs(update.remove) do
            if op.ns == OC_NS and op.name == "tags" then
                has_remove_tags = true
                prop_results[#prop_results + 1] = { ns = op.ns, name = op.name, status = 200 }
            elseif op.ns == OC_NS and op.name == "favorite" then
                prop_results[#prop_results + 1] = { ns = op.ns, name = op.name, status = 403 }
            else
                prop_results[#prop_results + 1] = { ns = op.ns, name = op.name, status = 403 }
            end
        end
        if has_set_tags or has_remove_tags then
            local info = row.info
            local old_set = {}
            for _, t in ipairs(info.tags or {}) do old_set[t] = true end
            local final_set = has_set_tags and set_tags_value or {}
            local new_set = {}
            for _, t in ipairs(final_set) do new_set[t] = true end
            for t, _ in pairs(new_set) do
                if not old_set[t] then
                    info = append_oplog({ info = info }, who, "set-label", t)
                end
            end
            for t, _ in pairs(old_set) do
                if not new_set[t] then
                    info = append_oplog({ info = info }, who, "unset-label", t)
                end
            end
            info.tags = final_set
            local updated, uerr = db.query_row(env_config,
                "UPDATE dav_files SET version=version+1, mtime=now(), info=$2::jsonb WHERE id=$1 AND version=$3 RETURNING id",
                row.id, cjson.encode(info), row.version)
            if uerr then return http.error_response(500, { uerr }) end
            if not updated then
                return http.response(412, { ["Content-Type"] = "application/xml" }, dav_error_xml("Write race detected"))
            end
        end
        local out = {
            [[<?xml version="1.0" encoding="utf-8"?>]],
            [[<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">]]
        }
        for _, pr in ipairs(prop_results) do
            out[#out + 1] = "<d:response><d:propstat><d:prop>"
            out[#out + 1] = format_prop_empty(pr.ns, pr.name)
            out[#out + 1] = "</d:prop><d:status>HTTP/1.1 " .. pr.status .. " " .. (pr.status == 200 and "OK" or "Forbidden") .. "</d:status></d:propstat></d:response>"
        end
        out[#out + 1] = "</d:multistatus>"
        return http.response(207, { ["Content-Type"] = "application/xml; charset=utf-8" }, table.concat(out))
    end

    return http.response(501, { ["Content-Type"] = "application/xml" }, dav_error_xml("Method not implemented"))
end

function nc31.handle(request, env_config, http)
    if request.path == "/index.php/login/v2" and request.method == "POST" then
        return handle_login_v2_init(request, env_config, http)
    end
    if request.path == "/login/v2/grant" and request.method == "POST" then
        return handle_login_v2_grant(request, env_config, http)
    end
    if request.path == "/login/v2/poll" and request.method == "POST" then
        return handle_login_v2_poll(request, env_config, http)
    end
    if request.path:find("^/ocs/v2%.php/cloud/") and request.method == "GET" then
        return handle_ocs(request, env_config, http)
    end
    if request.path:sub(1, #DAV_PREFIX) == DAV_PREFIX then
        local resp = handle_dav(request, env_config, http)
        if resp then return resp end
    end
    return nil
end

return nc31
