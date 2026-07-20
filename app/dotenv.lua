-- dotenv.lua - Load environment variables from .env file
-- Mimics Python's load_dotenv() behavior
-- Returns a frozen, immutable table

local M = {}

-- Parse .env file into a table
local function parse_dotenv(path)
    local env = {}
    local file = io.open(path, "r")
    if not file then return env end

    for line in file:lines() do
        line = line:match("^%s*(.-)%s*$") or line  -- trim whitespace
        if line ~= "" and not line:match("^#") then  -- skip empty lines and comments
            local key, value = line:match("^([^=]+)=(.*)$")
            if key then
                -- Remove surrounding quotes if present
                value = value:match('^"(.*)"$') or value:match("'(.*)'") or value
                env[key] = value
            end
        end
    end
    file:close()
    return env
end

-- Create an immutable table
local function freeze(t)
    return setmetatable(t, {
        __newindex = function()
            error("Cannot modify dotenv table - it is immutable", 2)
        end
    })
end

-- Load .env file and return an immutable table
-- Defaults to ".env" in the current directory if no path is provided
function M.load_dotenv(path)
    local env = parse_dotenv(path or ".env")
    -- Override with existing environment variables
    for k, _ in pairs(env) do
        local val = os.getenv(k)
        if val then
            env[k] = val
        end
    end
    return freeze(env)
end

return M
