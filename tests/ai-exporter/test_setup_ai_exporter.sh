#!/usr/bin/env bash
# =============================================================================
# Tests for setup-ai-exporter.sh. They run the real script against a fake `aws` and `curl` (tests/ai-exporter/
# fakebin), so nothing real is downloaded or changed. Run:  bash tests/ai-exporter/test_setup_ai_exporter.sh
# =============================================================================
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../../setup-ai-exporter.sh"
ANT_KEY="sk-ant-admin01-test-only-not-a-real-key"
OAI_KEY="sk-admin-test-only-not-a-real-key"
PASS=0 FAIL=0 FAILED=()

sha() { sha256sum "$1" | cut -d' ' -f1; }

make_release() {  # make_release <tag> <version> [zip content]
  local dir="$FAKE_RELEASE_DIR/$1" zip="ai-exporter-$2.zip"
  mkdir -p "$dir"
  printf '%s' "${3:-zip bytes of $2}" > "$dir/$zip"
  printf 'AWSTemplateFormatVersion: "2010-09-09"\n# version %s\n' "$2" > "$dir/ai-exporter-template.yaml"
  cat > "$dir/ai-exporter-manifest.json" <<EOF
{"tag": "$1", "version": "$2", "zip_file": "$zip", "zip_sha256": "$(sha "$dir/$zip")",
 "template_file": "ai-exporter-template.yaml", "template_sha256": "$(sha "$dir/ai-exporter-template.yaml")"}
EOF
}

setup_env() {
  T="$(mktemp -d)"
  export FAKE_AWS_LOG="$T/aws.log" FAKE_AWS_DIR="$T/aws" FAKE_RELEASE_DIR="$T/releases"
  export AI_EXPORTER_RELEASE_BASE="https://example.invalid/releases/download" AI_EXPORTER_DIR="$T/work"
  export AI_EXPORTER_STATE="$T/state" AWS_REGION="us-east-1" PATH="$HERE/fakebin:$PATH"
  export ANTHROPIC_ADMIN_KEY="$ANT_KEY" OPENAI_ADMIN_KEY="$OAI_KEY"
  mkdir -p "$FAKE_AWS_DIR" && : > "$FAKE_AWS_LOG"
  make_release ai-exporter-1.0.0 1.0.0
}

run() { OUT="$("$SCRIPT" "$@" < /dev/null 2>&1)"; CODE=$?; }
install_ok() { run install --release ai-exporter-1.0.0 --org-id 44 "$@"; }
log_has() { grep -qF -- "$1" "$FAKE_AWS_LOG"; }
expect() {  # expect <what> [!] <command...>: a leading ! means the command must fail
  local what="$1" negate=false ok=false; shift
  if [ "${1:-}" = "!" ]; then negate=true; shift; fi
  if "$@"; then ok=true; fi
  if [ "$ok" != "$negate" ]; then return 0; fi
  echo "    expected: $what"; return 1
}

t_help() { run --help; expect "exit 0" [ "$CODE" -eq 0 ] && expect "usage" grep -q "install" <<< "$OUT"; }

t_unknown_command() { run explode; expect "exit 2" [ "$CODE" -eq 2 ]; }

t_install_needs_release_and_org() {
  run install --org-id 44; expect "fails without --release" [ "$CODE" -ne 0 ] && expect "names --release" grep -q -- "--release" <<< "$OUT" &&
  run install --release ai-exporter-1.0.0; expect "fails without --org-id" [ "$CODE" -ne 0 ] && expect "names --org-id" grep -q -- "--org-id" <<< "$OUT"
}

t_bad_tag_refused() { run install --release "../x" --org-id 44; expect "refused" [ "$CODE" -ne 0 ] && expect "message" grep -q "not a valid tag" <<< "$OUT"; }

t_damaged_zip_refused() {
  printf 'tampered' > "$FAKE_RELEASE_DIR/ai-exporter-1.0.0/ai-exporter-1.0.0.zip"
  install_ok
  expect "refused" [ "$CODE" -ne 0 ] && expect "says damaged" grep -q "damaged" <<< "$OUT" &&
  expect "nothing deployed" ! log_has "cloudformation deploy" && expect "nothing uploaded" ! log_has "s3 cp"
}

t_install_deploys_and_stores_keys() {
  install_ok --backfill-months 3
  local zsha; zsha="$(sha "$FAKE_RELEASE_DIR/ai-exporter-1.0.0/ai-exporter-1.0.0.zip")"
  expect "exit 0 ($OUT)" [ "$CODE" -eq 0 ] &&
  expect "code bucket created" log_has "s3api create-bucket --bucket cloudpi-ai-exporter-code-123456789012-us-east-1" &&
  expect "zip uploaded under its sha" log_has "s3://cloudpi-ai-exporter-code-123456789012-us-east-1/ai-exporter/bundle-$zsha.zip" &&
  expect "stack deployed" log_has "cloudformation deploy --template-file" &&
  expect "stack name" log_has "--stack-name cloudpi-ai-exporter" &&
  expect "IAM capability" log_has "--capabilities CAPABILITY_IAM" &&
  expect "parameters" log_has "OrgId=44" && log_has "CodeKey=ai-exporter/bundle-$zsha.zip" &&
  log_has "EnableAnthropic=true" && log_has "EnableOpenAI=true" && log_has "BackfillMonths=3" &&
  expect "anthropic key stored" [ "$(cat "$FAKE_AWS_DIR/secret-anthropic-AbCdEf")" = "$ANT_KEY" ] &&
  expect "openai key stored" [ "$(cat "$FAKE_AWS_DIR/secret-openai-GhIjKl")" = "$OAI_KEY" ] &&
  expect "keys passed as files" log_has "--secret-string file://" &&
  expect "dry run of the plan" log_has '{"mode": "plan", "dry_run": true}' &&
  expect "tasks shown" grep -q "anthropic" <<< "$OUT"
}

t_keys_never_appear_in_output_logs_or_state() {
  install_ok
  expect "not in output" ! grep -qF "$ANT_KEY" <<< "$OUT" && expect "not in output" ! grep -qF "$OAI_KEY" <<< "$OUT" &&
  expect "not on any aws command line" ! log_has "$ANT_KEY" && expect "not on any aws command line" ! log_has "$OAI_KEY" &&
  expect "not in the state file" ! grep -qF "sk-" "$AI_EXPORTER_STATE" &&
  expect "temp key files removed" [ -z "$(find "$T" -name 'ai-exporter-key.*' 2>/dev/null)" ]
}

t_state_file_remembers_the_install() {
  install_ok
  expect "release" grep -q "^RELEASE=ai-exporter-1.0.0$" "$AI_EXPORTER_STATE" &&
  expect "stack" grep -q "^STACK=cloudpi-ai-exporter$" "$AI_EXPORTER_STATE" &&
  expect "region" grep -q "^REGION=us-east-1$" "$AI_EXPORTER_STATE"
}

t_openai_only() {
  unset ANTHROPIC_ADMIN_KEY
  touch "$FAKE_AWS_DIR/no-anthropic"
  install_ok --providers openai
  expect "exit 0 ($OUT)" [ "$CODE" -eq 0 ] && expect "anthropic off" log_has "EnableAnthropic=false" &&
  expect "openai on" log_has "EnableOpenAI=true" && expect "no anthropic secret" [ ! -f "$FAKE_AWS_DIR/secret-anthropic-AbCdEf" ]
}

t_bad_providers_refused() { install_ok --providers bedrock; expect "refused" [ "$CODE" -ne 0 ] && expect "message" grep -q "providers" <<< "$OUT"; }

t_missing_key_without_a_terminal_stops_before_deploying() {
  unset OPENAI_ADMIN_KEY
  install_ok
  expect "refused" [ "$CODE" -ne 0 ] && expect "names the variable" grep -q "OPENAI_ADMIN_KEY" <<< "$OUT" &&
  expect "nothing deployed" ! log_has "cloudformation deploy"
}

t_cloudpi_account_needs_external_id() {
  install_ok --cloudpi-account-id 210987654321
  expect "refused" [ "$CODE" -ne 0 ] && expect "message" grep -q -- "--cloudpi-external-id" <<< "$OUT"
}

t_cloudpi_external_id_is_masked_in_dry_run() {
  install_ok --cloudpi-account-id 210987654321 --cloudpi-external-id ext-secret-123 --dry-run
  expect "exit 0 ($OUT)" [ "$CODE" -eq 0 ] && expect "masked" ! grep -qF "ext-secret-123" <<< "$OUT"
}

t_dry_run_changes_nothing() {
  install_ok --dry-run
  expect "exit 0 ($OUT)" [ "$CODE" -eq 0 ] && expect "shows the deploy" grep -q "(dry run) aws cloudformation deploy" <<< "$OUT" &&
  expect "no deploy ran" ! log_has "cloudformation deploy" && expect "no upload ran" ! log_has "s3 cp" &&
  expect "no secrets stored" [ -z "$(ls "$FAKE_AWS_DIR" | grep secret-)" ] && expect "no state saved" [ ! -f "$AI_EXPORTER_STATE" ]
}

t_upgrade_deploys_the_new_zip_and_keeps_settings() {
  install_ok; : > "$FAKE_AWS_LOG"
  make_release ai-exporter-1.1.0 1.1.0
  run upgrade ai-exporter-1.1.0
  local zsha; zsha="$(sha "$FAKE_RELEASE_DIR/ai-exporter-1.1.0/ai-exporter-1.1.0.zip")"
  expect "exit 0 ($OUT)" [ "$CODE" -eq 0 ] && expect "new code key" log_has "CodeKey=ai-exporter/bundle-$zsha.zip" &&
  expect "other settings untouched (kept by CloudFormation)" ! log_has "OrgId=" &&
  expect "keys not asked again" ! log_has "put-secret-value" &&
  expect "state updated" grep -q "^RELEASE=ai-exporter-1.1.0$" "$AI_EXPORTER_STATE"
}

t_upgrade_needs_an_install() { run upgrade ai-exporter-1.0.0; expect "refused" [ "$CODE" -ne 0 ] && expect "message" grep -q "install" <<< "$OUT"; }

t_set_key_rotates_one_key() {
  install_ok; export OPENAI_ADMIN_KEY="sk-admin-rotated-test-key"
  run set-key openai
  expect "exit 0 ($OUT)" [ "$CODE" -eq 0 ] && expect "stored" [ "$(cat "$FAKE_AWS_DIR/secret-openai-GhIjKl")" = "sk-admin-rotated-test-key" ]
}

t_run_now_starts_a_plan_without_waiting() {
  install_ok; : > "$FAKE_AWS_LOG"
  run run-now
  expect "exit 0 ($OUT)" [ "$CODE" -eq 0 ] && expect "async invoke" log_has "--invocation-type Event" && expect "plan" log_has '{"mode": "plan"}'
}

t_status_shows_stack_and_latest_run() {
  install_ok
  run status
  expect "exit 0 ($OUT)" [ "$CODE" -eq 0 ] && expect "stack status" grep -q "CREATE_COMPLETE" <<< "$OUT" &&
  expect "latest run log" grep -q '"provider": "openai"' <<< "$OUT"
}

t_uninstall_asks_and_keeps_data_by_default() {
  install_ok; : > "$FAKE_AWS_LOG"
  run uninstall
  expect "refuses without a terminal or --yes" [ "$CODE" -ne 0 ] && expect "nothing deleted" ! log_has "delete-stack" &&
  run uninstall --yes
  expect "exit 0 ($OUT)" [ "$CODE" -eq 0 ] && expect "stack deleted" log_has "cloudformation delete-stack --stack-name cloudpi-ai-exporter" &&
  expect "data kept" ! log_has "s3 rm"
}

t_uninstall_delete_data_removes_the_bucket() {
  install_ok
  run uninstall --yes --delete-data
  expect "exit 0 ($OUT)" [ "$CODE" -eq 0 ] && expect "files removed" log_has "s3 rm s3://cloudpi-ai-focus-123456789012-us-east-1 --recursive" &&
  expect "bucket removed" log_has "s3api delete-bucket --bucket cloudpi-ai-focus-123456789012-us-east-1"
}

TESTS=$(declare -F | awk '{print $3}' | grep '^t_')
for t in $TESTS; do
  if ( setup_env; "$t" ); then PASS=$((PASS + 1)); echo "ok   $t"; else FAIL=$((FAIL + 1)); FAILED+=("$t"); echo "FAIL $t"; fi
done
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
