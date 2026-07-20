-- PostgreSQL database module using lunet.postgres
-- Coroutine-safe driver (queries run on libuv's thread pool) built into lunet
-- Every function takes env_config (the resolved config table) as its first argument

local native = require("lunet.postgres")

-- LuaJIT is Lua 5.1: unpack is global there, table.unpack on 5.2-compat builds
local unpack = table.unpack or unpack

local db = {}

-- Connection pool: array-backed, create-on-demand. Safe under lunet's
-- cooperative coroutines since table.remove/insert never yield.
local pool = {}
local POOL_SIZE = 100

-- Open a new connection using values from the passed-in env_config table
local function new_connection(env_config)
    local conn, err = native.open({
        host = env_config.PGHOST,
        port = tonumber(env_config.PGPORT),
        database = env_config.PGDATABASE,
        user = env_config.PGUSER,
        password = env_config.PGPASSWORD,
    })
    if not conn then
        io.stderr:write("PostgreSQL connect failed: ", tostring(err), "\n")
        return nil, "Failed to connect: " .. tostring(err)
    end
    return conn, nil
end

local function get_conn(env_config)
    local conn = table.remove(pool)
    if conn then
        return conn, nil
    end
    return new_connection(env_config)
end

local function release_conn(conn)
    if #pool < POOL_SIZE then
        table.insert(pool, conn)
    else
        native.close(conn)
    end
end

-- Execute a query
-- @param sql: SQL query string
-- @param ...: Optional parameters for parameterized queries
-- @return result: table of rows, or nil
-- @return err: error message, or nil
function db.query(env_config, sql, ...)
    local conn, err = get_conn(env_config)
    if not conn then
        return nil, err
    end

    local res, qerr = native.query(conn, sql, ...)
    if not res then
        native.close(conn)
        return nil, qerr
    end

    release_conn(conn)
    return res, nil
end

-- Execute a query and return a single row
-- @param sql: SQL query string
-- @param ...: Optional parameters
-- @return row: table of first row, or nil
-- @return err: error message, or nil
function db.query_row(env_config, sql, ...)
    local res, err = db.query(env_config, sql, ...)
    if not res then
        return nil, err
    end
    return res[1], nil
end

-- Get a user by email
-- @param email: user email
-- @return user: table with user data, or nil
-- @return err: error message, or nil
function db.get_user_by_email(env_config, email)
    local sql = "SELECT id, email, username, password_hash, salt, bio, image FROM users WHERE email = $1"
    local row, err = db.query_row(env_config, sql, email)
    if not row then
        return nil, err
    end
    return row, nil
end

-- Get a user by id
-- @param id: user id
-- @return user: table with user data, or nil
-- @return err: error message, or nil
function db.get_user_by_id(env_config, id)
    local sql = "SELECT id, email, username, bio, image FROM users WHERE id = $1"
    local row, err = db.query_row(env_config, sql, id)
    if not row then
        return nil, err
    end
    return row, nil
end

-- Create a new user
-- @param user: table with email, username, password_hash, bio, image
-- @return user: table with created user data including id, or nil
-- @return err: error message, or nil
function db.create_user(env_config, user)
    local sql = [[
        INSERT INTO users (email, username, password_hash, salt, bio, image)
        VALUES ($1, $2, $3, $4, $5, $6)
        RETURNING id, email, username, salt, bio, image
    ]]
    local row, err = db.query_row(env_config, sql, user.email, user.username, user.password_hash, user.salt, user.bio, user.image)
    if not row then
        return nil, err
    end
    return row, nil
end

-- ==================== FOLLOWS ====================

-- Check if user follows another user
-- @param follower_id: follower user id
-- @param followee_id: followee user id
-- @return following: boolean
-- @return err: error message, or nil
function db.is_following(env_config, follower_id, followee_id)
    local sql = "SELECT 1 FROM user_follows WHERE follower_id = $1 AND followee_id = $2"
    local row, err = db.query_row(env_config, sql, follower_id, followee_id)
    if err then
        return false, err
    end
    return row ~= nil, nil
end

-- Follow a user
-- @param follower_id: follower user id
-- @param followee_id: followee user id
-- @return success: boolean
-- @return err: error message, or nil
function db.follow_user(env_config, follower_id, followee_id)
    -- Idempotent and race-free under concurrent requests
    local sql = "INSERT INTO user_follows (follower_id, followee_id) VALUES ($1, $2) ON CONFLICT DO NOTHING"
    local ok, err = db.query(env_config, sql, follower_id, followee_id)
    if not ok then
        return false, err
    end
    return true, nil
end

-- Unfollow a user
-- @param follower_id: follower user id
-- @param followee_id: followee user id
-- @return success: boolean
-- @return err: error message, or nil
function db.unfollow_user(env_config, follower_id, followee_id)
    local sql = "DELETE FROM user_follows WHERE follower_id = $1 AND followee_id = $2"
    local ok, err = db.query(env_config, sql, follower_id, followee_id)
    if not ok then
        return false, err
    end
    return true, nil
end

-- Get profile by username
-- @param username: username
-- @return profile: table with user data, or nil
-- @return err: error message, or nil
function db.get_profile_by_username(env_config, username)
    local sql = "SELECT id, email, username, bio, image FROM users WHERE username = $1"
    local row, err = db.query_row(env_config, sql, username)
    if not row then
        return nil, err
    end
    return row, nil
end

return db
