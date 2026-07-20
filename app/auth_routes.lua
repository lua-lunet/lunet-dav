-- Authentication routes for RealWorld API
-- Uses JWT for authentication and lunet.postgres for PostgreSQL

local router = require("router")
local jwt = require("jwt")

local json = require("cjson")
local db = require("db")
local web = require("web")

local JWT_EXPIRY = 3600  -- 1 hour in seconds

-- LuaJIT is Lua 5.1: unpack is global there, table.unpack on 5.2-compat builds
local unpack = table.unpack or unpack
local JSON_NULL = json.null  -- Use cjson's null value for JSON encoding

local json_response = web.json_response
local error_response = web.error_response

-- Map a unique-constraint violation to the RealWorld 409 response, or nil.
-- Relying on the constraint (not a pre-check) keeps writes race-free.
local function taken_response(err)
    if err and err:find("users_email_key", 1, true) then
        return error_response(409, { email = { "has already been taken" } })
    end
    if err and err:find("users_username_key", 1, true) then
        return error_response(409, { username = { "has already been taken" } })
    end
    return nil
end

-- Validate login request
local function validate_login_request(ngx)
    -- Read request body
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    
    if not body then
        return nil, nil, "Missing request body"
    end
    
    local ok, data = pcall(json.decode, body)
    if not ok or not data then
        return nil, nil, "Invalid JSON"
    end
    
    if not data.user then
        return nil, nil, "User data required"
    end
    
    return data.user, nil, nil
end

-- Register a new user
router.route("POST", "/api/users", function(env_config, ngx, params)
    local user_data, _, err = validate_login_request(ngx)
    if not user_data then
        return error_response(422, { body = { err or "Invalid request" } })
    end
    
    -- Validate required fields
    local errors = {}
    if not user_data.username or user_data.username == "" then
        errors.username = { "can't be blank" }
    end
    if not user_data.email or user_data.email == "" then
        errors.email = { "can't be blank" }
    end
    if not user_data.password or user_data.password == "" then
        errors.password = { "can't be blank" }
    end
    if next(errors) then
        return error_response(422, errors)
    end
    
    -- Generate salt and hash password
    local password = require("password")
    local salt = password.generate_salt()
    local password_hash, hash_err = password.hash(user_data.password, salt)
    if not password_hash then
        return error_response(500, { body = { "Failed to hash password: " .. (hash_err or "unknown") } })
    end
    
    -- Create user
    local user = {
        email = user_data.email,
        username = user_data.username or user_data.email:match("^([^@]+)") or "user",
        password_hash = password_hash,
        salt = salt,
        bio = user_data.bio,
        image = user_data.image
    }
    
    local created, err = db.create_user(env_config, user)
    if not created then
        return taken_response(err) or error_response(500, { body = { "Database error: " .. err } })
    end
    
    -- Create JWT token
    local token_payload = {
        id = created.id,
        email = created.email,
        username = created.username,
        exp = os.time() + JWT_EXPIRY
    }
    
    local token, err = jwt.encode(token_payload, env_config.JWT_SECRET, "HS256")
    if not token then
        return error_response(500, { body = { "Failed to create token: " .. err } })
    end
    
    -- Return user with token
    -- Use ngx.null for null values (nil would be omitted by JSON encoder)
    return json_response(201, {
        user = {
            id = created.id,
            email = created.email,
            username = created.username,
            token = token,
            bio = created.bio or JSON_NULL,
            image = created.image or JSON_NULL
        }
    })
end)

-- Login user and return JWT token
router.route("POST", "/api/users/login", function(env_config, ngx, params)
    local user, _, err = validate_login_request(ngx)
    if not user then
        return error_response(422, { body = { err or "Invalid request" } })
    end
    
    -- Validate required fields
    local errors = {}
    if not user.email or user.email == "" then
        errors.email = { "can't be blank" }
    end
    if not user.password or user.password == "" then
        errors.password = { "can't be blank" }
    end
    if next(errors) then
        return error_response(422, errors)
    end
    
    -- Find user by email
    local found_user, err = db.get_user_by_email(env_config, user.email)
    if err then
        return error_response(500, { body = { "Database error: " .. err } })
    end
    
    if not found_user then
        return error_response(401, { credentials = { "invalid" } })
    end
    
    -- Verify password
    local password = require("password")
    if not password.verify(user.password, found_user.password_hash, found_user.salt) then
        return error_response(401, { credentials = { "invalid" } })
    end
    
    -- Create JWT token
    local token_payload = {
        id = found_user.id,
        email = found_user.email,
        username = found_user.username,
        exp = os.time() + JWT_EXPIRY
    }
    
    local token, err = jwt.encode(token_payload, env_config.JWT_SECRET, "HS256")
    if not token then
        return error_response(500, { body = { "Failed to create token: " .. err } })
    end
    
    -- Get user profile (without password hash)
    local profile, err = db.get_user_by_id(env_config, found_user.id)
    if err then
        return error_response(500, { body = { "Database error: " .. err } })
    end
    if not profile then
        return error_response(500, { body = { "Failed to retrieve user profile" } })
    end
    
    -- Return user with token
    -- Use ngx.null for null values (nil would be omitted by JSON encoder)
    return json_response(200, {
        user = {
            id = profile.id,
            email = profile.email,
            username = profile.username,
            token = token,
            bio = profile.bio or JSON_NULL,
            image = profile.image or JSON_NULL
        }
    })
end)

-- Get current user (requires authentication)
router.route("GET", "/api/user", function(env_config, ngx, params)
    local user, token, auth_err = web.get_current_user(env_config, ngx)
    if not user then
        return error_response(401, auth_err)
    end

    -- Normalize nil to null for JSON encoding (nil would be omitted)
    user.bio = user.bio or JSON_NULL
    user.image = user.image or JSON_NULL
    user.token = token

    return json_response(200, { user = user })
end)

-- Update user (requires authentication)
router.route("PUT", "/api/user", function(env_config, ngx, params)
    local current_user, token, auth_err = web.get_current_user(env_config, ngx)
    if not current_user then
        return error_response(401, auth_err)
    end
    local user_id = current_user.id

    -- Read request body
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    
    if not body then
        return error_response(422, { body = { "Missing request body" } })
    end
    
    local ok, data = pcall(json.decode, body)
    if not ok or not data then
        return error_response(422, { body = { "Invalid JSON" } })
    end
    
    local user_data = data.user or {}
    
    -- Validate fields
    local errors = {}
    if user_data.email ~= nil then
        if user_data.email == JSON_NULL or user_data.email == "" then
            errors.email = { "can't be blank" }
        end
    end
    if user_data.username ~= nil then
        if user_data.username == JSON_NULL or user_data.username == "" then
            errors.username = { "can't be blank" }
        end
    end
    if user_data.password ~= nil then
        if user_data.password == JSON_NULL or user_data.password == "" then
            errors.password = { "can't be blank" }
        elseif type(user_data.password) == "string" and #user_data.password < 8 then
            errors.password = { "must be at least 8 characters" }
        end
    end
    if next(errors) then
        return error_response(422, errors)
    end
    
    -- Update user in database
    local update_fields = {}
    local update_values = {}
    local param_index = 1
    
    if user_data.email and user_data.email ~= "" and user_data.email ~= json.null then
        table.insert(update_fields, "email = $" .. param_index)
        table.insert(update_values, user_data.email)
        param_index = param_index + 1
    end
    
    if user_data.username and user_data.username ~= "" and user_data.username ~= json.null then
        table.insert(update_fields, "username = $" .. param_index)
        table.insert(update_values, user_data.username)
        param_index = param_index + 1
    end
    
    -- Handle bio: empty string or null -> NULL
    if user_data.bio ~= nil then
        if user_data.bio == "" or user_data.bio == json.null then
            table.insert(update_fields, "bio = NULL")
        else
            table.insert(update_fields, "bio = $" .. param_index)
            table.insert(update_values, user_data.bio)
            param_index = param_index + 1
        end
    end
    
    -- Handle image: empty string or null -> NULL
    if user_data.image ~= nil then
        if user_data.image == "" or user_data.image == json.null then
            table.insert(update_fields, "image = NULL")
        else
            table.insert(update_fields, "image = $" .. param_index)
            table.insert(update_values, user_data.image)
            param_index = param_index + 1
        end
    end
    
    if user_data.password and user_data.password ~= "" then
        local password = require("password")
        local salt = password.generate_salt()
        local password_hash, err = password.hash(user_data.password, salt)
        if password_hash then
            table.insert(update_fields, "password_hash = $" .. param_index)
            table.insert(update_values, password_hash)
            param_index = param_index + 1
            
            table.insert(update_fields, "salt = $" .. param_index)
            table.insert(update_values, salt)
            param_index = param_index + 1
        end
    end
    
    if #update_fields == 0 then
        -- No fields to update; return the current user
        current_user.bio = current_user.bio or JSON_NULL
        current_user.image = current_user.image or JSON_NULL
        current_user.token = token
        return json_response(200, { user = current_user })
    end
    
    -- Add id for WHERE clause
    table.insert(update_values, user_id)
    
    local sql = "UPDATE users SET " .. table.concat(update_fields, ", ") .. " WHERE id = $" .. param_index .. " RETURNING id, email, username, bio, image"
    
    local user, err = db.query_row(env_config, sql, unpack(update_values))
    if not user then
        return taken_response(err) or error_response(500, { body = { "Database error: " .. err } })
    end

    -- Normalize nil to null for JSON encoding (nil would be omitted)
    user.bio = user.bio or JSON_NULL
    user.image = user.image or JSON_NULL
    user.token = token

    return json_response(200, { user = user })
end)

-- Return router for use in main routing
return router
