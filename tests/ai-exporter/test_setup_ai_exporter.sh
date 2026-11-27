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
  export TMPDIR="$T/tmp"  # so the temp-key check below looks where the script really writes
  mkdir -p "$FAKE_AWS_DIR" "$TMPDIR" && : > "$FAKE_AWS_LOG"
  make_release ai-exporter-1.0.0 1.0.0
}

run() { OUT="$("$SCRIPT" "$@" < /dev/null 2>&1)"; CODE=$?; }
install_ok() { run install --release ai-exporter-1.0.0 --org-id 44 "$@"; }
log_has() { grep -qF -- "$1" "$FAKE_AWS_LOG"; }
params_has() { [ -f "$FAKE_AWS_DIR/deploy-params.json" ] && grep -qF -- "\"$1" "$FAKE_AWS_DIR/deploy-params.json"; }
expect() {  # expect <what> [!] <command...>: a leading ! means the command must fail
  local what="$1" negate=false ok=false; shift
  if [ "${1:-}" = "!" ]; then negate=true; shift; fi
  if "$@"; then ok=true; fi
  if [ "$ok" != "$negate" ]; then return 0; fi
  echo "    expected: $what"; exit 1  # ends this test (each runs in its own subshell), even mid-chain
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
  expect "IAM capability" log_has "--capabilities CAPABILITY_NAMED_IAM" &&
  expect "parameters from a private file" log_has "--parameter-overrides file://" &&
  expect "parameters" params_has "OrgId=44" && params_has "CodeKey=ai-exporter/bundle-$zsha.zip" &&
  params_has "EnableAnthropic=true" && params_has "EnableOpenAI=true" && params_has "BackfillMonths=3" &&
  params_has "ScheduleExpression=cron(0 6 * * ? *)" &&
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
  expect "exit 0 ($OUT)" [ "$CODE" -eq 0 ] && expect "anthropic off" params_has "EnableAnthropic=false" &&
  expect "openai on" params_has "EnableOpenAI=true" && expect "no anthropic secret" [ ! -f "$FAKE_AWS_DIR/secret-anthropic-AbCdEf" ]
}

t_default_backfill_is_two_months() {  # spec 147 D-3: 3 months with the current one, like CloudPi onboarding
  install_ok
  expect "exit 0 ($OUT)" [ "$CODE" -eq 0 ] && expect "backfill 2" params_has "BackfillMonths=2" &&
  expect "requester mode full" params_has "RequesterMode=full"
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
  expect "no secrets stored" [ -z "$(ls "$FAKE_AWS_DIR" | grep secret-)" ] && expect "no state saved" [ ! -f "$AI_EXPORTER_STATE" ] &&
  expect "never claims a change" ! grep -qE "\] (code bucket .* created|.* key stored|installed\.)" <<< "$OUT" &&
  expect "says what it would do" grep -q "would create the code bucket" <<< "$OUT" && grep -q "would store the openai admin key" <<< "$OUT" &&
  expect "ends saying nothing changed" grep -q "dry run finished: nothing was changed" <<< "$OUT"
}

t_dry_run_upgrade_and_run_now_claim_nothing() {
  install_ok; : > "$FAKE_AWS_LOG"
  run upgrade ai-exporter-1.0.0 --dry-run
  expect "upgrade exit 0 ($OUT)" [ "$CODE" -eq 0 ] && expect "no 'upgraded' claim" ! grep -q "upgraded to" <<< "$OUT" &&
  expect "says nothing changed" grep -q "dry run finished: nothing was changed" <<< "$OUT" &&
  run run-now --dry-run
  expect "run-now exit 0 ($OUT)" [ "$CODE" -eq 0 ] && expect "no 'run started' claim" ! grep -q "run started" <<< "$OUT" &&
  expect "nothing invoked" ! log_has "lambda invoke --invocation-type Event"
}

t_upgrade_deploys_the_new_zip_and_keeps_settings() {
  install_ok; : > "$FAKE_AWS_LOG"
  make_release ai-exporter-1.1.0 1.1.0
  run upgrade ai-exporter-1.1.0
  local zsha; zsha="$(sha "$FAKE_RELEASE_DIR/ai-exporter-1.1.0/ai-exporter-1.1.0.zip")"
  expect "exit 0 ($OUT)" [ "$CODE" -eq 0 ] && expect "new code key" params_has "CodeKey=ai-exporter/bundle-$zsha.zip" &&
  expect "other settings untouched (kept by CloudFormation)" ! params_has "OrgId=" &&
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

# ---------- review fixes (PR #14) ----------

t_dry_run_reports_a_crashing_lambda() {
  touch "$FAKE_AWS_DIR/lambda-error"
  install_ok
  expect "fails" [ "$CODE" -ne 0 ] && expect "says the dry run failed" grep -q "dry run failed" <<< "$OUT" &&
  expect "shows the function's error" grep -q "ConfigError" <<< "$OUT" &&
  expect "not presented as a plan" ! grep -q "the next run will collect" <<< "$OUT"
}

t_set_key_with_no_key_never_overwrites_the_secret() {
  install_ok; printf 'working-key' > "$FAKE_AWS_DIR/secret-openai-GhIjKl"; : > "$FAKE_AWS_LOG"
  unset OPENAI_ADMIN_KEY
  run set-key openai
  expect "fails" [ "$CODE" -ne 0 ] && expect "names the variable" grep -q "OPENAI_ADMIN_KEY" <<< "$OUT" &&
  expect "secret untouched" [ "$(cat "$FAKE_AWS_DIR/secret-openai-GhIjKl")" = "working-key" ] &&
  expect "nothing stored" ! log_has "put-secret-value"
}

t_flag_without_a_value_is_refused() {
  run install --org-id 44 --release; expect "fails with a message" [ "$CODE" -eq 2 ] && expect "names the flag" grep -q -- "--release needs a value" <<< "$OUT" &&
  run install --release --org-id 44; expect "next flag is not taken as the value" [ "$CODE" -eq 2 ] && expect "names the flag" grep -q -- "--release needs a value" <<< "$OUT"
}

t_delete_data_prompt_names_the_billing_files_and_versioned_buckets_are_refused() {
  install_ok
  run uninstall --delete-data
  expect "refuses without a terminal" [ "$CODE" -ne 0 ] && expect "warns about the billing files" grep -q "FOCUS billing files" <<< "$OUT" &&
  touch "$FAKE_AWS_DIR/versioned"; : > "$FAKE_AWS_LOG"
  run uninstall --yes --delete-data
  expect "refused" [ "$CODE" -ne 0 ] && expect "says versioning" grep -q "versioning" <<< "$OUT" &&
  expect "stack not deleted first" ! log_has "delete-stack"
}

t_state_is_kept_per_stack() {
  unset AI_EXPORTER_STATE; export AI_EXPORTER_STATE_DIR="$T"
  install_ok && install_ok --stack second-exporter
  expect "two state files" [ -f "$T/.cloudpi-ai-exporter.cloudpi-ai-exporter.state" ] && [ -f "$T/.cloudpi-ai-exporter.second-exporter.state" ] &&
  expect "each remembers its stack" grep -q "^STACK=second-exporter$" "$T/.cloudpi-ai-exporter.second-exporter.state" &&
  run status --stack unknown-stack; expect "unknown stack refused" [ "$CODE" -ne 0 ] && expect "message" grep -q "no install found" <<< "$OUT" &&
  run status --region eu-west-1; expect "different region refused" [ "$CODE" -ne 0 ] && expect "message" grep -q "region" <<< "$OUT"
}

t_external_id_is_never_on_a_command_line() {
  install_ok --cloudpi-account-id 210987654321 --cloudpi-external-id ext-secret-123
  expect "exit 0 ($OUT)" [ "$CODE" -eq 0 ] && expect "not on any aws command line" ! log_has "ext-secret-123" &&
  expect "passed in the private file" params_has "CloudPiExternalId=ext-secret-123" &&
  expect "params file removed" [ -z "$(find "$T/tmp" -name 'ai-exporter-params.*' 2>/dev/null)" ]
}

t_expected_sha256_pins_the_release() {
  install_ok --expect-sha256 0000000000000000000000000000000000000000000000000000000000000000
  expect "refused" [ "$CODE" -ne 0 ] && expect "says it does not match" grep -q "does not match --expect-sha256" <<< "$OUT" &&
  expect "nothing deployed" ! log_has "cloudformation deploy" &&
  install_ok --expect-sha256 "$(sha "$FAKE_RELEASE_DIR/ai-exporter-1.0.0/ai-exporter-1.0.0.zip")"
  expect "accepted when it matches ($OUT)" [ "$CODE" -eq 0 ]
}

t_status_shows_every_log_of_the_latest_run() {
  install_ok
  run status
  expect "exit 0 ($OUT)" [ "$CODE" -eq 0 ] && expect "anthropic log shown" grep -q '"provider": "anthropic"' <<< "$OUT" &&
  expect "its failure visible" grep -q '"status": "failed"' <<< "$OUT" && expect "openai log shown" grep -q '"provider": "openai"' <<< "$OUT"
}

t_expected_template_sha256_pins_the_template() {
  install_ok --expect-template-sha256 1111111111111111111111111111111111111111111111111111111111111111
  expect "refused" [ "$CODE" -ne 0 ] && expect "says it does not match" grep -q "does not match --expect-template-sha256" <<< "$OUT" &&
  expect "nothing deployed" ! log_has "cloudformation deploy" &&
  install_ok --expect-template-sha256 "$(sha "$FAKE_RELEASE_DIR/ai-exporter-1.0.0/ai-exporter-template.yaml")"              --expect-sha256 "$(sha "$FAKE_RELEASE_DIR/ai-exporter-1.0.0/ai-exporter-1.0.0.zip")"
  expect "accepted when both match ($OUT)" [ "$CODE" -eq 0 ]
}

t_key_file_lives_in_the_work_folder_and_is_gone_after() {
  install_ok
  local path; path="$(cat "$FAKE_AWS_DIR/last-key-path")"
  expect "key file was used ($OUT)" [ -n "$path" ] && expect "file removed" [ ! -e "$path" ] &&
  expect "its folder removed too (so Ctrl-C cannot leave it behind)" [ ! -e "$(dirname "$path")" ] &&
  run set-key openai; path="$(cat "$FAKE_AWS_DIR/last-key-path")"
  expect "set-key ok ($OUT)" [ "$CODE" -eq 0 ] && expect "set-key folder removed" [ ! -e "$(dirname "$path")" ]
}

t_setting_with_a_line_break_is_refused() {
  install_ok --alarm-email "$(printf 'ops@example.com
x')"
  expect "refused" [ "$CODE" -ne 0 ] && expect "names the setting" grep -q "AlarmEmail" <<< "$OUT" &&
  expect "nothing deployed" ! log_has "cloudformation deploy"
}

t_delete_data_stops_when_versioning_cannot_be_checked() {
  install_ok; touch "$FAKE_AWS_DIR/versioning-denied"; : > "$FAKE_AWS_LOG"
  run uninstall --yes --delete-data
  expect "refused" [ "$CODE" -ne 0 ] && expect "says why" grep -q "could not check whether the bucket" <<< "$OUT" &&
  expect "stack not deleted" ! log_has "delete-stack" && expect "files not deleted" ! log_has "s3 rm"
}

t_install_in_another_region_does_not_overwrite_the_stack_state() {
  install_ok
  local before; before="$(cat "$AI_EXPORTER_STATE")"
  install_ok --region eu-west-1
  expect "refused" [ "$CODE" -ne 0 ] && expect "points to --stack" grep -q -- "--stack <another name>" <<< "$OUT" &&
  expect "state untouched" [ "$(cat "$AI_EXPORTER_STATE")" = "$before" ]
}

# ---------- gateway sources (spec 147 Phase 7a) ----------

up_has() { [ -f "$FAKE_AWS_DIR/update-params.json" ] && grep -qF -- "$1" "$FAKE_AWS_DIR/update-params.json"; }
add_gw() { run add-gateway-source --name litellm-prod --type litellm --bucket acme-litellm-logs --prefix gateway-logs "$@"; }

t_add_gateway_source_changes_only_the_gateway_parameters() {
  install_ok && add_gw --openai-projects proj_9xY,proj_2 --anthropic-workspaces wrkspc_01
  expect "exit 0 ($OUT)" [ "$CODE" -eq 0 ] &&
  expect "stack updated, same template" log_has "cloudformation update-stack" && log_has "--use-previous-template" &&
  expect "IAM capability" log_has "--capabilities CAPABILITY_NAMED_IAM" &&
  expect "waits for it" log_has "cloudformation wait stack-update-complete" &&
  expect "sources" up_has '"ParameterKey":"GatewaySources","ParameterValue":"[{\"name\":\"litellm-prod\",\"type\":\"litellm\",\"storage\":\"s3\",\"bucket\":\"acme-litellm-logs\",\"prefix\":\"gateway-logs\",\"scope\":{\"anthropic\":{\"workspaces\":[\"wrkspc_01\"]},\"openai\":{\"projects\":[\"proj_9xY\",\"proj_2\"]}}}]"' &&
  expect "bucket" up_has '"ParameterKey":"GatewayLogBucketArns","ParameterValue":"arn:aws:s3:::acme-litellm-logs"' &&
  expect "objects" up_has '"ParameterKey":"GatewayLogObjectArns","ParameterValue":"arn:aws:s3:::acme-litellm-logs/gateway-logs/*"' &&
  expect "prefix" up_has '"ParameterKey":"GatewayLogPrefixes","ParameterValue":"gateway-logs/*"' &&
  expect "everything else as it was" up_has '{"ParameterKey":"OrgId","UsePreviousValue":true}' &&
  up_has '{"ParameterKey":"CloudPiExternalId","UsePreviousValue":true}' &&
  expect "remembered" grep -q "^GW_SOURCE_litellm-prod=" "$AI_EXPORTER_STATE"
}

t_add_gateway_source_options() {
  install_ok && add_gw --openai-all --kms-key-arn arn:aws:kms:us-east-1:123456789012:key/1234abcd-12ab-34cd-56ef-1234567890ab --no-person-ids default_user_id,svc-ci --type cloudpi_record
  expect "exit 0 ($OUT)" [ "$CODE" -eq 0 ] &&
  expect "all" up_has '\"openai\":\"all\"' && expect "type" up_has '\"type\":\"cloudpi_record\"' &&
  expect "no-person ids" up_has '\"no_person_ids\":[\"default_user_id\",\"svc-ci\"]' &&
  expect "kms" up_has '"ParameterKey":"GatewayKmsKeyArns","ParameterValue":"arn:aws:kms:us-east-1:123456789012:key/1234abcd-12ab-34cd-56ef-1234567890ab"'
}

t_bad_gateway_sources_are_refused_before_anything_changes() {
  install_ok
  local bad
  for bad in "--prefix gateway-logs" "--openai-projects p --prefix ''" "--openai-projects p --name Bad_Name" \
             "--openai-projects p --type kong" "--openai-projects p --bucket NOT_A_BUCKET" \
             "--openai-projects p --openai-keys k" "--openai-projects p --kms-key-arn my-key" \
             "--openai-projects 'a b'"; do
    eval "add_gw $bad"
    expect "refused: $bad ($OUT)" [ "$CODE" -ne 0 ] && expect "no stack update: $bad" ! log_has "update-stack" || return 1
  done
}

t_a_second_source_must_not_overlap_and_names_are_unique() {
  install_ok && add_gw --openai-projects proj_9xY
  run add-gateway-source --name kong-edge --type litellm --bucket other-logs --prefix ai --openai-projects proj_9xY,proj_3
  expect "overlap refused" [ "$CODE" -ne 0 ] && expect "says overlap" grep -q "overlap" <<< "$OUT" &&
  add_gw --openai-projects proj_other
  expect "duplicate name refused" [ "$CODE" -ne 0 ] && expect "points to set-gateway-source" grep -q "set-gateway-source" <<< "$OUT" &&
  run add-gateway-source --name kong-edge --type litellm --bucket other-logs --prefix ai --openai-projects proj_3
  expect "a separate project is fine ($OUT)" [ "$CODE" -eq 0 ] &&
  expect "both sources" up_has 'litellm-prod' && up_has 'kong-edge' &&
  expect "both buckets" up_has '"ParameterValue":"arn:aws:s3:::acme-litellm-logs,arn:aws:s3:::other-logs"'
}

t_set_and_remove_a_gateway_source() {
  install_ok && add_gw --openai-projects proj_9xY
  run set-gateway-source --name litellm-prod --type litellm --bucket acme-litellm-logs --prefix gateway-logs --openai-projects proj_new
  expect "set ($OUT)" [ "$CODE" -eq 0 ] && expect "new scope" up_has 'proj_new' && expect "old scope gone" ! up_has 'proj_9xY' &&
  run remove-gateway-source --name litellm-prod
  expect "removed ($OUT)" [ "$CODE" -eq 0 ] && expect "no sources" up_has '"ParameterKey":"GatewaySources","ParameterValue":"[]"' &&
  expect "no read access left" up_has '"ParameterKey":"GatewayLogBucketArns","ParameterValue":""' &&
  expect "forgotten" ! grep -q "^GW_SOURCE_litellm-prod=" "$AI_EXPORTER_STATE" &&
  run remove-gateway-source --name litellm-prod
  expect "unknown source refused" [ "$CODE" -ne 0 ]
}

t_account_map_entries() {
  install_ok && add_gw --openai-projects proj_a,proj_b
  run add-account-map --source litellm-prod --provider openai --account proj_a --model-id openai-proj-a
  expect "added ($OUT)" [ "$CODE" -eq 0 ] &&
  expect "map" up_has '"ParameterKey":"GatewayAccountMap","ParameterValue":"[{\"source\":\"litellm-prod\",\"provider\":\"openai\",\"account\":\"proj_a\",\"match\":{\"model_id\":\"openai-proj-a\"}}]"' &&
  run add-account-map --source unknown --provider openai --account proj_a --model-id x
  expect "unknown source refused" [ "$CODE" -ne 0 ] &&
  run add-account-map --source litellm-prod --provider openai --account proj_a
  expect "a match is required" [ "$CODE" -ne 0 ] &&
  run remove-gateway-source --name litellm-prod
  expect "its map goes with it" up_has '"ParameterKey":"GatewayAccountMap","ParameterValue":"[]"'
}

t_set_gateway_source_keeps_its_account_map() {  # found in the real-bill lab 2026-11-27
  install_ok && add_gw --openai-projects proj_a
  run add-account-map --source litellm-prod --provider openai --account proj_a --model-id openai-proj-a
  run set-gateway-source --name litellm-prod --type litellm --bucket acme-litellm-logs --prefix gateway-logs --openai-projects proj_a,proj_b
  expect "set ($OUT)" [ "$CODE" -eq 0 ] && expect "new scope" up_has 'proj_b' &&
  expect "the map is kept" up_has '"ParameterKey":"GatewayAccountMap","ParameterValue":"[{\"source\":\"litellm-prod\"' &&
  expect "still in the state" grep -q '^GW_MAP={"source":"litellm-prod"' "$AI_EXPORTER_STATE"
}

t_list_gateway_sources() {
  install_ok && add_gw --openai-projects proj_9xY
  run list-gateway-sources
  expect "exit 0" [ "$CODE" -eq 0 ] && expect "lists it" grep -q "litellm-prod" <<< "$OUT" && grep -q "acme-litellm-logs/gateway-logs" <<< "$OUT"
}

t_gateway_dry_run_changes_nothing() {
  install_ok && local before; before="$(cat "$AI_EXPORTER_STATE")"
  add_gw --openai-projects proj_9xY --dry-run
  expect "exit 0 ($OUT)" [ "$CODE" -eq 0 ] && expect "shows the update" grep -q "(dry run) aws cloudformation update-stack" <<< "$OUT" &&
  expect "nothing called" ! log_has "update-stack" && expect "state untouched" [ "$(cat "$AI_EXPORTER_STATE")" = "$before" ]
}

t_a_release_without_gateway_support_is_refused() {
  install_ok && touch "$FAKE_AWS_DIR/no-gateway-params"
  add_gw --openai-projects proj_9xY
  expect "refused" [ "$CODE" -ne 0 ] && expect "says upgrade" grep -q "upgrade" <<< "$OUT" && expect "no update" ! log_has "update-stack"
}

t_no_change_to_the_stack_is_not_an_error() {
  install_ok && touch "$FAKE_AWS_DIR/no-updates"
  add_gw --openai-projects proj_9xY
  expect "exit 0 ($OUT)" [ "$CODE" -eq 0 ] && expect "says so" grep -q "already" <<< "$OUT"
}

t_reinstall_keeps_the_gateway_sources() {
  install_ok && add_gw --openai-projects proj_9xY && install_ok
  expect "still remembered" grep -q "^GW_SOURCE_litellm-prod=" "$AI_EXPORTER_STATE"
}

TESTS=$(declare -F | awk '{print $3}' | grep '^t_')
for t in $TESTS; do
  if ( setup_env; "$t" ); then PASS=$((PASS + 1)); echo "ok   $t"; else FAIL=$((FAIL + 1)); FAILED+=("$t"); echo "FAIL $t"; fi
done
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
