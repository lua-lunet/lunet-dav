---@diagnostic disable: undefined-global, undefined-field

describe("db.pool", function()
    local db
    local fake

    local function fake_postgres()
        fake = {
            conns = {},
            queries = {},
            closed = {},
            fail_on = nil,
            rows_queue = {},
            open_count = 0,
            max_opens = nil,
        }
        package.loaded["lunet.postgres"] = {
            open = function(_)
                if fake.max_opens and fake.open_count >= fake.max_opens then
                    return nil, "too many opens"
                end
                fake.open_count = fake.open_count + 1
                local conn = { id = fake.open_count }
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
                fake.open_count = fake.open_count - 1
            end,
        }
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

    it("caps total open connections at MAX_TOTAL_CONNS under concurrent get_conn calls", function()
        db._set_max_total_conns(3)
        fake.max_opens = 100

        local results = {}
        local coros = {}

        for i = 1, 5 do
            coros[i] = coroutine.create(function()
                local conn, err = db.get_conn({})
                results[i] = { conn = conn, err = err }
            end)
        end

        for i = 1, 3 do
            coroutine.resume(coros[i])
        end

        assert.equals(3, fake.open_count)

        for i = 4, 5 do
            coroutine.resume(coros[i])
        end

        assert.equals(3, fake.open_count)

        local conn1 = results[1].conn
        db.release_conn(conn1)

        coroutine.resume(coros[4])
        assert.equals(3, fake.open_count)
        assert.is_not_nil(results[4].conn)

        local conn2 = results[2].conn
        db.release_conn(conn2)
        coroutine.resume(coros[5])
        assert.equals(3, fake.open_count)
        assert.is_not_nil(results[5].conn)
    end)

    it("decrements open_count after a query error closes a conn", function()
        db._set_max_total_conns(2)

        local conn1, _ = db.get_conn({})
        local conn2, _ = db.get_conn({})
        assert.equals(2, fake.open_count)

        db.release_conn(conn1)
        assert.equals(2, fake.open_count)

        fake.fail_on = "SELECT"
        local res, err = db.query({}, "SELECT 1")
        assert.is_nil(res)
        assert.is_not_nil(err)
        assert.equals(1, fake.open_count)

        local conn3, err3 = db.get_conn({})
        assert.is_not_nil(conn3)
        assert.is_nil(err3)
        assert.equals(2, fake.open_count)
    end)

    it("release wakes exactly one waiter", function()
        db._set_max_total_conns(1)

        local conn1, _ = db.get_conn({})
        assert.equals(1, fake.open_count)

        local waiter1_done = false
        local waiter2_done = false
        local w1_conn = nil
        local w2_conn = nil

        local w1 = coroutine.create(function()
            w1_conn, _ = db.get_conn({})
            waiter1_done = true
        end)

        local w2 = coroutine.create(function()
            w2_conn, _ = db.get_conn({})
            waiter2_done = true
        end)

        coroutine.resume(w1)
        assert.is_false(waiter1_done)

        coroutine.resume(w2)
        assert.is_false(waiter2_done)

        db.release_conn(conn1)
        assert.is_true(waiter1_done)
        assert.is_false(waiter2_done)
        assert.is_not_nil(w1_conn)

        db.release_conn(w1_conn)
        assert.is_true(waiter2_done)
        assert.is_not_nil(w2_conn)
    end)
end)

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

    it("surfaces dest_cas when a version-guarded DELETE returns zero rows inside a tx", function()
        fake.rows_queue = {
            {},
            { { id = 20, version = 4 } },
            {},
            {},
        }

        local res, err = db.transaction({}, function(tx)
            local dest = tx.query_row(
                "SELECT id, version FROM dav_files WHERE collection=$1 AND name=$2 FOR UPDATE",
                "coll", "target.txt")
            if dest then
                local deleted = tx.query_row(
                    "DELETE FROM dav_files WHERE id=$1 AND version=$2 RETURNING id",
                    dest.id, dest.version)
                if not deleted then
                    return nil, "dest_cas"
                end
            end
            return { overwritten = true }
        end)

        assert.is_nil(res)
        assert.equals("dest_cas", err)
        local s = sqls()
        assert.equals("ROLLBACK", s[#s])
        for _, q in ipairs(fake.queries) do
            assert.are_not.equals("COMMIT", q.sql)
        end
    end)
end)
