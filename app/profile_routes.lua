-- Profile routes for chassis compatibility
-- Handles profile retrieval, follow/unfollow

local router = require("router")
local json = require("cjson")
local db = require("db")
local web = require("web")

local json_response = web.json_response
local error_response = web.error_response
local get_current_user = web.get_current_user

-- Helper to format profile response
local function format_profile(env_config, profile, current_user_id)
    local formatted = {
        username = profile.username,
        bio = profile.bio or json.null,
        image = profile.image or json.null,
        following = false
    }
    
    -- Check if current user is following this profile
    if current_user_id and current_user_id ~= profile.id then
        local is_following, _ = db.is_following(env_config, current_user_id, profile.id)
        formatted.following = is_following
    end
    
    return formatted
end

-- Get profile
router.route("GET", "/api/profiles/:username", function(env_config, ngx, params)
    local user, token, err = get_current_user(env_config, ngx)
    local current_user_id = user and user.id or nil
    
    local profile = web.fetched(db.get_profile_by_username(env_config, params.username))
    if not profile then
        return error_response(404, { profile = { "not found" } })
    end
    
    return json_response(200, { profile = format_profile(env_config, profile, current_user_id) })
end)

-- Follow user
router.route("POST", "/api/profiles/:username/follow", function(env_config, ngx, params)
    local user, token, err = get_current_user(env_config, ngx)
    if not user then
        return error_response(401, err)
    end
    
    local profile = web.fetched(db.get_profile_by_username(env_config, params.username))
    if not profile then
        return error_response(404, { profile = { "not found" } })
    end
    
    -- Can't follow yourself
    if profile.id == user.id then
        return error_response(422, { follow = { "Cannot follow yourself" } })
    end
    
    -- Check if already following
    local is_following, _ = db.is_following(env_config, user.id, profile.id)
    if is_following then
        return json_response(200, { profile = format_profile(env_config, profile, user.id) })
    end
    
    local ok, err = db.follow_user(env_config, user.id, profile.id)
    if not ok then
        return error_response(500, { database = { err or "Failed to follow user" } })
    end
    
    return json_response(200, { profile = format_profile(env_config, profile, user.id) })
end)

-- Unfollow user
router.route("DELETE", "/api/profiles/:username/follow", function(env_config, ngx, params)
    local user, token, err = get_current_user(env_config, ngx)
    if not user then
        return error_response(401, err)
    end
    
    local profile = web.fetched(db.get_profile_by_username(env_config, params.username))
    if not profile then
        return error_response(404, { profile = { "not found" } })
    end
    
    local ok, err = db.unfollow_user(env_config, user.id, profile.id)
    if not ok then
        return error_response(500, { database = { err or "Failed to unfollow user" } })
    end
    
    return json_response(200, { profile = format_profile(env_config, profile, user.id) })
end)

return router
