---@diagnostic disable: undefined-global, undefined-field

describe("db.transaction", function()
    local db
    local fake

    local function fake_postgres()
        fake = {
            conns = {},
            queries = {},
            closed = {},
            fail_on = nil,
            rows_queue = {},
        }
        package.loaded["lunet.postgres"] = {
            open = function(_)
                local conn = { id = #fake.conns + 1 }
                fake.conns[#fake.conns + 1] = conn
                return conn, nil
            end,
            query = function(conn, sql, ...)
                fake.queries[#fake.queries + 1] = { conn = conn, sql = sql }
                if fake.fail_on and sql:find(fake.fail_on, 1, true) then
                    return nil, "forced failure"
                end
                if #fake.rows_queue > 0 then
                    return table.remove(fake.rows_queue, 1), nil
                end
                return {}, nil
            end,
            close = function(conn)
                fake.closed[#fake.closed + 1] = conn
            end,
        }
    end

    local function sqls()
        local out = {}
        for _, q in ipairs(fake.queries) do
            out[#out + 1] = q.sql
        end
        return out
    end

    before_each(function()
        fake_postgres()
        package.loaded["db"] = nil
        db = require("db")
    end)

    after_each(function()
        package.loaded["db"] = nil
        package.loaded["lunet.postgres"] = nil
    end)

    it("runs BEGIN, fn statements, COMMIT on one pinned connection", function()
        fake.rows_queue = { {}, {}, { { id = 7, name = "x" } }, {} }

        local row, err = db.transaction({}, function(tx)
            tx.query("DELETE FROM dav_files WHERE id = $1", 2)
            return tx.query_row("UPDATE dav_files SET name = $1 WHERE id = $2 RETURNING id, name", "x", 7)
        end)

        assert.is_nil(err)
        assert.equals(7, row.id)
        local s = sqls()
        assert.equals("BEGIN", s[1])
        assert.matches("DELETE FROM dav_files", s[2])
        assert.matches("UPDATE dav_files", s[3])
        assert.equals("COMMIT", s[4])
        assert.is_nil(s[5])
        for _, q in ipairs(fake.queries) do
            assert.equals(1, q.conn.id)
        end
    end)

    it("rolls back when fn returns nil and passes the reason through", function()
        local res, err = db.transaction({}, function(tx)
            tx.query("DELETE FROM dav_files WHERE id = $1", 2)
            local updated = tx.query_row("UPDATE dav_files SET name = $1 WHERE id = $2 RETURNING id", "x", 9)
            if not updated then
                return nil, "cas"
            end
            return updated
        end)

        assert.is_nil(res)
        assert.equals("cas", err)
        local s = sqls()
        assert.equals("ROLLBACK", s[#s])
        for _, q in ipairs(fake.queries) do
            assert.are_not.equals("COMMIT", q.sql)
        end
    end)

    it("rolls back and propagates an error raised inside fn", function()
        local res, err = db.transaction({}, function(_)
            error("boom", 0)
        end)

        assert.is_nil(res)
        assert.equals("boom", err)
        assert.equals("ROLLBACK", sqls()[#sqls()])
    end)

    it("rolls back and surfaces the driver error when a tx statement fails", function()
        fake.fail_on = "DELETE"

        local res, err = db.transaction({}, function(tx)
            tx.query("DELETE FROM dav_files WHERE id = $1", 2)
            return true
        end)

        assert.is_nil(res)
        assert.matches("forced failure", err)
        assert.equals("ROLLBACK", sqls()[#sqls()])
    end)

    it("returns the connection to the pool after COMMIT", function()
        local ok = db.transaction({}, function(_)
            return true
        end)
        assert.is_true(ok)

        db.query({}, "SELECT 1")

        assert.equals(1, #fake.conns)
        assert.equals("SELECT 1", sqls()[#sqls()])
    end)

    it("returns the connection to the pool after ROLLBACK", function()
        local ok, _ = db.transaction({}, function(_)
            error("boom", 0)
        end)
        assert.is_nil(ok)

        db.query({}, "SELECT 1")

        assert.equals(1, #fake.conns)
    end)

    it("closes the connection and errors when BEGIN fails", function()
        fake.fail_on = "BEGIN"

        local res, err = db.transaction({}, function(_)
            return true
        end)

        assert.is_nil(res)
        assert.matches("forced failure", err)
        assert.equals(1, #fake.closed)
    end)

    it("query_row returns nil for an empty result set", function()
        local seen
        local ok = db.transaction({}, function(tx)
            seen = tx.query_row("SELECT 1 WHERE false")
            return true
        end)

        assert.is_true(ok)
        assert.is_nil(seen)
    end)
end)
