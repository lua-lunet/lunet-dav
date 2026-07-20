-- Article routes for RealWorld API
-- Handles article CRUD, tags, favorites

local router = require("router")
local json = require("cjson")
local db = require("db")
local web = require("web")
local crypto = require("lib.crypto")

local json_response = web.json_response
local error_response = web.error_response
local get_current_user = web.get_current_user

-- Helper to format article response
local function format_article(env_config, article, current_user_id, include_body)
    if not article then
        return nil
    end
    
    if include_body == nil then include_body = true end
    
    local formatted = {
        slug = article.slug,
        title = article.title,
        description = article.description,
        createdAt = article.created_at,
        updatedAt = article.updated_at,
        favorited = false,
        favoritesCount = article.favorites_count or 0,
        author = {
            username = article.username,
            bio = article.bio,
            image = article.image,
            following = false
        }
    }
    
    if include_body then
        formatted.body = article.body
    end
    
    -- Get tags
    local tags, _ = db.get_article_tags(env_config, article.id)
    if tags and #tags > 0 then
        formatted.tagList = tags
    else
        formatted.tagList = {}
    end
    
    -- Check if favorited by current user
    if current_user_id then
        local is_favorited, _ = db.is_favorited(env_config, current_user_id, article.id)
        formatted.favorited = is_favorited
        
        -- Check if current user is following the author
        local is_following, _ = db.is_following(env_config, current_user_id, article.author_id)
        formatted.author.following = is_following
    end
    
    return formatted
end

-- Helper to format articles list (without body)
local function format_articles_list(env_config, articles, current_user_id)
    local formatted = {}
    for _, article in ipairs(articles) do
        table.insert(formatted, format_article(env_config, article, current_user_id, false))
    end
    return formatted
end

-- Helper to generate slug from title
local function generate_slug(title)
    -- Simple slug generation: lowercase, replace spaces with hyphens, remove special chars
    local slug = string.lower(title)
    slug = slug:gsub("[^a-z0-9%-_]", "-")
    slug = slug:gsub("%-+", "-")
    slug = slug:gsub("^%-+", "")
    slug = slug:gsub("%-+$", "")
    -- CSPRNG suffix keeps slugs unique across workers and concurrent requests
    local suffix = crypto.random_bytes(4):gsub(".", function(c) return string.format("%02x", c:byte()) end)
    return slug .. "-" .. suffix
end

-- List articles
router.route("GET", "/api/articles", function(env_config, ngx, params)
    local user, token, err = get_current_user(env_config, ngx)
    local current_user_id = user and user.id or nil
    
    -- Parse query parameters
    local limit = tonumber(ngx.var.arg_limit) or 20
    local offset = tonumber(ngx.var.arg_offset) or 0
    local author = ngx.var.arg_author
    local tag = ngx.var.arg_tag
    local favorited = ngx.var.arg_favorited
    
    -- Get author_id if author param is provided
    local author_id = nil
    if author then
        local profile = web.fetched(db.get_profile_by_username(env_config, author))
        if profile then
            author_id = profile.id
        else
            return error_response(422, { author = { "not found" } })
        end
    end
    
    -- Get favorited user_id if favorited param is provided
    local favorited_id = nil
    if favorited then
        local profile = web.fetched(db.get_profile_by_username(env_config, favorited))
        if profile then
            favorited_id = profile.id
        else
            return error_response(422, { favorited = { "not found" } })
        end
    end
    
    local articles, err, total_count = db.list_articles(env_config, limit, offset, author_id, tag, favorited_id)
    if err then
        return error_response(500, { database = { err } })
    end
    
    return json_response(200, {
        articles = format_articles_list(env_config, articles, current_user_id),
        articlesCount = total_count
    })
end)

-- Feed (articles from followed users)
router.route("GET", "/api/articles/feed", function(env_config, ngx, params)
    local user, token, err = get_current_user(env_config, ngx)
    if not user then
        return error_response(401, err)
    end
    
    local limit = tonumber(ngx.var.arg_limit) or 20
    local offset = tonumber(ngx.var.arg_offset) or 0
    
    local articles, err, total_count = db.get_feed(env_config, user.id, limit, offset)
    if err then
        return error_response(500, { database = { err } })
    end
    
    return json_response(200, {
        articles = format_articles_list(env_config, articles, user.id),
        articlesCount = total_count
    })
end)

-- Get article by slug
router.route("GET", "/api/articles/:slug", function(env_config, ngx, params)
    local user, token, err = get_current_user(env_config, ngx)
    local current_user_id = user and user.id or nil
    
    local article = web.fetched(db.get_article_by_slug(env_config, params.slug))
    if not article then
        return error_response(404, { article = { "not found" } })
    end
    
    return json_response(200, { article = format_article(env_config, article, current_user_id) })
end)

-- Create article
router.route("POST", "/api/articles", function(env_config, ngx, params)
    local user, token, err = get_current_user(env_config, ngx)
    if not user then
        return error_response(401, err)
    end
    
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if not body then
        return error_response(422, { article = { "Missing request body" } })
    end
    
    local ok, data = pcall(json.decode, body)
    if not ok or not data then
        return error_response(422, { article = { "Invalid JSON" } })
    end
    
    local article_data = data.article or {}
    
    -- Validate required fields
    local errors = {}
    if not article_data.title or article_data.title == "" then
        errors.title = { "can't be blank" }
    end
    if not article_data.description or article_data.description == "" then
        errors.description = { "can't be blank" }
    end
    if not article_data.body or article_data.body == "" then
        errors.body = { "can't be blank" }
    end
    if next(errors) then
        return error_response(422, errors)
    end
    
    -- Generate slug if not provided
    local slug = article_data.slug or generate_slug(article_data.title)
    
    local article, err = db.create_article(env_config, {
        slug = slug,
        title = article_data.title,
        description = article_data.description or "",
        body = article_data.body or "",
        author_id = user.id
    })
    
    if not article then
        return error_response(500, { database = { err or "Failed to create article" } })
    end
    
    -- Set tags if provided
    if article_data.tagList and #article_data.tagList > 0 then
        local ok, err = db.set_article_tags(env_config, article.id, article_data.tagList)
        if not ok then
            -- Rollback: delete the article
            db.delete_article(env_config, article.slug)
            return error_response(500, { tags = { err or "Failed to set tags" } })
        end
    end
    
    -- Reload article with author info
    local article2 = web.fetched(db.get_article_by_slug(env_config, slug))
    
    return json_response(201, { article = format_article(env_config, article2, user.id) })
end)

-- Update article
router.route("PUT", "/api/articles/:slug", function(env_config, ngx, params)
    local user, token, err = get_current_user(env_config, ngx)
    if not user then
        return error_response(401, err)
    end
    
    -- Get current article to check ownership
    local current_article = web.fetched(db.get_article_by_slug(env_config, params.slug))
    if not current_article then
        return error_response(404, { article = { "not found" } })
    end
    
    if current_article.author_id ~= user.id then
        return error_response(403, { article = { "forbidden" } })
    end
    
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if not body then
        return error_response(422, { article = { "Missing request body" } })
    end
    
    local ok, data = pcall(json.decode, body)
    if not ok or not data then
        return error_response(422, { article = { "Invalid JSON" } })
    end
    
    local article_data = data.article or {}
    
    -- Validate tagList if present
    if article_data.tagList == json.null then
        return error_response(422, { tagList = { "must be an array" } })
    end
    
    -- Build updates
    local updates = {}
    if article_data.title then updates.title = article_data.title end
    if article_data.description then updates.description = article_data.description end
    if article_data.body then updates.body = article_data.body end
    
    -- Update article
    local article, err = db.update_article(env_config, params.slug, updates)
    if not article then
        return error_response(500, { database = { err or "Failed to update article" } })
    end
    
    -- Update tags if provided
    if article_data.tagList then
        local ok, err = db.set_article_tags(env_config, article.id, article_data.tagList)
        if not ok then
            return error_response(500, { tags = { err or "Failed to update tags" } })
        end
    end
    
    -- Reload article with author info
    local article2 = web.fetched(db.get_article_by_slug(env_config, params.slug))
    
    return json_response(200, { article = format_article(env_config, article2, user.id) })
end)

-- Delete article
router.route("DELETE", "/api/articles/:slug", function(env_config, ngx, params)
    local user, token, err = get_current_user(env_config, ngx)
    if not user then
        return error_response(401, err)
    end
    
    -- Get current article to check ownership
    local current_article = web.fetched(db.get_article_by_slug(env_config, params.slug))
    if not current_article then
        return error_response(404, { article = { "not found" } })
    end
    
    if current_article.author_id ~= user.id then
        return error_response(403, { article = { "forbidden" } })
    end
    
    local ok, err = db.delete_article(env_config, params.slug)
    if not ok then
        return error_response(500, { database = { err or "Failed to delete article" } })
    end
    
    return json_response(204, nil)
end)

-- Get article comments
router.route("GET", "/api/articles/:slug/comments", function(env_config, ngx, params)
    -- Check if article exists first
    local article = web.fetched(db.get_article_by_slug(env_config, params.slug))
    if not article then
        return error_response(404, { article = { "not found" } })
    end
    
    local user, token, err = get_current_user(env_config, ngx)
    local current_user_id = user and user.id or nil
    
    local comments, err = db.get_comments_by_article(env_config, params.slug)
    if err then
        return error_response(500, { database = { err } })
    end
    
    -- Format comments
    local formatted_comments = {}
    for _, comment in ipairs(comments or {}) do
        table.insert(formatted_comments, {
            id = comment.id,
            body = comment.body,
            createdAt = comment.created_at,
            updatedAt = comment.updated_at,
            author = {
                username = comment.username,
                bio = comment.bio,
                image = comment.image
            }
        })
    end
    
    return json_response(200, { comments = formatted_comments })
end)

-- Create comment
router.route("POST", "/api/articles/:slug/comments", function(env_config, ngx, params)
    local user, token, err = get_current_user(env_config, ngx)
    if not user then
        return error_response(401, err)
    end
    
    -- Get article to verify it exists
    local article = web.fetched(db.get_article_by_slug(env_config, params.slug))
    if not article then
        return error_response(404, { article = { "not found" } })
    end
    
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if not body then
        return error_response(422, { comment = { "Missing request body" } })
    end
    
    local ok, data = pcall(json.decode, body)
    if not ok or not data then
        return error_response(422, { comment = { "Invalid JSON" } })
    end
    
    local comment_data = data.comment or {}
    
    if not comment_data.body or comment_data.body == "" then
        return error_response(422, { body = { "can't be blank" } })
    end
    
    local comment, err = db.create_comment(env_config, {
        body = comment_data.body,
        author_id = user.id,
        article_id = article.id
    })
    
    if not comment then
        return error_response(500, { database = { err or "Failed to create comment" } })
    end
    
    -- Format response
    local formatted = {
        id = comment.id,
        body = comment.body,
        createdAt = comment.created_at,
        updatedAt = comment.updated_at,
        author = {
            username = user.username,
            bio = user.bio,
            image = user.image
        }
    }
    
    return json_response(201, { comment = formatted })
end)

-- Delete comment
router.route("DELETE", "/api/articles/:slug/comments/:id", function(env_config, ngx, params)
    local user, token, err = get_current_user(env_config, ngx)
    if not user then
        return error_response(401, err)
    end
    
    -- Check if article exists first
    local article = web.fetched(db.get_article_by_slug(env_config, params.slug))
    if not article then
        return error_response(404, { article = { "not found" } })
    end
    
    local comment = web.fetched(db.get_comment_by_id(env_config, tonumber(params.id)))
    if not comment then
        return error_response(404, { comment = { "not found" } })
    end
    
    -- Check ownership
    if comment.author_id ~= user.id then
        return error_response(403, { comment = { "forbidden" } })
    end
    
    local ok, err = db.delete_comment(env_config, comment.id)
    if not ok then
        return error_response(500, { database = { err or "Failed to delete comment" } })
    end
    
    return json_response(204, nil)
end)

-- Favorite article
router.route("POST", "/api/articles/:slug/favorite", function(env_config, ngx, params)
    local user, token, err = get_current_user(env_config, ngx)
    if not user then
        return error_response(401, err)
    end
    
    local article = web.fetched(db.get_article_by_slug(env_config, params.slug))
    if not article then
        return error_response(404, { article = { "not found" } })
    end
    
    local ok, err = db.favorite_article(env_config, user.id, article.id)
    if not ok then
        return error_response(500, { database = { err or "Failed to favorite article" } })
    end
    
    -- Reload article to get updated favorites count
    local article2 = web.fetched(db.get_article_by_slug(env_config, params.slug))
    
    return json_response(200, { article = format_article(env_config, article2, user.id) })
end)

-- Unfavorite article
router.route("DELETE", "/api/articles/:slug/favorite", function(env_config, ngx, params)
    local user, token, err = get_current_user(env_config, ngx)
    if not user then
        return error_response(401, err)
    end
    
    local article = web.fetched(db.get_article_by_slug(env_config, params.slug))
    if not article then
        return error_response(404, { article = { "not found" } })
    end
    
    local ok, err = db.unfavorite_article(env_config, user.id, article.id)
    if not ok then
        return error_response(500, { database = { err or "Failed to unfavorite article" } })
    end
    
    -- Reload article to get updated favorites count
    local article2 = web.fetched(db.get_article_by_slug(env_config, params.slug))
    
    return json_response(200, { article = format_article(env_config, article2, user.id) })
end)

-- Get tags
router.route("GET", "/api/tags", function(env_config, ngx, params)
    local tags, err = db.get_all_tags(env_config)
    if err then
        return error_response(500, { database = { err } })
    end
    
    return json_response(200, { tags = tags })
end)

return router
