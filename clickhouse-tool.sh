#!/bin/bash
# Runs one of the app's ClickHouse tools inside the app container with the API's own environment (its database and
# ClickHouse settings come from cloudpi.secrets through pm2, so a plain `docker exec node` would not see them).
#   ./clickhouse-tool.sh copy plan|run|verify|status [--tables a,b]
#   ./clickhouse-tool.sh migrate
#   ./clickhouse-tool.sh fix-drift --table <table> --ids 1,2,3
#   ./clickhouse-tool.sh removal-gate --run-id <id> --baseline <file> --candidate <file> --log <file> --since <time>
# removal-gate reads its files inside the app container: copy them there first (docker cp).
set -euo pipefail

APP=${CLICKHOUSE_TOOL_APP:-cloudpi-app}
BACKEND=${CLICKHOUSE_TOOL_BACKEND:-/app/backend}
TOOL_ENV_FILE=/tmp/clickhouse-tool.env
declare -A TOOL_MODULES=(
    [copy]=dist/migration/clickhouse/copy/copy.js
    [migrate]=dist/migration/clickhouse/migrate.js
    [fix-drift]=dist/migration/clickhouse/fixDrift.js
    [removal-gate]=dist/migration/clickhouse/removalGate.js
)

tool_log() { echo "[clickhouse-tool] $*"; }
tool_fail() { echo "[clickhouse-tool] ERROR: $*" >&2; exit 1; }

# Saves the running API's environment inside the container, readable by its owner only.
capture_api_env() {
    [ "$(docker inspect -f '{{.State.Running}}' "$APP" 2>/dev/null)" = "true" ] || tool_fail "container $APP is not running"
    local api_pid
    api_pid=$(docker exec "$APP" pm2 pid CloudPi-Node-API | tr -dc '0-9')
    [ -n "$api_pid" ] && [ "$api_pid" != "0" ] || tool_fail "CloudPi-Node-API is not running in $APP; its environment is needed"
    docker exec "$APP" sh -c "umask 077; cat /proc/$api_pid/environ > $TOOL_ENV_FILE"
}

forget_api_env() {
    docker exec "$APP" rm -f "$TOOL_ENV_FILE" >/dev/null 2>&1 || true
}

# One setting of the saved API environment, e.g. api_setting DB_WRITE.
api_setting() {
    docker exec "$APP" sh -c "tr '\0' '\n' < $TOOL_ENV_FILE | sed -n 's/^$1=//p'"
}

# Runs a compiled app tool module with the saved environment and returns its exit code.
run_tool() {
    local module=$1; shift
    docker exec -e TOOL_ENV_FILE="$TOOL_ENV_FILE" -w "$BACKEND" "$APP" node -e '
      const fs = require("fs");
      for (const pair of fs.readFileSync(process.env.TOOL_ENV_FILE, "utf8").split("\0")) {
        const i = pair.indexOf("=");
        if (i > 0) process.env[pair.slice(0, i)] = pair.slice(i + 1);
      }
      require(require("path").resolve(process.argv[1])).main(process.argv.slice(2)).then((code) => process.exit(code));
    ' -- "$module" "$@"
}

tool_main() {
    local name=${1:-}
    [ -n "$name" ] && [ -n "${TOOL_MODULES[$name]:-}" ] || tool_fail "usage: $0 copy|migrate|fix-drift|removal-gate [args]"
    shift
    capture_api_env
    trap forget_api_env EXIT
    run_tool "${TOOL_MODULES[$name]}" "$@"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    tool_main "$@"
fi
