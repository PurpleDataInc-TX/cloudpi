#!/bin/bash
# Fills ClickHouse from MySQL once, on an install that already has data, before DB_WRITE=dual is turned on.
# Runs the app's own tools inside the app container (clickhouse-tool.sh): the ClickHouse migrations, the plan (which
# stops on any column that differs between the engines), then the copy (every table into a
# staging table, verified chunk by chunk, swapped in whole), then the parity check, which must find 0 differing
# tables. The API, the worker and Flask are stopped for the whole run so nothing writes while it copies, and are
# started again however it ends.
#   ./clickhouse-first-load.sh            shows the plan and asks before stopping anything
#   ./clickhouse-first-load.sh --yes      runs without asking
set -euo pipefail

CH=cloudpi-clickhouse
WRITERS=(CloudPi-Node-API CloudPi-Node-Worker CloudPi-Flask-API CloudPi-Flask-Worker)
# shellcheck source=clickhouse-tool.sh
. "$(dirname "$0")/clickhouse-tool.sh"

log() { echo "[first-load] $*"; }
fail() { echo "[first-load] ERROR: $*" >&2; exit 1; }

restart_writers() {
    log "starting ${WRITERS[*]} again"
    docker exec "$APP" pm2 start "${WRITERS[@]}" >/dev/null || log "WARNING: could not start them; run: docker exec $APP pm2 start ${WRITERS[*]}"
    forget_api_env
}

[ "${1:-}" = "--yes" ] || [ $# -eq 0 ] || fail "usage: $0 [--yes]"
[ "$(docker inspect -f '{{.State.Running}}' "$CH" 2>/dev/null)" = "true" ] || fail "container $CH is not running"

capture_api_env
write_mode=$(api_setting DB_WRITE)
if [ "${write_mode:-mysql}" != "mysql" ]; then
    forget_api_env
    fail "DB_WRITE is '${write_mode}'. The first load runs only while DB_WRITE=mysql, before ClickHouse is written."
fi

log "ClickHouse migrations (nothing writes to ClickHouse while DB_WRITE=mysql)"
run_tool dist/migration/clickhouse/migrate.js || { forget_api_env; fail "ClickHouse migrations failed"; }

log "the plan (nothing is copied yet):"
run_tool dist/migration/clickhouse/copy/copy.js plan || { forget_api_env; fail "the plan found differences; fix them, then run this script again"; }

if [ "${1:-}" != "--yes" ]; then
    read -r -p "Stop ${WRITERS[*]} and copy every table now? [y/N] " answer
    [ "$answer" = "y" ] || [ "$answer" = "Y" ] || { forget_api_env; log "nothing changed"; exit 0; }
fi

log "stopping ${WRITERS[*]} so nothing writes during the copy"
docker exec "$APP" pm2 stop "${WRITERS[@]}" >/dev/null
trap restart_writers EXIT

log "1/3 copy every table"
run_tool dist/migration/clickhouse/copy/copy.js run || fail "the copy failed; run this script again, it continues where it stopped"
log "2/3 parity: every table on both engines"
run_tool dist/migration/clickhouse/copy/copy.js verify || fail "ClickHouse differs from MySQL; do not turn on DB_WRITE=dual"
log "3/3 the copy is marked done"
run_tool dist/migration/clickhouse/copy/copy.js status || fail "the copy is not marked done"

log "ClickHouse now equals MySQL. Next: set DB_WRITE=dual and DB_READ=compare in .env, then docker-compose up -d app"
