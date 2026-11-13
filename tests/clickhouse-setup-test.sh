#!/bin/bash
# clickhouse-setup.sh on a deployment as main ships it: the dry run changes nothing, the run gives a compose file that
# validates with the clickhouse service and the app's settings, a second run changes nothing, and the shipped
# service fragment is the one in this repo's docker-compose.yml.
#   tests/clickhouse-setup-test.sh [git ref of the existing deployment, default origin/main]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REF=${1:-origin/main}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PASS=0
FAILED=0

check() {
    local name=$1; shift
    if "$@" >/dev/null 2>&1; then echo "  ok   $name"; PASS=$((PASS + 1)); else echo "  FAIL $name"; FAILED=$((FAILED + 1)); fi
}
compose_config() { (cd "$WORK/deploy" && docker compose config "$@"); }

# A deployment folder as $REF ships it, with this branch's setup script and fragment beside it.
mkdir -p "$WORK/deploy/clickhouse"
git -C "$ROOT" show "$REF:docker-compose.yml" > "$WORK/deploy/docker-compose.yml"
git -C "$ROOT" show "$REF:.env" > "$WORK/deploy/.env"
printf 'DB_USER=cloudpi\nDB_PASSWORD=not-a-real-password\n' > "$WORK/deploy/cloudpi.secrets"
cp "$ROOT/clickhouse-setup.sh" "$WORK/deploy/"
cp "$ROOT/clickhouse/compose-service.yml" "$WORK/deploy/clickhouse/"
TAG=Cloudpi_ch_test-1

echo "clickhouse-setup.sh on the deployment of $REF"
before=$(sha256sum "$WORK/deploy/docker-compose.yml" "$WORK/deploy/.env" "$WORK/deploy/cloudpi.secrets")
"$WORK/deploy/clickhouse-setup.sh" --ch-tag "$TAG" --dry-run > "$WORK/dry.out"
check "the dry run changes no file" test "$before" = "$(sha256sum "$WORK/deploy/docker-compose.yml" "$WORK/deploy/.env" "$WORK/deploy/cloudpi.secrets")"
check "the dry run shows the clickhouse service" grep -q '^+  clickhouse:' "$WORK/dry.out"
check "the dry run never prints a password" bash -c "! grep -qE 'CH_PASSWORD=[A-Za-z0-9]{32}' '$WORK/dry.out'"

"$WORK/deploy/clickhouse-setup.sh" --ch-tag "$TAG" > "$WORK/run.out"
config=$(compose_config)
check "the edited compose file validates" compose_config --quiet
check "the clickhouse service runs the given tag" grep -q "image: cloudpi1/cloudpi:$TAG" <<<"$config"
check "the app waits for a healthy clickhouse" python3 -c "
import sys, yaml
c = yaml.safe_load(sys.stdin)
assert c['services']['app']['depends_on']['clickhouse']['condition'] == 'service_healthy'
assert c['services']['app']['depends_on']['db']['condition'] == 'service_healthy'
" <<<"$config"
check "the app gets the ClickHouse settings, on MySQL alone" python3 -c "
import sys, yaml
e = yaml.safe_load(sys.stdin)['services']['app']['environment']
assert (e['DB_WRITE'], e['DB_READ'], e['CH_HOST'], e['CH_PORT'], e['CH_SECURE']) == ('mysql', 'mysql', 'cloudpi-clickhouse', '8443', 'true')
assert e['CH_CA_CERT'] == '/etc/clickhouse-ca/ca.crt' and 'NODE_EXTRA_CA_CERTS' not in e and e['HOST']
" <<<"$config"
check "the app mounts the CA read-only and keeps its volumes" python3 -c "
import sys, yaml
v = yaml.safe_load(sys.stdin)['services']['app']['volumes']
targets = {x['target']: x.get('read_only', False) for x in v}
assert targets['/etc/clickhouse-ca'] is True and '/app/backups' in targets and '/var/lib/redis' in targets
" <<<"$config"
check "the four clickhouse volumes are declared" python3 -c "
import sys, yaml
v = yaml.safe_load(sys.stdin)['volumes']
assert all(n in v for n in ['clickhouse_data', 'clickhouse_logs', 'clickhouse_tls', 'clickhouse_ca'])
" <<<"$config"
check ".env names the tag and keeps MySQL alone" grep -qx "CH_IMAGE_TAG=$TAG" "$WORK/deploy/.env"
check "a 32-character ClickHouse password is generated" grep -qE '^CH_PASSWORD=[A-Za-z0-9]{32}$' "$WORK/deploy/cloudpi.secrets"
check "the run prints no password" bash -c "! grep -qE 'CH_PASSWORD=' '$WORK/run.out'"
check "the originals are backed up" bash -c "ls '$WORK/deploy'/docker-compose.yml.pre-clickhouse.* '$WORK/deploy'/.env.pre-clickhouse.*"

after=$(sha256sum "$WORK/deploy/docker-compose.yml" "$WORK/deploy/.env" "$WORK/deploy/cloudpi.secrets")
"$WORK/deploy/clickhouse-setup.sh" --ch-tag "$TAG" > /dev/null
check "a second run changes nothing" test "$after" = "$(sha256sum "$WORK/deploy/docker-compose.yml" "$WORK/deploy/.env" "$WORK/deploy/cloudpi.secrets")"

check "the shipped fragment is the clickhouse service of this repo's docker-compose.yml" diff \
    <(awk '/^  clickhouse:/{p=1} p&&/^  app:/{exit} p' "$ROOT/docker-compose.yml" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}') \
    "$ROOT/clickhouse/compose-service.yml"

echo "$PASS passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
