--[[
  lunet.lnt_shared — shared dictionary for LuaJIT

  This module exposes an lnt-style shared dictionary API.

  The backing store is a Rust library (liblnt_shared) that manages an
  anonymous mmap(2) region.  All state lives inside the mmap — no heap
  allocation for persistent dictionary data.

  Usage
  -----
      local lnt = require("lunet.lnt_shared")

      -- Open (or reuse) a named dictionary of 1 MiB.
      local cache = lnt.store("cache", 1024 * 1024)

      cache:set("greeting", "hello")
      print(cache:get("greeting"))          --> "hello"

      cache:set("counter", 0)               -- stores as number
      cache:incr("counter", 1)              -- atomic increment
      print(cache:get("counter"))           --> 1

      -- TTL in seconds (fractional OK)
      cache:set("tmp", "bye", 0.5)          -- expires in 500 ms
      cache:flush_expired()

  Value types
  -----------
  Lua strings  → stored as raw bytes   (val_type 0)
  Lua numbers  → stored as f64 LE      (val_type 1)
  Lua booleans → stored as single byte (val_type 2)

  Any other type raises an error.

  Error handling
  --------------
  Methods follow the Lua convention: return value on success, or
  nil + error-string on failure.

  Platform
  --------
  Linux and macOS only.  The underlying Rust crate requires
  mmap(MAP_ANONYMOUS|MAP_SHARED) and clock_gettime(CLOCK_MONOTONIC).
]]

local ffi = require("ffi")

-- ── FFI declarations ─────────────────────────────────────────────────────────

ffi.cdef[[
  /* Opaque dictionary handle */
  typedef void* ngx_shared_handle_t;

  /* Lifecycle */
  ngx_shared_handle_t ngx_shared_open(const char* name, uint64_t size_bytes);
  void                ngx_shared_close(ngx_shared_handle_t h);

  /* CRUD */
  int  ngx_shared_get(ngx_shared_handle_t h,
                      const uint8_t* key, size_t klen,
                      uint8_t** out_val, size_t* out_len, int* out_type);
  void ngx_shared_free_bytes(uint8_t* p, size_t len);

  int  ngx_shared_set(ngx_shared_handle_t h,
                      const uint8_t* key, size_t klen,
                      const uint8_t* val, size_t vlen,
                      int val_type, double ttl_secs);
  int  ngx_shared_add(ngx_shared_handle_t h,
                      const uint8_t* key, size_t klen,
                      const uint8_t* val, size_t vlen,
                      int val_type, double ttl_secs);
  int  ngx_shared_replace(ngx_shared_handle_t h,
                          const uint8_t* key, size_t klen,
                          const uint8_t* val, size_t vlen,
                          int val_type, double ttl_secs);
  int  ngx_shared_delete(ngx_shared_handle_t h,
                         const uint8_t* key, size_t klen);

  /* Numeric increment */
  int  ngx_shared_incr(ngx_shared_handle_t h,
                       const uint8_t* key, size_t klen,
                       double delta, double init, int has_init,
                       double ttl_secs, double* result);

  /* TTL management */
  int  ngx_shared_expire(ngx_shared_handle_t h,
                         const uint8_t* key, size_t klen,
                         double ttl_secs);
  int  ngx_shared_ttl(ngx_shared_handle_t h,
                      const uint8_t* key, size_t klen,
                      double* out_ttl);

  /* Bulk operations */
  void ngx_shared_flush_all(ngx_shared_handle_t h);
  int  ngx_shared_flush_expired(ngx_shared_handle_t h, int max);

  /* Stats */
  uint64_t ngx_shared_capacity(ngx_shared_handle_t h);
  uint64_t ngx_shared_free_space(ngx_shared_handle_t h);
]]

-- ── Library loader ────────────────────────────────────────────────────────────

local function find_lib()
  -- 1. Explicit environment override.
  local env = os.getenv("LUNET_LNT_SHARED_LIB")
  if not env or env == "" then
    -- Deprecated compatibility alias for older setups.
    env = os.getenv("LUNET_NGX_SHARED_LIB")
  end
  if env and env ~= "" then
    return env
  end

  -- 2. Determine the platform suffix using uname(1).
  --    io.popen may return nil in restricted environments; fall back to "so".
  local suffix = "so"  -- Linux default
  local ok_popen, uname = pcall(io.popen, "uname -s 2>/dev/null")
  if ok_popen and uname then
    local sys = uname:read("*l") or ""
    uname:close()
    if sys == "Darwin" then
      suffix = "dylib"
    end
  end

  -- 3. Search relative to this file's directory.
  local script = debug.getinfo(2, "S").source
  local dir = script:match("^@(.+)/[^/]+$") or "."
  local candidates = {
    dir .. "/target/release/liblnt_shared." .. suffix,
    dir .. "/liblnt_shared." .. suffix,
    -- Deprecated compatibility paths for previously built artifacts.
    dir .. "/target/release/libngx_shared." .. suffix,
    dir .. "/libngx_shared." .. suffix,
  }

  for _, p in ipairs(candidates) do
    local f = io.open(p, "rb")
    if f then
      f:close()
      return p
    end
  end

  error(
    "lunet.lnt_shared: cannot find liblnt_shared." .. suffix .. "\n" ..
    "  Build it with:  cd ext/lnt_shared && cargo build --release\n" ..
    "  or set LUNET_LNT_SHARED_LIB=/path/to/liblnt_shared." .. suffix,
    3
  )
end

local _lib
local function lib()
  if not _lib then
    _lib = ffi.load(find_lib())
  end
  return _lib
end

-- ── Error code constants (mirror dict.rs) ─────────────────────────────────────

local ERR_CODES = {
  [0]  = nil,            -- NGX_SHARED_OK
  [-1] = "not found",    -- NGX_SHARED_NOT_FOUND
  [-2] = "already exists", -- NGX_SHARED_ERR_EXISTS
  [-3] = "out of memory",  -- NGX_SHARED_ERR_NOMEM
  [-4] = "type mismatch",  -- NGX_SHARED_ERR_TYPE
  [-5] = "hash table full", -- NGX_SHARED_ERR_FULL
  [-6] = "invalid argument", -- NGX_SHARED_ERR_INVAL
}

local function rc_to_err(rc)
  return ERR_CODES[rc] or ("error " .. tostring(rc))
end

-- ── Value encoding / decoding ─────────────────────────────────────────────────

-- val_type constants (must match region.rs VTYPE_*)
local VTYPE_BYTES = 0
local VTYPE_F64   = 1
local VTYPE_BOOL  = 2

-- Reusable FFI scratch buffers
local _out_val_pp = ffi.new("uint8_t*[1]")
local _out_len_p  = ffi.new("size_t[1]")
local _out_type_p = ffi.new("int[1]")
local _out_ttl_p  = ffi.new("double[1]")
local _result_p   = ffi.new("double[1]")
local _f64_buf    = ffi.new("uint8_t[8]")

local function encode_value(v)
  local t = type(v)
  if t == "string" then
    return v, #v, VTYPE_BYTES
  elseif t == "number" then
    -- Store as little-endian f64
    local n = ffi.cast("double*", _f64_buf)
    n[0] = v
    return ffi.string(_f64_buf, 8), 8, VTYPE_F64
  elseif t == "boolean" then
    return (v and "\1" or "\0"), 1, VTYPE_BOOL
  else
    error("lunet.lnt_shared: unsupported value type: " .. t, 3)
  end
end

local function decode_value(ptr, len, vtype)
  if vtype == VTYPE_BYTES then
    return ffi.string(ptr, len)
  elseif vtype == VTYPE_F64 then
    if len < 8 then return nil end
    local n = ffi.cast("double*", ptr)
    return tonumber(n[0])
  elseif vtype == VTYPE_BOOL then
    if len < 1 then return false end
    return ptr[0] ~= 0
  else
    -- Unknown type: return raw bytes
    return ffi.string(ptr, len)
  end
end

-- ── Dict methods ──────────────────────────────────────────────────────────────

local Dict = {}
Dict.__index = Dict

--- Get the value for `key`.
--- Returns `value` on success, or `nil, err` if not found.
function Dict:get(key)
  assert(type(key) == "string", "key must be a string")
  local l = lib()
  local rc = l.ngx_shared_get(
    self._h,
    key, #key,
    _out_val_pp, _out_len_p, _out_type_p
  )
  if rc ~= 0 then
    return nil, rc_to_err(rc)
  end
  local ptr = _out_val_pp[0]
  local len = tonumber(_out_len_p[0])
  local vtype = tonumber(_out_type_p[0])
  local val = decode_value(ptr, len, vtype)
  l.ngx_shared_free_bytes(ptr, len)
  return val
end

--- Set `key` to `value` (overwrites any existing entry).
--- `ttl` is optional seconds until expiry; omit or pass `0` for no expiry.
--- Returns `true` on success, or `nil, err` on failure.
function Dict:set(key, value, ttl)
  assert(type(key) == "string", "key must be a string")
  local bytes, blen, vtype = encode_value(value)
  local rc = lib().ngx_shared_set(
    self._h,
    key, #key,
    bytes, blen,
    vtype, ttl or 0
  )
  if rc ~= 0 then
    return nil, rc_to_err(rc)
  end
  return true
end

--- Add `key` only if it does not already exist.
--- Returns `true` on success, `nil, "already exists"` if the key exists,
--- or `nil, err` on other failure.
function Dict:add(key, value, ttl)
  assert(type(key) == "string", "key must be a string")
  local bytes, blen, vtype = encode_value(value)
  local rc = lib().ngx_shared_add(
    self._h,
    key, #key,
    bytes, blen,
    vtype, ttl or 0
  )
  if rc ~= 0 then
    return nil, rc_to_err(rc)
  end
  return true
end

--- Replace `key` only if it already exists.
--- Returns `true` on success, `nil, "not found"` if the key is absent,
--- or `nil, err` on other failure.
function Dict:replace(key, value, ttl)
  assert(type(key) == "string", "key must be a string")
  local bytes, blen, vtype = encode_value(value)
  local rc = lib().ngx_shared_replace(
    self._h,
    key, #key,
    bytes, blen,
    vtype, ttl or 0
  )
  if rc ~= 0 then
    return nil, rc_to_err(rc)
  end
  return true
end

--- Delete `key`.  Returns `true` on success, `nil, "not found"` if absent.
function Dict:delete(key)
  assert(type(key) == "string", "key must be a string")
  local rc = lib().ngx_shared_delete(self._h, key, #key)
  if rc ~= 0 then
    return nil, rc_to_err(rc)
  end
  return true
end

--- Atomically increment numeric key `key` by `delta` (default 1).
--- If the key does not exist and `init` is provided, initialise it to `init`
--- before incrementing.
--- `ttl` applies only to newly created keys; pass `nil` to leave existing
--- key TTL unchanged.
--- Returns the new value on success, or `nil, err` on failure.
function Dict:incr(key, delta, init, ttl)
  assert(type(key) == "string", "key must be a string")
  delta = delta or 1
  local has_init = (init ~= nil) and 1 or 0
  local rc = lib().ngx_shared_incr(
    self._h,
    key, #key,
    delta,
    init or 0,
    has_init,
    ttl or 0,
    _result_p
  )
  if rc ~= 0 then
    return nil, rc_to_err(rc)
  end
  return tonumber(_result_p[0])
end

--- Update the TTL of `key` to `ttl_secs` seconds.
--- Pass `0` or a negative value to remove the expiry.
--- Returns `true` on success, `nil, err` on failure.
function Dict:expire(key, ttl_secs)
  assert(type(key) == "string", "key must be a string")
  local rc = lib().ngx_shared_expire(self._h, key, #key, ttl_secs or 0)
  if rc ~= 0 then
    return nil, rc_to_err(rc)
  end
  return true
end

--- Get the remaining TTL in seconds for `key`.
--- Returns `ttl_seconds` (a number >= 0) on success.
--- Returns `-1` if the key exists but has no expiry.
--- Returns `nil, "not found"` if the key does not exist.
function Dict:ttl(key)
  assert(type(key) == "string", "key must be a string")
  local rc = lib().ngx_shared_ttl(self._h, key, #key, _out_ttl_p)
  if rc == 0 or rc == 1 then
    return tonumber(_out_ttl_p[0])
  end
  return nil, rc_to_err(rc)
end

--- Remove all entries from the dictionary and reset the allocator.
function Dict:flush_all()
  lib().ngx_shared_flush_all(self._h)
end

--- Scan the dictionary and evict expired entries.
--- `max` limits the number of entries evicted (0 or nil = unlimited).
--- Returns the number of entries evicted.
function Dict:flush_expired(max)
  return tonumber(lib().ngx_shared_flush_expired(self._h, max or 0))
end

--- Returns the total capacity of the region in bytes.
function Dict:capacity()
  return tonumber(lib().ngx_shared_capacity(self._h))
end

--- Returns the approximate number of free bytes in the data area.
--- Note: tombstoned entries do not reclaim space until flush_all.
function Dict:free_space()
  return tonumber(lib().ngx_shared_free_space(self._h))
end

--- Explicitly close the dictionary handle.
--- Safe to call multiple times; also runs automatically at GC time via
--- ffi.gc (LuaJIT ignores __gc on plain tables, so the finalizer is
--- attached to the cdata handle itself).
function Dict:close()
  if self._h ~= nil then
    ffi.gc(self._h, nil)               -- disarm the finalizer
    lib().ngx_shared_close(self._h)
    self._h = nil
  end
  return true
end

function Dict:__tostring()
  return string.format("lnt_shared.Dict(%s)", self._name)
end

-- ── Public module ─────────────────────────────────────────────────────────────

local M = {}

--- Open (or reuse) a named dictionary.
---
--- Parameters:
---   name        string  Logical name for the dictionary.
---   size_bytes  number  Minimum size in bytes (default 1 MiB, minimum 64 KiB).
---
--- Returns a Dict object.  Multiple calls with the same name return handles
--- to the same underlying region.
function M.open(name, size_bytes)
  assert(type(name) == "string" and #name > 0, "name must be a non-empty string")
  size_bytes = math.max(size_bytes or 1024 * 1024, 65536)
  local l = lib()
  local h = l.ngx_shared_open(name, size_bytes)
  if h == nil then
    error("lunet.lnt_shared: failed to open dictionary '" .. name .. "'", 2)
  end

  -- Attach the finalizer to the cdata handle (LuaJIT does not honour __gc
  -- on plain tables).  The underlying region outlives the handle: it is
  -- freed only when the last handle to it is closed.
  h = ffi.gc(h, l.ngx_shared_close)
  local d = setmetatable({ _h = h, _name = name }, Dict)
  return d
end

M.store = M.open

return M
