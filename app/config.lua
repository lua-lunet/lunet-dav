-- Config module - Centralized environment variable resolution
-- Single point of truth for all environment variable access

local json = require("cjson")
local dotenv = require("dotenv")

-- Static definition of required environment variables
-- Each entry: { name = "VAR_NAME", secret = boolean }
local REQUIRED_VARS = {
    { name = "PGHOST", secret = false },
    { name = "PGPORT", secret = false },
    { name = "PGDATABASE", secret = false },
    { name = "PGUSER", secret = false },
    { name = "PGPASSWORD", secret = true },
    { name = "JWT_SECRET", secret = true },
    -- S3 object store for DAV file bytes (MinIO locally; see docs/DESIGN.md §2)
    { name = "S3_ENDPOINT", secret = false },
    { name = "S3_REGION", secret = false },
    { name = "S3_BUCKET", secret = false },
    { name = "S3_ACCESS_KEY_ID", secret = true },
    { name = "S3_SECRET_ACCESS_KEY", secret = true },
}

-- Cached result of the first successful resolve (per worker)
local cached_config

-- Render config as a JSON string with secret values masked
local function masked_json(config)
    local masked = {}
    for _, var_def in ipairs(REQUIRED_VARS) do
        if config[var_def.name] then
            masked[var_def.name] = var_def.secret and "***" or config[var_def.name]
        end
    end
    return json.encode(masked)
end

-- Resolve all required environment variables into a config table
-- Uses dotenv to load from .env file (os.getenv does not see them in
-- OpenResty worker processes); falls back to os.getenv outside nginx
-- @return config: table with all resolved values, or nil
-- @return errors: table of missing variable names, or nil
local function resolve_config()
    if cached_config then
        return cached_config, nil
    end

    local config = {}
    local errors = {}
    local env_from_file = dotenv.load_dotenv()

    for _, var_def in ipairs(REQUIRED_VARS) do
        local value = env_from_file[var_def.name] or os.getenv(var_def.name)
        if not value or value == "" then
            table.insert(errors, var_def.name)
        else
            config[var_def.name] = value
        end
    end

    if #errors > 0 then
        return nil, errors
    end

    -- Optional: set PGSSLMODE=require for databases that mandate TLS
    config.PGSSLMODE = env_from_file.PGSSLMODE or os.getenv("PGSSLMODE")

    cached_config = config
    if ngx then
        ngx.log(ngx.NOTICE, "Resolved config: ", masked_json(config))
    end
    return config, nil
end

return {
    resolve = resolve_config,
}
