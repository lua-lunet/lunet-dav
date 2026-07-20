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

-- ==================== ARTICLES ====================

-- Get article by slug
-- @param slug: article slug
-- @return article: table with article data, or nil
-- @return err: error message, or nil
function db.get_article_by_slug(env_config, slug)
    local sql = [[
        SELECT a.id, a.slug, a.title, a.description, a.body,
               iso8601(a.created_at) AS created_at, iso8601(a.updated_at) AS updated_at,
               a.author_id, u.username, u.bio, u.image,
               (SELECT COUNT(*) FROM article_favorites f WHERE f.article_id = a.id) as favorites_count
        FROM articles a
        JOIN users u ON a.author_id = u.id
        WHERE a.slug = $1
    ]]
    local row, err = db.query_row(env_config, sql, slug)
    if not row then
        return nil, err
    end
    return row, nil
end

-- List articles (with optional filters)
-- @param limit: max number of articles
-- @param offset: starting offset
-- @param author_id: filter by author (optional)
-- @param tag: filter by tag (optional)
-- @param favorited: filter by favorited user (optional)
-- @return articles: table of article data, or nil
-- @return err: error message, or nil
function db.list_articles(env_config, limit, offset, author_id, tag, favorited)
    local params = {}
    local conditions = {}
    local param_index = 1

    if author_id then
        table.insert(conditions, "a.author_id = $" .. param_index .. "")
        table.insert(params, author_id)
        param_index = param_index + 1
    end

    if tag then
        table.insert(
            conditions,
            "a.id IN (SELECT article_id FROM article_tags at JOIN tags t ON at.tag_id = t.id WHERE t.name = $" .. param_index
                .. ")"
        )
        table.insert(params, tag)
        param_index = param_index + 1
    end

    if favorited then
        table.insert(
            conditions, "a.id IN (SELECT article_id FROM article_favorites WHERE user_id = $" .. param_index .. ")"
        )
        table.insert(params, favorited)
        param_index = param_index + 1
    end

    local where_clause = ""
    if #conditions > 0 then
        where_clause = "WHERE " .. table.concat(conditions, " AND ")
    end

    -- Get total count first
    local count_sql = "SELECT COUNT(*) as count FROM articles a " .. where_clause
    local count_row, err = db.query_row(env_config, count_sql, unpack(params))
    local total_count = 0
    if count_row then
        total_count = tonumber(count_row.count) or 0
    end

    -- Add limit and offset for the main query
    local query_params = {}
    for i, v in ipairs(params) do
        query_params[i] = v
    end
    table.insert(query_params, limit)
    table.insert(query_params, offset)

    local sql = string.format(
        [[
        SELECT a.id, a.slug, a.title, a.description, a.body,
               iso8601(a.created_at) AS created_at, iso8601(a.updated_at) AS updated_at,
               a.author_id, u.username, u.bio, u.image,
               (SELECT COUNT(*) FROM article_favorites f WHERE f.article_id = a.id) as favorites_count,
               (SELECT COUNT(*) FROM article_tags at2 WHERE at2.article_id = a.id) as tag_count
        FROM articles a
        JOIN users u ON a.author_id = u.id
        %s
        ORDER BY a.created_at DESC
        LIMIT $%d OFFSET $%d
    ]], where_clause, param_index, param_index + 1
    )

    local rows, err = db.query(env_config, sql, unpack(query_params))
    if not rows then
        return nil, err, 0
    end
    return rows, nil, total_count
end

-- Create article
-- @param article: table with slug, title, description, body, author_id
-- @return article: table with created article data, or nil
-- @return err: error message, or nil
function db.create_article(env_config, article)
    local sql = [[
        INSERT INTO articles (slug, title, description, body, author_id)
        VALUES ($1, $2, $3, $4, $5)
        RETURNING id, slug, title, description, body, author_id,
                  iso8601(created_at) AS created_at, iso8601(updated_at) AS updated_at
    ]]
    local row, err = db.query_row(env_config, sql, article.slug, article.title, article.description, article.body, article.author_id)
    if not row then
        return nil, err
    end
    return row, nil
end

-- Update article
-- @param slug: article slug
-- @param updates: table with fields to update
-- @return article: table with updated article data, or nil
-- @return err: error message, or nil
function db.update_article(env_config, slug, updates)
    local fields = {}
    local values = {}
    local param_index = 1

    for key, value in pairs(updates) do
        if value ~= nil then
            table.insert(fields, key .. " = $" .. param_index)
            table.insert(values, value)
            param_index = param_index + 1
        end
    end

    if #fields == 0 then
        return db.get_article_by_slug(env_config, slug)
    end

    -- Always update updated_at
    table.insert(fields, "updated_at = CURRENT_TIMESTAMP")

    table.insert(values, slug)
    local sql = "UPDATE articles SET " .. table.concat(fields, ", ") .. " WHERE slug = $" .. param_index
        .. " RETURNING id, slug, title, description, body, author_id,"
        .. " iso8601(created_at) AS created_at, iso8601(updated_at) AS updated_at"
    local row, err = db.query_row(env_config, sql, unpack(values))
    if not row then
        return nil, err
    end
    return row, nil
end

-- Delete article
-- @param slug: article slug
-- @return success: boolean
-- @return err: error message, or nil
function db.delete_article(env_config, slug)
    local sql = "DELETE FROM articles WHERE slug = $1"
    local ok, err = db.query(env_config, sql, slug)
    if not ok then
        return false, err
    end
    return true, nil
end

-- ==================== ARTICLE TAGS ====================

-- Get tags for an article
-- @param article_id: article id
-- @return tags: table of tag names, or nil
-- @return err: error message, or nil
function db.get_article_tags(env_config, article_id)
    local sql = [[
        SELECT t.name
        FROM article_tags at
        JOIN tags t ON at.tag_id = t.id
        WHERE at.article_id = $1
        ORDER BY t.name
    ]]
    local rows, err = db.query(env_config, sql, article_id)
    if not rows then
        return nil, err
    end
    local tags = {}
    for _, row in ipairs(rows) do
        table.insert(tags, row.name)
    end
    return tags, nil
end

-- Get or create tag by name
-- @param name: tag name
-- @return tag_id: number, or nil
-- @return err: error message, or nil
function db.get_or_create_tag(env_config, name)
    -- Try to find existing tag
    local sql = "SELECT id FROM tags WHERE name = $1"
    local row, err = db.query_row(env_config, sql, name)
    if err then
        return nil, err
    end
    if row then
        return row.id, nil
    end

    -- Create new tag
    sql = "INSERT INTO tags (name) VALUES ($1) RETURNING id"
    row, err = db.query_row(env_config, sql, name)
    if not row then
        return nil, err
    end
    return row.id, nil
end

-- Set tags for an article
-- @param article_id: article id
-- @param tag_names: table of tag names
-- @return success: boolean
-- @return err: error message, or nil
function db.set_article_tags(env_config, article_id, tag_names)
    -- First, clear existing tags
    local ok, err = db.query(env_config, "DELETE FROM article_tags WHERE article_id = $1", article_id)
    if not ok then
        return false, err
    end

    -- Add new tags
    for _, name in ipairs(tag_names) do
        local tag_id, err = db.get_or_create_tag(env_config, name)
        if not tag_id then
            return false, err
        end
        ok, err = db.query(env_config, "INSERT INTO article_tags (article_id, tag_id) VALUES ($1, $2)", article_id, tag_id)
        if not ok then
            return false, err
        end
    end

    return true, nil
end

-- Get all tags
-- @return tags: table of tag names, or nil
-- @return err: error message, or nil
function db.get_all_tags(env_config)
    local sql = "SELECT name FROM tags ORDER BY name"
    local rows, err = db.query(env_config, sql)
    if not rows then
        return nil, err
    end
    local tags = {}
    for _, row in ipairs(rows) do
        table.insert(tags, row.name)
    end
    return tags, nil
end

-- ==================== COMMENTS ====================

-- Get comments for an article
-- @param slug: article slug
-- @return comments: table of comment data, or nil
-- @return err: error message, or nil
function db.get_comments_by_article(env_config, slug)
    local sql = [[
        SELECT c.id, c.body, c.author_id, u.username, u.bio, u.image,
               iso8601(c.created_at) AS created_at, iso8601(c.updated_at) AS updated_at
        FROM comments c
        JOIN users u ON c.author_id = u.id
        JOIN articles a ON c.article_id = a.id
        WHERE a.slug = $1
        ORDER BY c.created_at DESC
    ]]
    local rows, err = db.query(env_config, sql, slug)
    if not rows then
        return nil, err
    end
    return rows, nil
end

-- Get comment by id
-- @param id: comment id
-- @return comment: table with comment data, or nil
-- @return err: error message, or nil
function db.get_comment_by_id(env_config, id)
    local sql = [[
        SELECT c.id, c.body, c.author_id, c.article_id, u.username, u.bio, u.image,
               iso8601(c.created_at) AS created_at, iso8601(c.updated_at) AS updated_at
        FROM comments c
        JOIN users u ON c.author_id = u.id
        WHERE c.id = $1
    ]]
    local row, err = db.query_row(env_config, sql, id)
    if not row then
        return nil, err
    end
    return row, nil
end

-- Create comment
-- @param comment: table with body, author_id, article_id
-- @return comment: table with created comment data, or nil
-- @return err: error message, or nil
function db.create_comment(env_config, comment)
    local sql = [[
        INSERT INTO comments (body, author_id, article_id)
        VALUES ($1, $2, $3)
        RETURNING id, body, author_id, article_id,
                  iso8601(created_at) AS created_at, iso8601(updated_at) AS updated_at
    ]]
    local row, err = db.query_row(env_config, sql, comment.body, comment.author_id, comment.article_id)
    if not row then
        return nil, err
    end
    return row, nil
end

-- Delete comment
-- @param id: comment id
-- @return success: boolean
-- @return err: error message, or nil
function db.delete_comment(env_config, id)
    local sql = "DELETE FROM comments WHERE id = $1"
    local ok, err = db.query(env_config, sql, id)
    if not ok then
        return false, err
    end
    return true, nil
end

-- ==================== FAVORITES ====================

-- Check if user favorited article
-- @param user_id: user id
-- @param article_id: article id
-- @return favorited: boolean
-- @return err: error message, or nil
function db.is_favorited(env_config, user_id, article_id)
    local sql = "SELECT 1 FROM article_favorites WHERE user_id = $1 AND article_id = $2"
    local row, err = db.query_row(env_config, sql, user_id, article_id)
    if err then
        return false, err
    end
    return row ~= nil, nil
end

-- Favorite an article
-- @param user_id: user id
-- @param article_id: article id
-- @return success: boolean
-- @return err: error message, or nil
function db.favorite_article(env_config, user_id, article_id)
    -- Idempotent and race-free under concurrent requests
    local sql = "INSERT INTO article_favorites (user_id, article_id) VALUES ($1, $2) ON CONFLICT DO NOTHING"
    local ok, err = db.query(env_config, sql, user_id, article_id)
    if not ok then
        return false, err
    end
    return true, nil
end

-- Unfavorite an article
-- @param user_id: user id
-- @param article_id: article id
-- @return success: boolean
-- @return err: error message, or nil
function db.unfavorite_article(env_config, user_id, article_id)
    local sql = "DELETE FROM article_favorites WHERE user_id = $1 AND article_id = $2"
    local ok, err = db.query(env_config, sql, user_id, article_id)
    if not ok then
        return false, err
    end
    return true, nil
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

-- Feed: Get articles from followed users
-- @param user_id: user id
-- @param limit: max number of articles
-- @param offset: starting offset
-- @return articles: table of article data, or nil
-- @return err: error message, or nil
function db.get_feed(env_config, user_id, limit, offset)
    -- Get total count first
    local count_sql = [[
        SELECT COUNT(*) as count
        FROM articles a
        WHERE a.author_id IN (SELECT followee_id FROM user_follows WHERE follower_id = $1)
        OR a.author_id = $1
    ]]
    local count_row, err = db.query_row(env_config, count_sql, user_id)
    local total_count = 0
    if count_row then
        total_count = tonumber(count_row.count) or 0
    end
    
    local sql = [[
        SELECT a.id, a.slug, a.title, a.description, a.body,
               iso8601(a.created_at) AS created_at, iso8601(a.updated_at) AS updated_at,
               a.author_id, u.username, u.bio, u.image,
               (SELECT COUNT(*) FROM article_favorites f WHERE f.article_id = a.id) as favorites_count,
               (SELECT COUNT(*) FROM article_tags at2 WHERE at2.article_id = a.id) as tag_count
        FROM articles a
        JOIN users u ON a.author_id = u.id
        WHERE a.author_id IN (SELECT followee_id FROM user_follows WHERE follower_id = $1)
        OR a.author_id = $1
        ORDER BY a.created_at DESC
        LIMIT $2 OFFSET $3
    ]]
    local rows, err = db.query(env_config, sql, user_id, limit, offset)
    if not rows then
        return nil, err, 0
    end
    return rows, nil, total_count
end

return db
