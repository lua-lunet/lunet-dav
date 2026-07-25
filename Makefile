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
	@echo "Initializing database..."
	@. ./.env; \
	echo "  Connecting to PostgreSQL at $$PGHOST:$$PGPORT, database: $$PGDATABASE, user: $$PGUSER"; \
	PGPASSWORD=$$PGPASSWORD psql -h $$PGHOST -p $$PGPORT -U $$PGUSER -d $$PGDATABASE \
		-f sql/schema.sql \
		-f sql/auth_schema.sql \
		-f sql/dav_schema.sql >/dev/null 2>&1 \
		|| echo "  WARNING: Could not initialize database. Using existing database."
	@echo "Init complete."

start:
	@if [ -f $(PID_FILE) ] && kill -0 $$(cat $(PID_FILE)) 2>/dev/null; then \
		echo "Server already running (PID $$(cat $(PID_FILE)))."; \
	else \
		mkdir -p target; \
		set -a; . ./.env; set +a; \
		nohup ./bin/lunet-run server.lua > target/server.log 2>&1 & \
		sleep 1; \
		curl -fsS http://127.0.0.1:$${LUNET_PORT:-8081}/health >/dev/null \
			|| { echo "ERROR: server failed to start. See target/server.log"; exit 1; }; \
		lsof -nP -tiTCP:$${LUNET_PORT:-8081} -sTCP:LISTEN > $(PID_FILE); \
		echo "Server started on port $${LUNET_PORT:-8081} (PID $$(cat $(PID_FILE)))."; \
	fi

stop:
	@if [ -f $(PID_FILE) ] && kill -0 $$(cat $(PID_FILE)) 2>/dev/null; then \
		kill $$(cat $(PID_FILE)); \
		while kill -0 $$(cat $(PID_FILE)) 2>/dev/null; do sleep 1; done; \
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
	@HOST=http://127.0.0.1:8081 bash specs/run-chassis-tests-hurl.sh

load-test: start
	@HOST=http://127.0.0.1:8081 sh specs/run-load-tests.sh

# --- Automated e2e (ephemeral Postgres 16 + MinIO on colima/docker) ---------
# Pull-only linux/arm64 images, no mounts, no BuildKit; high loopback ports so
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
	@echo "                  schema, server, all hurl compat suites, litmus WebDAV suite"
	@echo "  make e2e-up   - Start just the e2e infra (PG 55432, MinIO 19000/19001)"
	@echo "  make e2e-down - Tear down the e2e infra"
	@echo "  make load-test - Run read-dominated load test with hey (concurrency 1 -> 64)"
	@echo "  make db-reset - Drop and recreate the database schema"
	@echo "  make clean    - Remove runtime files in target/ (server must be stopped)"
	@echo "  make all      - Run init, lint, start, and test (default)"
	@echo "  make help     - Show this help message"
	@echo ""

.PHONY: all init lint start stop restart status test load-test e2e e2e-up e2e-down db-reset clean help
