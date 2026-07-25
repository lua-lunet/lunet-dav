---@diagnostic disable: undefined-global, undefined-field

describe("PUT response header policy", function()
    local dav_headers

    before_each(function()
        package.loaded["dav_headers"] = nil
        dav_headers = require("dav_headers")
    end)

    after_each(function()
        package.loaded["dav_headers"] = nil
    end)

    local function base_headers()
        return { ["OC-FileId"] = "00000001oczn5x60nrdu", ["OC-Etag"] = "\"e\"" }
    end

    it("on-request emits X-Hash-SHA256 only when the request asked for it", function()
        local asked = dav_headers.apply_put_policy(base_headers(), {
            mode = "on-request", requested_hash = true, sha256 = "abc",
        })
        assert.equals("abc", asked["X-Hash-SHA256"])

        local silent = dav_headers.apply_put_policy(base_headers(), {
            mode = "on-request", requested_hash = false, sha256 = "abc",
        })
        assert.is_nil(silent["X-Hash-SHA256"])
    end)

    it("always emits X-Hash-SHA256 without a request header", function()
        local h = dav_headers.apply_put_policy(base_headers(), {
            mode = "always", requested_hash = false, sha256 = "abc",
        })
        assert.equals("abc", h["X-Hash-SHA256"])
    end)

    it("never suppresses X-Hash-SHA256 even when requested", function()
        local h = dav_headers.apply_put_policy(base_headers(), {
            mode = "never", requested_hash = true, sha256 = "abc",
        })
        assert.is_nil(h["X-Hash-SHA256"])
    end)

    it("copies allowlisted upstream headers that were harvested", function()
        local h = dav_headers.apply_put_policy(base_headers(), {
            mode = "never",
            passthrough = { ["x-amz-version-id"] = true, ["x-amz-checksum-sha256"] = true },
            upstream = { version_id = "v-1", etag = "e", checksum_sha256 = "sum" },
        })
        assert.equals("v-1", h["x-amz-version-id"])
        assert.equals("sum", h["x-amz-checksum-sha256"])
    end)

    it("skips allowlisted names that were not harvested", function()
        local h = dav_headers.apply_put_policy(base_headers(), {
            mode = "never",
            passthrough = { ["x-amz-version-id"] = true, ["x-amz-checksum-sha256"] = true },
            upstream = { version_id = "v-1" },
        })
        assert.equals("v-1", h["x-amz-version-id"])
        assert.is_nil(h["x-amz-checksum-sha256"])
    end)

    it("skips allowlisted names with no upstream mapping", function()
        local h = dav_headers.apply_put_policy(base_headers(), {
            mode = "never",
            passthrough = { ["x-amz-server-side-encryption"] = true },
            upstream = { version_id = "v-1", checksum_sha256 = "sum" },
        })
        assert.is_nil(h["x-amz-server-side-encryption"])
    end)

    it("copies nothing with an empty allowlist, and never leaks unlisted upstream values", function()
        local h = dav_headers.apply_put_policy(base_headers(), {
            mode = "never",
            passthrough = {},
            upstream = { version_id = "v-1", etag = "e", checksum_sha256 = "sum" },
        })
        assert.is_nil(h["x-amz-version-id"])
        assert.is_nil(h["x-amz-checksum-sha256"])
        assert.is_nil(h["etag"])
    end)

    it("leaves the fixed nc core headers untouched", function()
        local h = dav_headers.apply_put_policy(base_headers(), {
            mode = "always", requested_hash = false, sha256 = "abc",
            passthrough = { ["x-amz-version-id"] = true },
            upstream = { version_id = "v-1" },
        })
        assert.equals("00000001oczn5x60nrdu", h["OC-FileId"])
        assert.equals("\"e\"", h["OC-Etag"])
    end)
end)
