---@diagnostic disable: undefined-global, undefined-field

describe("behavior configuration", function()
    local behavior

    before_each(function()
        package.loaded["behavior"] = nil
        behavior = require("behavior")
    end)

    after_each(function()
        package.loaded["behavior"] = nil
    end)

    local function no_env()
        return nil
    end

    it("returns the defaults when nothing overrides them", function()
        local b, errs = behavior.resolve({}, no_env)

        assert.is_nil(errs)
        assert.same({
            DAV_INSTANCE_ID = "oczn5x60nrdu",
            DAV_FILEID_PAD_WIDTH = 8,
            S3_LANDING_PREFIX = "_landing/",
            S3_API_PROFILE = "lcd",
            DAV_EMIT_HASH_HEADER = "on-request",
            DAV_PUT_PASSTHROUGH_HEADERS = {},
            DAV_MAX_UPLOAD_BYTES = 536870912,
        }, b)
    end)

    it("lets .env override the defaults", function()
        local b, errs = behavior.resolve({
            DAV_INSTANCE_ID = "myinstance01",
            DAV_FILEID_PAD_WIDTH = "10",
            S3_API_PROFILE = "minio",
            DAV_EMIT_HASH_HEADER = "always",
        }, no_env)

        assert.is_nil(errs)
        assert.equals("myinstance01", b.DAV_INSTANCE_ID)
        assert.equals(10, b.DAV_FILEID_PAD_WIDTH)
        assert.equals("minio", b.S3_API_PROFILE)
        assert.equals("always", b.DAV_EMIT_HASH_HEADER)
    end)

    it("lets real env vars override .env", function()
        local b, errs = behavior.resolve(
            { DAV_INSTANCE_ID = "fromdotenv", S3_API_PROFILE = "lcd" },
            function(name)
                if name == "DAV_INSTANCE_ID" then return "fromenv" end
                return nil
            end
        )

        assert.is_nil(errs)
        assert.equals("fromenv", b.DAV_INSTANCE_ID)
        assert.equals("lcd", b.S3_API_PROFILE)
    end)

    it("rejects a non-numeric DAV_FILEID_PAD_WIDTH", function()
        local b, errs = behavior.resolve({ DAV_FILEID_PAD_WIDTH = "wide" }, no_env)

        assert.is_nil(b)
        assert.equals(1, #errs)
        assert.matches("DAV_FILEID_PAD_WIDTH", errs[1], 1, true)
    end)

    it("coerces DAV_PUT_PASSTHROUGH_HEADERS to a lowercase trimmed set", function()
        local b, errs = behavior.resolve({
            DAV_PUT_PASSTHROUGH_HEADERS = " X-Amz-Version-Id ,x-amz-checksum-sha256,,",
        }, no_env)

        assert.is_nil(errs)
        assert.same({
            ["x-amz-version-id"] = true,
            ["x-amz-checksum-sha256"] = true,
        }, b.DAV_PUT_PASSTHROUGH_HEADERS)
    end)

    it("treats an empty passthrough value as an empty set", function()
        local b, errs = behavior.resolve({ DAV_PUT_PASSTHROUGH_HEADERS = "  " }, no_env)

        assert.is_nil(errs)
        assert.same({}, b.DAV_PUT_PASSTHROUGH_HEADERS)
    end)

    it("rejects an unknown S3_API_PROFILE, naming the key", function()
        local b, errs = behavior.resolve({ S3_API_PROFILE = "gcs" }, no_env)

        assert.is_nil(b)
        assert.matches("S3_API_PROFILE", errs[1], 1, true)
        assert.matches("gcs", errs[1], 1, true)
    end)

    it("rejects an unknown DAV_EMIT_HASH_HEADER, naming the key", function()
        local b, errs = behavior.resolve({ DAV_EMIT_HASH_HEADER = "sometimes" }, no_env)

        assert.is_nil(b)
        assert.matches("DAV_EMIT_HASH_HEADER", errs[1], 1, true)
    end)

    it("rejects unknown DAV_/S3_ keys found in .env", function()
        local b, errs = behavior.resolve({
            DAV_BIND_INTERFACES = "127.0.0.1",
            S3_FORCE_PATH_STYLE = "true",
        }, no_env)

        assert.is_nil(b)
        assert.equals(2, #errs)
        assert.matches("DAV_BIND_INTERFACES", table.concat(errs, "\n"), 1, true)
        assert.matches("S3_FORCE_PATH_STYLE", table.concat(errs, "\n"), 1, true)
    end)

    it("ignores the known S3 connection keys without resolving them", function()
        local b, errs = behavior.resolve({
            S3_ENDPOINT = "http://127.0.0.1:9000",
            S3_REGION = "us-east-1",
            S3_BUCKET = "b",
            S3_ACCESS_KEY_ID = "k",
            S3_SECRET_ACCESS_KEY = "s",
        }, no_env)

        assert.is_nil(errs)
        assert.is_nil(b.S3_ENDPOINT)
        assert.is_nil(b.S3_BUCKET)
    end)
end)
