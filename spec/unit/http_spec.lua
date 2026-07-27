---@diagnostic disable: undefined-global, undefined-field

describe("http.read_request", function()
    local http
    local reads
    local writes
    local closed

    local function fake_socket()
        reads = reads or {}
        writes = writes or {}
        closed = false
        package.loaded["lunet.socket"] = {
            read = function()
                local c = table.remove(reads, 1)
                if c == nil then return nil, "closed" end
                return c
            end,
            write = function(_, data)
                writes[#writes + 1] = data
                return nil
            end,
            close = function() closed = true end,
        }
    end

    before_each(function()
        reads = {}
        writes = {}
        closed = false
        fake_socket()
        package.loaded["http"] = nil
        http = require("http")
    end)

    after_each(function()
        package.loaded["http"] = nil
        package.loaded["lunet.socket"] = nil
    end)

    local HEAD = "PUT /remote.php/dav/files/alice/hello.txt HTTP/1.1\r\n"
        .. "Host: localhost\r\n"
        .. "Content-Length: 6\r\n"
        .. "\r\n"

    it("reassembles a fragmented request (headers in 2 chunks, body in 3)", function()
        reads = {
            "PUT /remote.php/dav/files/alice/hello.txt HTTP/1.1\r\nHost: localh",
            "ost\r\nContent-Length: 6\r\n\r\nhe",
            "ll",
            "o\n",
        }

        local req, err = http.read_request({}, {})

        assert.is_nil(err)
        assert.equals("PUT", req.method)
        assert.equals("/remote.php/dav/files/alice/hello.txt", req.path)
        assert.equals("hello\n", req.body)
        assert.equals("6", req.headers["content-length"])
    end)

    it("sends 100 Continue before reading the body when Expect is set", function()
        reads = {
            "PUT /x HTTP/1.1\r\nHost: h\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n",
            "hello",
        }

        local req, err = http.read_request({}, {})

        assert.is_nil(err)
        assert.equals("hello", req.body)
        assert.equals(1, #writes)
        assert.matches("100 Continue", writes[1], 1, true)
    end)

    it("rejects Transfer-Encoding: chunked with 501", function()
        reads = {
            "PUT /x HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n",
        }

        local req, err = http.read_request({}, {})

        assert.is_nil(req)
        assert.equals(501, err.status)
    end)

    it("returns 411 when PUT has no Content-Length", function()
        reads = {
            "PUT /x HTTP/1.1\r\nHost: h\r\n\r\n",
        }

        local req, err = http.read_request({}, {})

        assert.is_nil(req)
        assert.equals(411, err.status)
    end)

    it("returns 413 when Content-Length exceeds the cap", function()
        reads = {
            "PUT /x HTTP/1.1\r\nHost: h\r\nContent-Length: 1000\r\n\r\n",
        }

        local req, err = http.read_request({}, { max_body_bytes = 100 })

        assert.is_nil(req)
        assert.equals(413, err.status)
    end)

    it("returns 400 when the body EOF arrives early", function()
        reads = {
            "PUT /x HTTP/1.1\r\nHost: h\r\nContent-Length: 100\r\n\r\n",
            "only",
            "part",
        }

        local req, err = http.read_request({}, {})

        assert.is_nil(req)
        assert.equals(400, err.status)
    end)

    it("returns 400 when the header block exceeds 64 KB", function()
        local big = "GET /x HTTP/1.1\r\nHost: h\r\nX-Pad: "
            .. string.rep("A", 70000) .. "\r\n\r\n"
        reads = { big }

        local req, err = http.read_request({}, {})

        assert.is_nil(req)
        assert.equals(400, err.status)
    end)

    it("GET with no body returns an empty body string", function()
        reads = { "GET /health HTTP/1.1\r\nHost: h\r\n\r\n" }

        local req, err = http.read_request({}, {})

        assert.is_nil(err)
        assert.equals("GET", req.method)
        assert.equals("", req.body)
    end)

    it("reassembles a fragmented PROPFIND body across reads", function()
        local xml = '<?xml version="1.0"?><propfind xmlns="DAV:"><prop><propname/></prop></propfind>'
        reads = {
            "PROPFIND /remote.php/dav/files/alice HTTP/1.1\r\nHost: h\r\nContent-Length: "
                .. #xml .. "\r\n\r\n",
            xml:sub(1, 20),
            xml:sub(21),
        }

        local req, err = http.read_request({}, {})

        assert.is_nil(err)
        assert.equals("PROPFIND", req.method)
        assert.equals(xml, req.body)
    end)

    it("reassembles a fragmented POST form body across reads", function()
        local body = "user=alice&password=secret"
        reads = {
            "POST /login/v2/grant HTTP/1.1\r\nHost: h\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: "
                .. #body .. "\r\n\r\n",
            body:sub(1, 10),
            body:sub(11),
        }

        local req, err = http.read_request({}, {})

        assert.is_nil(err)
        assert.equals("POST", req.method)
        assert.equals(body, req.body)
    end)

    it("POST with CL where body arrives partly with headers and partly later", function()
        local body = "token=abcdef123456"
        reads = {
            "POST /login/v2/poll HTTP/1.1\r\nHost: h\r\nContent-Length: "
                .. #body .. "\r\n\r\n" .. body:sub(1, 8),
            body:sub(9),
        }

        local req, err = http.read_request({}, {})

        assert.is_nil(err)
        assert.equals("POST", req.method)
        assert.equals(body, req.body)
    end)

    it("POST without Content-Length gets an empty body (not 411)", function()
        reads = {
            "POST /index.php/login/v2 HTTP/1.1\r\nHost: h\r\n\r\n",
        }

        local req, err = http.read_request({}, {})

        assert.is_nil(err)
        assert.equals("POST", req.method)
        assert.equals("", req.body)
    end)

    it("returns 413 when POST Content-Length exceeds the cap", function()
        reads = {
            "POST /login/v2/poll HTTP/1.1\r\nHost: h\r\nContent-Length: 1000\r\n\r\n",
        }

        local req, err = http.read_request({}, { max_body_bytes = 100 })

        assert.is_nil(req)
        assert.equals(413, err.status)
    end)

    it("returns 400 when POST body EOF arrives early", function()
        reads = {
            "POST /login/v2/poll HTTP/1.1\r\nHost: h\r\nContent-Length: 100\r\n\r\n",
            "only",
            "part",
        }

        local req, err = http.read_request({}, {})

        assert.is_nil(req)
        assert.equals(400, err.status)
    end)
end)
