all: init lint start test

PID_FILE = target/lunet.pid

init:
	@echo "Checking dependencies..."
	@command -v mise >/dev/null 2>&1 || { echo "ERROR: mise is not installed. Please install: curl https://mise.run | sh"; exit 1; }
	@echo "  mise: OK"
	@mise trust --quiet 2>/dev/null || { echo "ERROR: mise is not trusted. Please run: mise trust"; exit 1; }
	@mise install --yes
	@echo "  mise tools: OK"
	@command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is not installed. Please install: brew install curl"; exit 1; }
	@echo "  curl: OK"
	@test -x bin/lunet-run || { echo "ERROR: bin/lunet-run not found. See https://github.com/lua-lunet/lunet releases."; exit 1; }
	@echo "  lunet-run: OK"
	@mise exec -- hurl --version 2>/dev/null | grep -qE ' 8\.' || { echo "ERROR: hurl 8.x is required (via mise)."; exit 1; }
	@echo "  hurl: OK"
	@mise exec -- lua-language-server --version >/dev/null 2>&1 || { echo "ERROR: lua-language-server is not installed via mise."; exit 1; }
	@echo "  lua-language-server: OK"
	@echo "Checking LuaExpat (lxp)..."
	@command -v luarocks >/dev/null 2>&1 || { echo "ERROR: luarocks is not installed. Please install: brew install luarocks"; exit 1; }
	@echo "  luarocks: OK"
	@UNAME=$$(uname -s); \
	if [ "$$UNAME" = "Darwin" ]; then \
		EXPAT_PREFIX=$$(brew --prefix expat 2>/dev/null) || true; \
		if [ -z "$$EXPAT_PREFIX" ]; then brew install expat; EXPAT_PREFIX=$$(brew --prefix expat); fi; \
		luarocks list luaexpat 2>/dev/null | grep -q luaexpat \
			|| luarocks install luaexpat EXPAT_DIR="$$EXPAT_PREFIX"; \
		echo "  lxp (busted): OK"; \
		if [ ! -f bin/lxp.so ] || [ ! -f bin/lxp/lom.lua ]; then \
			echo "  building lxp for lunet-run (gitignored build artifact)..."; \
			rm -rf target/lxp-build; \
			luarocks --lua-version=5.1 --lua-dir="$$(brew --prefix luajit)" install luaexpat \
				--tree=target/lxp-build EXPAT_DIR="$$EXPAT_PREFIX" \
				&& mkdir -p bin/lxp \
				&& cp target/lxp-build/lib/lua/5.1/lxp.so bin/lxp.so \
				&& cp target/lxp-build/share/lua/5.1/lxp/lom.lua bin/lxp/lom.lua \
				&& rm -rf target/lxp-build \
				|| { echo "ERROR: failed to build lxp for lunet-run."; exit 1; }; \
		fi; \
	else \
		dpkg -s lua-expat >/dev/null 2>&1 || { echo "ERROR: lua-expat is not installed. Please run: apt install lua-expat"; exit 1; }; \
		mkdir -p bin/lxp; \
		ARCH_PATH=$$(dpkg -L lua-expat | grep '/lua/5\.1/lxp\.so$$' | head -1); \
		[ -n "$$ARCH_PATH" ] || { echo "ERROR: lua-expat has no Lua 5.1 module (LuaJIT ABI)."; exit 1; }; \
		ln -sf "$$ARCH_PATH" bin/lxp.so; \
		ln -sf /usr/share/lua/5.1/lxp/lom.lua bin/lxp/lom.lua; \
		echo "  lxp (apt lua-expat, symlinked): OK"; \
	fi
	@echo 'package.path = "./bin/?.lua;" .. package.path; package.cpath = "./bin/?.so;./bin/lunet/?.so;" .. package.cpath; local lom = require("lxp.lom"); assert(lom.parse("<a/>"), "parse failed")' > target/lxp-check.lua
	@./bin/lunet-run target/lxp-check.lua || { echo "ERROR: lxp.lom not loadable by lunet-run."; rm -f target/lxp-check.lua; exit 1; }
	@rm -f target/lxp-check.lua
	@echo "  lxp (runtime): OK"
	@echo "Initializing database..."
	@. ./.env; \
	echo "  Connecting to PostgreSQL at $$PGHOST:$$PGPORT, database: $$PGDATABASE, user: $$PGUSER"; \
	if ! pg_isready -h $$PGHOST -p $$PGPORT -U $$PGUSER -d $$PGDATABASE -q 2>/dev/null; then \
		echo "  WARNING: PostgreSQL is not reachable. Skipping schema initialization."; \
		echo "  (Run 'make db-reset' or start the database and re-run 'make init'.)"; \
	else \
		echo "  Applying schemas (sql/schema.sql, sql/auth_schema.sql, sql/dav_schema.sql)..."; \
		PGPASSWORD=$$PGPASSWORD psql -h $$PGHOST -p $$PGPORT -U $$PGUSER -d $$PGDATABASE \
			-v ON_ERROR_STOP=1 \
			-f sql/schema.sql \
			-f sql/auth_schema.sql \
			-f sql/dav_schema.sql \
			|| { echo "ERROR: schema initialization failed (see psql errors above)"; exit 1; }; \
		echo "  Database schema applied."; \
	fi
	@echo "Init complete."

start:
	@if [ -f $(PID_FILE) ] && kill -0 $$(cat $(PID_FILE)) 2>/dev/null; then \
		echo "Server already running (PID $$(cat $(PID_FILE)))."; \
	else \
		mkdir -p target; \
		set -a; . ./.env; set +a; \
		if lsof -nP -iTCP:$${LUNET_PORT:-8081} -sTCP:LISTEN >/dev/null 2>&1; then \
			echo "ERROR: port $${LUNET_PORT:-8081} is already in use:"; \
			lsof -nP -iTCP:$${LUNET_PORT:-8081} -sTCP:LISTEN; \
			echo "Refusing to start. Kill the other listener or change LUNET_PORT."; \
			exit 1; \
		fi; \
		nohup ./bin/lunet-run server.lua > target/server.log 2>&1 & \
		echo $$! > $(PID_FILE).tmp; \
		sleep 1; \
		curl -fsS http://127.0.0.1:$${LUNET_PORT:-8081}/health >/dev/null \
			|| { \
				tmp_pid=$$(cat $(PID_FILE).tmp 2>/dev/null || true); \
				if [ -n "$$tmp_pid" ] && ps -p $$tmp_pid -o command= 2>/dev/null | grep -q "lunet-run"; then \
					kill $$tmp_pid 2>/dev/null || true; \
				fi; \
				rm -f $(PID_FILE).tmp; \
				echo "ERROR: server failed to start. See target/server.log"; exit 1; \
			}; \
		listener_pid=$$(lsof -nP -tiTCP:$${LUNET_PORT:-8081} -sTCP:LISTEN 2>/dev/null || true); \
		if [ -z "$$listener_pid" ]; then \
			rm -f $(PID_FILE).tmp; \
			echo "ERROR: health check passed but no listener found on port $${LUNET_PORT:-8081}."; exit 1; \
		fi; \
		if ! ps -p $$listener_pid -o command= 2>/dev/null | grep -q "lunet-run"; then \
			rm -f $(PID_FILE).tmp; \
			echo "ERROR: listener on port $${LUNET_PORT:-8081} is not lunet-run (PID $$listener_pid)."; exit 1; \
		fi; \
		echo $$listener_pid > $(PID_FILE); \
		rm -f $(PID_FILE).tmp; \
		echo "Server started on port $${LUNET_PORT:-8081} (PID $$(cat $(PID_FILE)))."; \
	fi

stop:
	@if [ -f $(PID_FILE) ] && kill -0 $$(cat $(PID_FILE)) 2>/dev/null; then \
		stored_pid=$$(cat $(PID_FILE)); \
		if ! ps -p $$stored_pid -o command= 2>/dev/null | grep -q "lunet-run"; then \
			echo "ERROR: PID $$stored_pid does not appear to be lunet-run. Refusing to kill (stale PID file?)."; \
			rm -f $(PID_FILE); \
			exit 1; \
		fi; \
		kill $$stored_pid; \
		while kill -0 $$stored_pid 2>/dev/null; do sleep 1; done; \
		rm -f $(PID_FILE); \
		echo "Server stopped."; \
	else \
		rm -f $(PID_FILE); \
		echo "Server is not running."; \
	fi

restart: stop start

status:
	@if [ -f $(PID_FILE) ] && kill -0 $$(cat $(PID_FILE)) 2>/dev/null; then \
		echo "Server is running (PID $$(cat $(PID_FILE)))."; \
	else \
		echo "Server is not running."; \
	fi

lint:
	@echo "Running lua-language-server..."
	@mise exec -- lua-language-server --check . --checklevel=Warning

test: start
	@echo "Running chassis auth/profile compatibility tests with Hurl..."
	@HOST=http://127.0.0.1:$${LUNET_PORT:-8081} bash specs/run-chassis-tests-hurl.sh

load-test: start
	@HOST=http://127.0.0.1:$${LUNET_PORT:-8081} sh specs/run-load-tests.sh

# --- Automated e2e (ephemeral Postgres 16 + MinIO on colima/docker) ---------
# Pull-only multi-arch images (amd64 + arm64), no mounts, no BuildKit; high loopback ports so
# nothing collides with dev services. See e2e/docker-compose.yml + e2e/run-e2e.sh.
e2e:
	@bash e2e/run-e2e.sh

e2e-up:
	@docker compose -f e2e/docker-compose.yml up -d --wait postgres minio
	@docker compose -f e2e/docker-compose.yml run --rm minio-init
	@echo "e2e stack up: PG 127.0.0.1:55432, MinIO API 127.0.0.1:19000, console 127.0.0.1:19001"

e2e-down:
	@docker compose -f e2e/docker-compose.yml down --remove-orphans
	@echo "e2e stack down."

docker-smoke:
	@bash e2e/docker-smoke.sh

db-reset:
	@. ./.env; \
	PGPASSWORD=$$PGPASSWORD psql -h $$PGHOST -p $$PGPORT -U $$PGUSER -d $$PGDATABASE \
		-v ON_ERROR_STOP=1 -q \
		-c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" \
		-f sql/schema.sql \
		-f sql/auth_schema.sql \
		-f sql/dav_schema.sql \
	&& echo "Database reset."

clean:
	@if [ -f $(PID_FILE) ]; then \
		echo "ERROR: server appears to be running ($(PID_FILE) exists). Run 'make stop' first."; \
		exit 1; \
	fi
	@find target -mindepth 1 ! -name .keep -delete
	@echo "Cleaned target/."

help:
	@echo "Available targets:"
	@echo ""
	@echo "  make init     - Check dependencies and initialize the database"
	@echo "  make lint     - Run lua-language-server static analysis"
	@echo "  make start    - Start the lunet server on port 8081"
	@echo "  make stop     - Stop the lunet server"
	@echo "  make restart  - Restart the lunet server"
	@echo "  make status   - Show server status (running/stopped)"
	@echo "  make test     - Run chassis auth/profile compatibility tests with Hurl"
	@echo "  make e2e      - Full automated e2e: ephemeral PG16+MinIO (docker compose),"
	@echo "                  schema, server, all hurl compat suites"
	@echo "  make e2e-up   - Start just the e2e infra (PG 55432, MinIO 19000/19001)"
	@echo "  make e2e-down - Tear down the e2e infra"
	@echo "  make docker-smoke - Build Docker image and run smoke test"
	@echo "  make load-test - Run read-dominated load test with hey (concurrency 1 -> 64)"
	@echo "  make db-reset - Drop and recreate the database schema"
	@echo "  make clean    - Remove runtime files in target/ (server must be stopped)"
	@echo "  make all      - Run init, lint, start, and test (default)"
	@echo "  make help     - Show this help message"
	@echo ""

.PHONY: all init lint start stop restart status test load-test e2e e2e-up e2e-down docker-smoke db-reset clean help
