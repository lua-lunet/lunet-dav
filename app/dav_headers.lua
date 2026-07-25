-- PUT response header policy (docs/DESIGN.md §8).
-- Fixed nc core headers are built by the caller; this module applies the two
-- config-gated layers on top:
--   * mapped:       X-Hash-SHA256 per DAV_EMIT_HASH_HEADER mode
--   * pass-through: upstream headers named in DAV_PUT_PASSTHROUGH_HEADERS,
--                   copied verbatim from the harvested upstream exchange

-- Map of upstream HTTP header name -> field in the harvested locator table
-- (lib/s3.lua put_object/head_object return values). Names not in this map
-- are never emitted: we only pass through what we actually harvest.
local UPSTREAM_FIELD = {
    ["x-amz-version-id"] = "version_id",
    ["x-amz-checksum-sha256"] = "checksum_sha256",
    ["etag"] = "etag",
}

-- apply_put_policy(headers, opts) -> headers (mutated and returned)
-- opts:
--   mode           DAV_EMIT_HASH_HEADER value: "on-request" | "always" | "never"
--   requested_hash true when the request carried `X-Hash: sha256`
--   sha256         locally computed content hash (the object key basename)
--   passthrough    set of upstream header names (lowercase) to copy
--   upstream       harvested locator table (may be nil)
local function apply_put_policy(headers, opts)
    if opts.mode == "always" or (opts.mode == "on-request" and opts.requested_hash) then
        headers["X-Hash-SHA256"] = opts.sha256
    end

    for name, _ in pairs(opts.passthrough or {}) do
        local field = UPSTREAM_FIELD[name]
        local value = field and opts.upstream and opts.upstream[field]
        if value and value ~= "" then
            headers[name] = value
        end
    end

    return headers
end

return { apply_put_policy = apply_put_policy }
