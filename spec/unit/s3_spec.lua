---@diagnostic disable: undefined-global, undefined-field

describe("S3 response bodies", function()
    local reads
    local writes
    local s3

    before_each(function()
        reads = {}
        writes = {}
        package.loaded["lunet.socket"] = {
            connect = function() return {} end,
            write = function(_, wire)
                writes[#writes + 1] = wire
                return nil
            end,
            close = function() end,
            read = function()
                local next_read = table.remove(reads, 1)
                if next_read == nil then return nil, "closed" end
                if type(next_read) == "table" and next_read.err then
                    return nil, next_read.err
                end
                return next_read
            end,
        }
        package.loaded["lib.crypto"] = {
            sha256_hex = function() return string.rep("0", 64) end,
            hmac_sha256_full = function() return string.rep("\0", 32) end,
            base64_encode = function() return "BASE64ENCODED" end,
        }
        package.loaded["s3"] = nil
        s3 = require("s3")
    end)

    after_each(function()
        package.loaded["s3"] = nil
        package.loaded["lunet.socket"] = nil
        package.loaded["lib.crypto"] = nil
    end)

    local config = {
        S3_ENDPOINT = "http://127.0.0.1:9000",
        S3_BUCKET = "test",
        S3_REGION = "us-east-1",
        S3_ACCESS_KEY_ID = "key",
        S3_SECRET_ACCESS_KEY = "secret",
    }

    it("rejects EOF before the declared Content-Length", function()
        reads = {
            "HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nhel",
        }

        local body, err = s3.get_object(config, "_landing/digest")

        assert.is_nil(body)
        assert.matches("closed before complete response body", err, 1, true)
        assert.matches("expected 6 bytes, received 3", err, 1, true)
    end)

    it("accepts a complete declared response body", function()
        reads = {
            "HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nhel",
            "lo\n",
        }

        local body, metadata = s3.get_object(config, "_landing/digest")

        assert.equals("hello\n", body)
        assert.is_table(metadata)
    end)

    it("does not read a body from a HEAD response", function()
        reads = {
            "HTTP/1.1 200 OK\r\nContent-Length: 6\r\n"
                .. "ETag: \"etag\"\r\nX-Amz-Version-Id: version-1\r\n\r\n",
        }

        local locator, err = s3.head_object(config, "_landing/digest")

        assert.is_nil(err)
        assert.same({ etag = "etag", version_id = "version-1" }, locator)
    end)

    it("reuses the winning version when a conditional PUT loses a race", function()
        reads = {
            "HTTP/1.1 412 Precondition Failed\r\nContent-Length: 0\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Length: 6\r\n"
                .. "ETag: \"etag\"\r\nX-Amz-Version-Id: version-1\r\n\r\n",
        }

        local locator, err = s3.put_object(config, "_landing/digest", "hello\n", "text/plain")

        assert.is_nil(err)
        assert.same({ etag = "etag", version_id = "version-1" }, locator)
        assert.matches("If%-None%-Match: %*", writes[1])
    end)

    it("lcd profile sends no checksum header and harvests nothing", function()
        reads = {
            "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n"
                .. "ETag: \"etag\"\r\nX-Amz-Version-Id: version-1\r\n"
                .. "X-Amz-Checksum-Sha256: ignored\r\n\r\n",
        }
        local cfg = {}
        for k, v in pairs(config) do cfg[k] = v end
        cfg.behavior = { S3_API_PROFILE = "lcd" }

        local locator, err = s3.put_object(cfg, "_landing/digest", "hello\n", "text/plain")

        assert.is_nil(err)
        assert.is_nil(locator.checksum_sha256)
        assert.not_matches("[Cc]hecksum", writes[1])
        assert.equals(1, #writes)
    end)

    it("checksum-capable profile sends and harvests x-amz-checksum-sha256", function()
        reads = {
            "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n"
                .. "ETag: \"etag\"\r\nX-Amz-Version-Id: version-1\r\n"
                .. "X-Amz-Checksum-Sha256: upstreamsum\r\n\r\n",
        }
        local cfg = {}
        for k, v in pairs(config) do cfg[k] = v end
        cfg.behavior = { S3_API_PROFILE = "minio" }

        local locator, err = s3.put_object(cfg, "_landing/digest", "hello\n", "text/plain")

        assert.is_nil(err)
        assert.equals("upstreamsum", locator.checksum_sha256)
        assert.matches("x%-amz%-checksum%-sha256: BASE64ENCODED", writes[1])
        assert.equals(1, #writes)
    end)

    it("follows up with HeadObject when a capable profile's PUT omits the checksum", function()
        reads = {
            "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n"
                .. "ETag: \"etag\"\r\nX-Amz-Version-Id: version-1\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n"
                .. "ETag: \"etag\"\r\nX-Amz-Version-Id: version-1\r\n"
                .. "X-Amz-Checksum-Sha256: headsum\r\n\r\n",
        }
        local cfg = {}
        for k, v in pairs(config) do cfg[k] = v end
        cfg.behavior = { S3_API_PROFILE = "minio-enterprise" }

        local locator, err = s3.put_object(cfg, "_landing/digest", "hello\n", "text/plain")

        assert.is_nil(err)
        assert.equals("headsum", locator.checksum_sha256)
        assert.equals(2, #writes)
        assert.matches("^HEAD ", writes[2])
        assert.matches("x%-amz%-checksum%-mode: ENABLED", writes[2])
    end)

    it("lcd HeadObject does not request checksum mode", function()
        reads = {
            "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n"
                .. "ETag: \"etag\"\r\nX-Amz-Version-Id: version-1\r\n\r\n",
        }

        local locator, err = s3.head_object(config, "_landing/digest")

        assert.is_nil(err)
        assert.equals("version-1", locator.version_id)
        assert.not_matches("checksum", writes[1])
    end)

    it("lcd never follows up even when the PUT response omits the checksum", function()
        reads = {
            "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n"
                .. "ETag: \"etag\"\r\nX-Amz-Version-Id: version-1\r\n\r\n",
        }
        local cfg = {}
        for k, v in pairs(config) do cfg[k] = v end
        cfg.behavior = { S3_API_PROFILE = "lcd" }

        local locator, err = s3.put_object(cfg, "_landing/digest", "hello\n", "text/plain")

        assert.is_nil(err)
        assert.is_nil(locator.checksum_sha256)
        assert.equals(1, #writes)
    end)

    it("minio PUT signs content-type and x-amz-checksum-sha256 in canonical request", function()
        reads = {
            "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n"
                .. "ETag: \"etag\"\r\nX-Amz-Version-Id: version-1\r\n"
                .. "X-Amz-Checksum-Sha256: upstreamsum\r\n\r\n",
        }
        local cfg = {}
        for k, v in pairs(config) do cfg[k] = v end
        cfg.behavior = { S3_API_PROFILE = "minio" }

        s3.put_object(cfg, "_landing/digest", "hello\n", "text/plain")

        local wire = writes[1]
        assert.matches("SignedHeaders=content%-type;host;x%-amz%-checksum%-sha256;x%-amz%-content%-sha256;x%-amz%-date", wire)
        assert.matches("x%-amz%-checksum%-sha256: BASE64ENCODED", wire)
    end)

    it("minio HEAD signs x-amz-checksum-mode in canonical request", function()
        reads = {
            "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n"
                .. "ETag: \"etag\"\r\nX-Amz-Version-Id: version-1\r\n"
                .. "X-Amz-Checksum-Sha256: upstreamsum\r\n\r\n",
        }
        local cfg = {}
        for k, v in pairs(config) do cfg[k] = v end
        cfg.behavior = { S3_API_PROFILE = "minio" }

        s3.head_object(cfg, "_landing/digest")

        local wire = writes[1]
        assert.matches("x%-amz%-checksum%-mode", wire:match("SignedHeaders=[^,\r\n]+"))
    end)

    it("lcd PUT signs content-type when sent and uses base signed headers without it", function()
        reads = {
            "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n"
                .. "ETag: \"etag\"\r\nX-Amz-Version-Id: version-1\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n"
                .. "ETag: \"etag\"\r\nX-Amz-Version-Id: version-1\r\n\r\n",
        }
        local cfg = {}
        for k, v in pairs(config) do cfg[k] = v end
        cfg.behavior = { S3_API_PROFILE = "lcd" }

        s3.put_object(cfg, "_landing/digest", "hello\n")

        local wire_no_ct = writes[1]
        assert.matches("SignedHeaders=host;x%-amz%-content%-sha256;x%-amz%-date", wire_no_ct)
        assert.not_matches("[Cc]ontent%-[Tt]ype", wire_no_ct)

        s3.put_object(cfg, "_landing/digest2", "hello\n", "text/plain")

        local wire_with_ct = writes[2]
        assert.matches("SignedHeaders=content%-type;host;x%-amz%-content%-sha256;x%-amz%-date", wire_with_ct)
        assert.matches("content%-type: text/plain", wire_with_ct)
    end)

    it("decodes a chunked response split across reads", function()
        reads = {
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel",
            "lo\r\n0\r\n\r\n",
        }

        local body, metadata = s3.get_object(config, "_landing/digest")

        assert.equals("hello", body)
        assert.is_table(metadata)
    end)

    it("decodes a chunked response with a mid-stream chunk split inside data", function()
        reads = {
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\n",
            "hel",
            "lo\r\n0\r\n\r\n",
        }

        local body, metadata = s3.get_object(config, "_landing/digest")

        assert.equals("hello", body)
        assert.is_table(metadata)
    end)

    it("surfaces an error when a no-CL body read fails mid-stream", function()
        reads = {
            "HTTP/1.1 200 OK\r\n\r\nsome data",
            { err = "reset" },
        }

        local body, err = s3.get_object(config, "_landing/digest")

        assert.is_nil(body)
        assert.matches("S3 connection error mid-body", err, 1, true)
        assert.matches("reset", err, 1, true)
    end)

    it("rejects an unknown Transfer-Encoding", function()
        reads = {
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\n\r\n",
        }

        local body, err = s3.get_object(config, "_landing/digest")

        assert.is_nil(body)
        assert.matches("unsupported transfer-encoding", err, 1, true)
    end)

    it("rejects a chunked response with malformed CRLF after chunk data", function()
        reads = {
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhelloXX0\r\n\r\n",
        }

        local body, err = s3.get_object(config, "_landing/digest")

        assert.is_nil(body)
        assert.matches("malformed chunked encoding", err, 1, true)
    end)

    it("rejects a chunked response with an oversized size line", function()
        local big_size_line = string.rep("1", 40) .. "\r\n"
        reads = {
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" .. big_size_line,
        }

        local body, err = s3.get_object(config, "_landing/digest")

        assert.is_nil(body)
        assert.matches("malformed chunked encoding", err, 1, true)
    end)

    it("rejects a chunked response with a non-hex size line", function()
        reads = {
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n",
        }

        local body, err = s3.get_object(config, "_landing/digest")

        assert.is_nil(body)
        assert.matches("malformed chunked encoding", err, 1, true)
    end)

    it("rejects a Content-Length response exceeding the maximum body size", function()
        reads = {
            "HTTP/1.1 200 OK\r\nContent-Length: 536870913\r\n\r\n",
        }

        local body, err = s3.get_object(config, "_landing/digest")

        assert.is_nil(body)
        assert.matches("too large", err, 1, true)
    end)
end)
