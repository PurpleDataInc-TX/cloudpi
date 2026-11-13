#!/bin/bash
# Adds the ClickHouse container to an existing CloudPi deployment: the clickhouse service and its volumes in
# docker-compose.yml, the app's settings to reach it, the .env keys and the ClickHouse user in cloudpi.secrets.
# The app keeps running on MySQL alone (DB_WRITE=mysql, DB_READ=mysql) until the first load and the mode switch.
#   ./clickhouse-setup.sh --ch-tag Cloudpi_ch_<x>               edit the deployment in this folder
#   ./clickhouse-setup.sh --ch-tag Cloudpi_ch_<x> --dry-run     show what would change, change nothing
#   ./clickhouse-setup.sh --ch-tag Cloudpi_ch_<x> --start       also pull and start the clickhouse container
#   --dir <folder> the deployment folder (default: this script's folder); --secrets <file> (default: cloudpi.secrets; a relative name is taken inside --dir)
# Safe to run again: whatever is already there is left as it is.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_DIR=$SCRIPT_DIR
SECRETS_NAME=cloudpi.secrets
CH_TAG=""
DRY_RUN=false
START=false
FRAGMENT="$SCRIPT_DIR/clickhouse/compose-service.yml"

log() { echo "[clickhouse-setup] $*"; }
fail() { echo "[clickhouse-setup] ERROR: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --ch-tag) CH_TAG=${2:-}; shift 2 ;;
        --dir) DEPLOY_DIR=${2:-}; shift 2 ;;
        --secrets) SECRETS_NAME=${2:-}; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --start) START=true; shift ;;
        *) fail "unknown argument '$1'; see the top of this script for usage" ;;
    esac
done

[[ "$CH_TAG" =~ ^Cloudpi_ch_[A-Za-z0-9._-]+$ ]] || fail "--ch-tag must be the Cloudpi_ch_* tag built with your db image"
COMPOSE="$DEPLOY_DIR/docker-compose.yml"
ENV_FILE="$DEPLOY_DIR/.env"
case $SECRETS_NAME in /*) SECRETS=$SECRETS_NAME ;; *) SECRETS="$DEPLOY_DIR/$SECRETS_NAME" ;; esac
for f in "$COMPOSE" "$ENV_FILE" "$SECRETS" "$FRAGMENT"; do [ -f "$f" ] || fail "$f not found"; done
command -v python3 >/dev/null || fail "python3 is needed to edit docker-compose.yml"
if docker compose version >/dev/null 2>&1; then compose() { docker compose "$@"; }
elif command -v docker-compose >/dev/null; then compose() { docker-compose "$@"; }
else fail "neither 'docker compose' nor 'docker-compose' is installed"; fi

# The compose file with the clickhouse service, the app's ClickHouse settings and the volumes added; prints it.
edited_compose() {
    python3 - "$COMPOSE" "$FRAGMENT" <<'PY'
import re, sys

lines = open(sys.argv[1]).read().split('\n')
fragment = open(sys.argv[2]).read().rstrip('\n').split('\n')

def block_end(start, indent):
    """Index after the block that starts at `start`: the first later line indented `indent` or less."""
    i = start + 1
    while i < len(lines) and (lines[i].strip() == '' or len(lines[i]) - len(lines[i].lstrip()) > indent):
        i += 1
    while i > start + 1 and lines[i - 1].strip() == '':
        i -= 1
    return i

def find(pattern, lo=0, hi=None):
    hi = len(lines) if hi is None else hi
    return next((i for i in range(lo, hi) if re.match(pattern, lines[i])), None)

def fail(message):
    sys.stderr.write(f'docker-compose.yml: {message}; add the ClickHouse parts by hand (see README.md, "ClickHouse")\n')
    sys.exit(3)

app = find(r'^  app:\s*$')
if app is None:
    fail('no app service')
if find(r'^  clickhouse:\s*$') is None:
    lines[app:app] = fragment + ['']
    app = find(r'^  app:\s*$')
app_end = block_end(app, 2)

def ensure_in_section(section, groups):
    """Appends to a section of the app service each (marker, lines) group whose marker regex it lacks."""
    global app_end
    head = find(rf'^    {section}:\s*$', app, app_end)
    if head is None:
        lines[app_end:app_end] = [f'    {section}:'] + [l for _, group in groups for l in group]
        app_end = block_end(app, 2)
        return
    end = block_end(head, 4)
    text = '\n'.join(lines[head:end])
    missing = [l for marker, group in groups if not re.search(marker, text, re.M) for l in group]
    lines[end:end] = missing
    app_end = block_end(app, 2)

ensure_in_section('depends_on', [(r'^      clickhouse:', ['      clickhouse:', '        condition: service_healthy'])])
environment = [
    ('DB_WRITE', '${DB_WRITE:-mysql}'), ('DB_READ', '${DB_READ:-mysql}'), ('CH_HOST', 'cloudpi-clickhouse'),
    ('CH_PORT', '"8443"'), ('CH_SECURE', '"true"'), ('CH_CA_CERT', '/etc/clickhouse-ca/ca.crt'),
]
env_head = find(r'^    environment:\s*$', app, app_end)
# The app's environment may be a mapping (KEY: value) or a list (- KEY=value); new keys follow its form.
is_list = env_head is not None and lines[env_head + 1].strip().startswith('- ')
ensure_in_section('environment', [
    (rf'^      (- )?{key}[:=]', [f'      - {key}={value.strip(chr(34))}' if is_list else f'      {key}: {value}'])
    for key, value in environment
])
ensure_in_section('volumes', [(r'clickhouse_ca:', ['      - clickhouse_ca:/etc/clickhouse-ca:ro'])])

top = find(r'^volumes:\s*$')
if top is None:
    fail('no top-level volumes section')
end = block_end(top, 0)
text = '\n'.join(lines[top:end])
for name in ['clickhouse_data', 'clickhouse_logs', 'clickhouse_tls', 'clickhouse_ca']:
    if not re.search(rf'^  {name}:', text, re.M):
        lines[end:end] = [f'  {name}:', '    driver: local']
        end += 2
sys.stdout.write('\n'.join(lines))
PY
}

# KEY=value lines a file lacks, for the keys it does not set yet.
missing_lines() {
    local file=$1; shift
    local pair
    for pair in "$@"; do grep -qE "^${pair%%=*}=" "$file" || echo "$pair"; done
}

new_compose=$(mktemp)
trap 'rm -f "$new_compose"' EXIT
edited_compose > "$new_compose"
env_lines=$(missing_lines "$ENV_FILE" "CH_IMAGE_TAG=$CH_TAG" DB_WRITE=mysql DB_READ=mysql CH_MEMORY=4G CH_CPUS=2)
secret_lines=$(missing_lines "$SECRETS" CH_USER=cloudpi_app CH_PASSWORD=generated)

if $DRY_RUN; then
    log "docker-compose.yml changes:"; diff -u "$COMPOSE" "$new_compose" || true
    log ".env lines to add:"; echo "${env_lines:-  (none)}"
    log "$SECRETS_NAME lines to add (password generated, not shown):"; echo "${secret_lines:-  (none)}" | sed 's/=generated$/=<random>/'
    exit 0
fi

stamp=$(date +%Y%m%d-%H%M%S)
cp -p "$COMPOSE" "$COMPOSE.pre-clickhouse.$stamp"
cp -p "$ENV_FILE" "$ENV_FILE.pre-clickhouse.$stamp"
cp -p "$SECRETS" "$SECRETS.pre-clickhouse.$stamp"
log "backups: *.pre-clickhouse.$stamp"
restore() {
    cp -p "$COMPOSE.pre-clickhouse.$stamp" "$COMPOSE"; cp -p "$ENV_FILE.pre-clickhouse.$stamp" "$ENV_FILE"
    cp -p "$SECRETS.pre-clickhouse.$stamp" "$SECRETS"
    fail "$1; every file was put back as it was"
}

cat "$new_compose" > "$COMPOSE"
[ -z "$env_lines" ] || printf '\n# ClickHouse (clickhouse-setup.sh)\n%s\n' "$env_lines" >> "$ENV_FILE"
if [ -n "$secret_lines" ]; then
    password=$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)
    printf '\n# ClickHouse user of the app (clickhouse-setup.sh)\n%s\n' "${secret_lines/=generated/=$password}" >> "$SECRETS"
fi
(cd "$DEPLOY_DIR" && compose config --quiet) || restore "the edited docker-compose.yml does not validate"
log "docker-compose.yml, .env and $SECRETS_NAME updated; the app still runs on MySQL alone"

if $START; then
    (cd "$DEPLOY_DIR" && compose pull clickhouse && compose up -d clickhouse) || fail "could not start clickhouse"
    for _ in $(seq 1 60); do
        [ "$(docker inspect -f '{{.State.Health.Status}}' cloudpi-clickhouse 2>/dev/null)" = "healthy" ] && break
        sleep 5
    done
    [ "$(docker inspect -f '{{.State.Health.Status}}' cloudpi-clickhouse 2>/dev/null)" = "healthy" ] \
        || fail "cloudpi-clickhouse is not healthy after 5 minutes; see docker logs cloudpi-clickhouse"
    log "cloudpi-clickhouse is running and healthy"
fi

log "next: upgrade the app and db images to the ClickHouse build (./cp_upgrade.sh <app tag>), which also gives the"
log "app its ClickHouse settings; then ./clickhouse-first-load.sh; then DB_WRITE=dual and DB_READ=compare in .env."
