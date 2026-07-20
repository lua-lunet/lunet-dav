-- Password hashing module using Argon2id (via lib/crypto, libsodium FFI)
-- Provides secure password hashing without any OpenResty/luarocks dependency

local crypto = require("lib.crypto")

local password = {}

-- Generate a random salt via libsodium's CSPRNG
-- @return salt: string hex-encoded salt (32 hex chars = 16 bytes), or nil
function password.generate_salt()
    local salt_bytes = crypto.random_bytes(16)
    if not salt_bytes then
        return nil
    end
    return (salt_bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

-- Hash a password using Argon2id
-- @param plain_password: string password to hash
-- @param salt: string salt (optional, if not provided will generate one)
-- @return hash: string hashed password (Argon2 encoded string, salt embedded)
-- @return salt: string salt used (kept only for the `salt` column; not needed to verify)
-- @return err: string error message or nil
function password.hash(plain_password, salt)
    if not plain_password or #plain_password == 0 then
        return nil, nil, "Password cannot be empty"
    end

    if not salt then
        salt = password.generate_salt()
    end

    local hash, err = crypto.hash_password(plain_password)
    if not hash then
        return nil, salt, err or "Failed to hash password"
    end

    return hash, salt, nil
end

-- Verify a password against a hash
-- @param plain_password: string password to verify
-- @param stored_hash: string Argon2 encoded hash
-- @param salt: string salt (unused; Argon2id's encoded hash embeds its own salt)
-- @return valid: boolean true if password matches
function password.verify(plain_password, stored_hash, salt)
    if not plain_password or not stored_hash then
        return false
    end

    return crypto.verify_password(plain_password, stored_hash)
end

return password
