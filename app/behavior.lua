-- Behavior configuration (docs/DESIGN.md §7).
-- Layered resolve: Lua defaults (SCHEMA below) < .env < real environment
-- variables. Unknown DAV_/S3_ keys in .env are rejected (typo guard).
--
-- resolve(env_file, getenv):
--   env_file — map of key -> string from dotenv ({} when absent)
--   getenv   — function(name) -> string|nil (os.getenv in production)
-- returns behavior table, or nil + errors[] naming every bad key.

local SCHEMA = {
    DAV_INSTANCE_ID = { kind = "string", default = "oczn5x60nrdu" },
    DAV_FILEID_PAD_WIDTH = { kind = "number", default = 8, min = 1, max = 32, integer = true },
    S3_LANDING_PREFIX = { kind = "string", default = "_landing/" },
    S3_API_PROFILE = {
        kind = "enum",
        default = "lcd",
        values = { lcd = true, minio = true, ["minio-enterprise"] = true },
    },
    DAV_EMIT_HASH_HEADER = {
        kind = "enum",
        default = "on-request",
        values = { ["on-request"] = true, always = true, never = true },
    },
    DAV_PUT_PASSTHROUGH_HEADERS = { kind = "list", default = {} },
    DAV_MAX_UPLOAD_BYTES = { kind = "number", default = 536870912, min = 1, integer = true },
}

-- Recognized but resolved by config.lua (connection vars). Listing them lets
-- the typo guard cover the whole DAV_/S3_ namespace in .env.
local KNOWN_ELSEWHERE = {
    S3_ENDPOINT = true,
    S3_REGION = true,
    S3_BUCKET = true,
    S3_ACCESS_KEY_ID = true,
    S3_SECRET_ACCESS_KEY = true,
}

local function coerce_list(raw)
    local set = {}
    for item in raw:gmatch("[^,]+") do
        local name = item:match("^%s*(.-)%s*$"):lower()
        if name ~= "" then
            set[name] = true
        end
    end
    return set
end

local function resolve(env_file, getenv)
    env_file = env_file or {}
    getenv = getenv or function() return nil end

    local errors = {}

    -- Only the .env layer is enumerable, so only it can be typo-checked (a
    -- mistyped real env var is indistinguishable from an unset one).
    for key, _ in pairs(env_file) do
        if (key:match("^DAV_") or key:match("^S3_"))
            and not SCHEMA[key] and not KNOWN_ELSEWHERE[key] then
            errors[#errors + 1] = "unknown behavior key in .env: " .. key
        end
    end

    local b = {}
    for key, spec in pairs(SCHEMA) do
        local raw = getenv(key)
        if raw == nil or raw == "" then raw = env_file[key] end
        if raw == "" then raw = nil end

        if raw == nil then
            b[key] = (spec.kind == "list") and {} or spec.default
        elseif spec.kind == "string" then
            b[key] = raw
        elseif spec.kind == "number" then
            local n = tonumber(raw)
            if not n then
                errors[#errors + 1] = key .. " must be a number, got: " .. raw
            elseif spec.integer and n ~= math.floor(n) then
                errors[#errors + 1] = key .. " must be an integer, got: " .. raw
            elseif spec.min and n < spec.min then
                errors[#errors + 1] = key .. " must be >= " .. spec.min .. ", got: " .. raw
            elseif spec.max and n > spec.max then
                errors[#errors + 1] = key .. " must be <= " .. spec.max .. ", got: " .. raw
            else
                b[key] = n
            end
        elseif spec.kind == "enum" then
            if not spec.values[raw] then
                errors[#errors + 1] = key .. " has an unsupported value: " .. raw
            else
                b[key] = raw
            end
        elseif spec.kind == "list" then
            b[key] = coerce_list(raw)
        end
    end

    if #errors > 0 then
        table.sort(errors)
        return nil, errors
    end
    return b, nil
end

return { resolve = resolve }
