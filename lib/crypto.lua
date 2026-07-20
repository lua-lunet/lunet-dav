-- Cryptography utilities using libsodium via FFI
-- Replaces argon2 (luarocks), resty.random, resty.string, and resty.jwt's
-- HMAC signing, none of which are needed once this module is loaded

local ffi = require("ffi")
local crypto = {}

ffi.cdef[[
    int sodium_init(void);

    // Password hashing (Argon2id)
    int crypto_pwhash_str(
        char out[128],
        const char * const passwd,
        unsigned long long passwdlen,
        unsigned long long opslimit,
        size_t memlimit
    );

    int crypto_pwhash_str_verify(
        const char str[128],
        const char * const passwd,
        unsigned long long passwdlen
    );

    // HMAC-SHA256
    int crypto_auth_hmacsha256(
        unsigned char *out,
        const unsigned char *in,
        unsigned long long inlen,
        const unsigned char *k
    );

    // Random bytes
    void randombytes_buf(void * const buf, const size_t size);

    // Constant time comparison
    int sodium_memcmp(const void * const b1_, const void * const b2_, size_t len);
]]

local sodium = ffi.load("sodium")
local initialized = false

local function init()
    if not initialized then
        if sodium.sodium_init() < 0 then
            error("libsodium initialization failed")
        end
        initialized = true
    end
end

local OPSLIMIT_INTERACTIVE = 2ULL
local MEMLIMIT_INTERACTIVE = 67108864ULL
local PWHASH_STRBYTES = 128
local HMAC_BYTES = 32
local HMAC_KEYBYTES = 32

-- Hash a password with Argon2id. The salt is embedded in the returned string.
function crypto.hash_password(password)
    init()
    local out = ffi.new("char[?]", PWHASH_STRBYTES)
    local result = sodium.crypto_pwhash_str(
        out,
        password,
        #password,
        OPSLIMIT_INTERACTIVE,
        MEMLIMIT_INTERACTIVE
    )
    if result ~= 0 then
        return nil, "password hashing failed"
    end
    return ffi.string(out)
end

function crypto.verify_password(password, hash)
    init()
    local result = sodium.crypto_pwhash_str_verify(hash, password, #password)
    return result == 0
end

function crypto.hmac_sha256(message, key)
    init()
    if #key < HMAC_KEYBYTES then
        local padded = ffi.new("unsigned char[?]", HMAC_KEYBYTES)
        ffi.copy(padded, key, #key)
        key = ffi.string(padded, HMAC_KEYBYTES)
    elseif #key > HMAC_KEYBYTES then
        key = key:sub(1, HMAC_KEYBYTES)
    end
    local out = ffi.new("unsigned char[?]", HMAC_BYTES)
    sodium.crypto_auth_hmacsha256(out, message, #message, key)
    return ffi.string(out, HMAC_BYTES)
end

function crypto.random_bytes(size)
    init()
    local buf = ffi.new("unsigned char[?]", size)
    sodium.randombytes_buf(buf, size)
    return ffi.string(buf, size)
end

function crypto.constant_time_compare(a, b)
    init()
    if #a ~= #b then return false end
    return sodium.sodium_memcmp(a, b, #a) == 0
end

local b64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local b64url_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

function crypto.base64_encode(data, url_safe)
    local chars = url_safe and b64url_chars or b64_chars
    local result = {}
    local pad = #data % 3
    data = data .. string.rep("\0", (3 - pad) % 3)

    for i = 1, #data, 3 do
        local b1, b2, b3 = data:byte(i, i + 2)
        local n = b1 * 65536 + b2 * 256 + b3
        result[#result + 1] = chars:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1)
        result[#result + 1] = chars:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
        result[#result + 1] = chars:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1)
        result[#result + 1] = chars:sub(n % 64 + 1, n % 64 + 1)
    end

    local encoded = table.concat(result)
    if pad == 1 then
        encoded = encoded:sub(1, -3) .. (url_safe and "" or "==")
    elseif pad == 2 then
        encoded = encoded:sub(1, -2) .. (url_safe and "" or "=")
    end
    return encoded
end

function crypto.base64_decode(data, url_safe)
    local chars = url_safe and b64url_chars or b64_chars
    local decode_map = {}
    for i = 1, 64 do
        decode_map[chars:sub(i, i)] = i - 1
    end
    decode_map["="] = 0

    data = data:gsub("=", "")
    local pad = #data % 4
    if pad == 1 then
        return nil, "invalid base64 length"
    end
    data = data .. string.rep("A", (4 - pad) % 4)

    local result = {}
    for i = 1, #data, 4 do
        local c1 = decode_map[data:sub(i, i)] or 0
        local c2 = decode_map[data:sub(i + 1, i + 1)] or 0
        local c3 = decode_map[data:sub(i + 2, i + 2)] or 0
        local c4 = decode_map[data:sub(i + 3, i + 3)] or 0
        local n = c1 * 262144 + c2 * 4096 + c3 * 64 + c4
        result[#result + 1] = string.char(math.floor(n / 65536) % 256)
        result[#result + 1] = string.char(math.floor(n / 256) % 256)
        result[#result + 1] = string.char(n % 256)
    end

    local decoded = table.concat(result)
    if pad == 2 then
        decoded = decoded:sub(1, -3)
    elseif pad == 3 then
        decoded = decoded:sub(1, -2)
    end
    return decoded
end

return crypto
