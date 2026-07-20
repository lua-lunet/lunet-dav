-- JWT module (HS256) built on lib/crypto (libsodium FFI)
-- Provides the same API as the old resty.jwt-backed implementation,
-- including resty.jwt's automatic expiry ("exp") validation on decode

local crypto = require("lib.crypto")
local cjson = require("cjson")

local jwt = {}

-- Encode a JWT token
-- @param payload: table with claims
-- @param secret: string secret key
-- @param algorithm: string algorithm name (e.g., "HS256")
-- @return token: string JWT token, or nil
-- @return err: string error message, or nil
function jwt.encode(payload, secret, algorithm)
    if not payload then
        return nil, "Payload cannot be nil"
    end

    if not secret or #secret == 0 then
        return nil, "Secret cannot be empty"
    end

    algorithm = algorithm or "HS256"

    if algorithm ~= "HS256" then
        return nil, "Unsupported algorithm: " .. algorithm
    end

    local header = { typ = "JWT", alg = algorithm }
    local header_b64 = crypto.base64_encode(cjson.encode(header), true)
    local payload_b64 = crypto.base64_encode(cjson.encode(payload), true)
    local message = header_b64 .. "." .. payload_b64
    local signature_b64 = crypto.base64_encode(crypto.hmac_sha256(message, secret), true)

    return message .. "." .. signature_b64, nil
end

-- Verify a JWT token and return its payload
-- @param token: string JWT token
-- @param secret: string secret key used to verify the signature
-- @return payload: table with claims, or nil
-- @return err: string error message, or nil
function jwt.decode(token, secret)
    if not token or #token == 0 then
        return nil, "Token cannot be empty"
    end

    if not secret or #secret == 0 then
        return nil, "Secret cannot be empty"
    end

    local header_b64, payload_b64, signature_b64 = token:match("^([^.]+)%.([^.]+)%.([^.]+)$")
    if not header_b64 then
        return nil, "Invalid token format"
    end

    local message = header_b64 .. "." .. payload_b64
    local expected_signature_b64 = crypto.base64_encode(crypto.hmac_sha256(message, secret), true)
    if not crypto.constant_time_compare(signature_b64, expected_signature_b64) then
        return nil, "Invalid signature"
    end

    local header_json = crypto.base64_decode(header_b64, true)
    local header_ok, header = pcall(cjson.decode, header_json)
    if not header_ok or header.alg ~= "HS256" then
        return nil, "Invalid header"
    end

    local payload_json = crypto.base64_decode(payload_b64, true)
    local payload_ok, payload = pcall(cjson.decode, payload_json)
    if not payload_ok then
        return nil, "Invalid payload"
    end

    -- Mirrors resty.jwt:verify()'s automatic expiry validation
    if payload.exp and payload.exp < os.time() then
        return nil, "Token expired"
    end

    return payload, nil
end

return jwt
