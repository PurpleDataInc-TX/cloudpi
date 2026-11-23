#!/bin/bash
# =============================================================================
# CloudPi - AI billing exporter setup
# =============================================================================
# Installs the AI billing exporter in YOUR AWS account: one Lambda that collects Anthropic (Claude) and OpenAI cost and
# usage every day, converts it to FOCUS 1.5 and writes it to a new private S3 bucket. See AI-BILLING-EXPORTER.md.
#
#   ./setup-ai-exporter.sh install --release ai-exporter-1.0.0 --org-id 44
#   ./setup-ai-exporter.sh upgrade ai-exporter-1.1.0
#   ./setup-ai-exporter.sh set-key openai        # store a new admin key (key rotation)
#   ./setup-ai-exporter.sh run-now               # start today's run now
#   ./setup-ai-exporter.sh status
#   ./setup-ai-exporter.sh uninstall [--delete-data]
#
# A release is a GitHub Release of the cloudpi repository. Its files (ai-exporter-manifest.json, the template and the
# Lambda zip) are downloaded into ./ai-exporter/<tag> and checked against the SHA-256s in the manifest before use.
# Admin keys are read from a hidden prompt (or ANTHROPIC_ADMIN_KEY / OPENAI_ADMIN_KEY) and passed to AWS only through a
# private temporary file: never on a command line, never in a log, never in the state file.
# Needs: the AWS CLI signed in to the account that will host the exporter, curl, sha256sum (or shasum).
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_ROOT="${AI_EXPORTER_DIR:-$SCRIPT_DIR/ai-exporter}"
STATE_FILE="${AI_EXPORTER_STATE:-$SCRIPT_DIR/.cloudpi-ai-exporter.state}"
RELEASE_BASE="${AI_EXPORTER_RELEASE_BASE:-https://github.com/PurpleDataInc-TX/cloudpi/releases/download}"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }
die() { log_error "$1"; exit 1; }
usage_error() { log_error "$1"; echo "Run ./setup-ai-exporter.sh --help for the options." >&2; exit 2; }

DRY_RUN=false ASSUME_YES=false DELETE_DATA=false
STACK="cloudpi-ai-exporter" REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}" RELEASE="" ORG_ID="" PROVIDERS="anthropic,openai"
BACKFILL=0 REQUESTER_MODE="full" SCHEDULE="cron(0 6 * * ? *)" ALARM_EMAIL="" CLOUDPI_ACCOUNT="" CLOUDPI_EXTERNAL_ID=""
CODE_BUCKET="" OUTPUT_BUCKET_NAME="" OUTPUT_PREFIX="ai-billing" POSITIONAL=""
ACCOUNT="" ZIP_SHA="" ZIP_PATH="" TEMPLATE_PATH="" WORKDIR=""
ANTHROPIC_KEY="" OPENAI_KEY=""
trap '[ -z "$WORKDIR" ] || rm -rf "$WORKDIR"' EXIT

# Reads change nothing and always run. Anything that changes AWS goes through `mutate`, which a dry run only prints
# (with the CloudPi external id masked).
query() { "$@"; }
mutate() {
    if $DRY_RUN; then
        local shown="$*"
        [ -z "$CLOUDPI_EXTERNAL_ID" ] || shown="${shown//"$CLOUDPI_EXTERNAL_ID"/***}"
        echo "  (dry run) $shown"
        return 0
    fi
    "$@"
}

usage() {
    cat <<'EOF'
Usage: ./setup-ai-exporter.sh <command> [options]

Commands
  install            deploy the exporter (bucket, Lambda, daily schedule, secrets) and store the admin keys
  upgrade <tag>      move the Lambda to another release; settings and keys stay as they are
  set-key <provider> store a new admin key for anthropic or openai (key rotation)
  run-now            start a run now instead of waiting for the daily schedule
  status             the stack's status and the newest run log
  uninstall          delete the stack; the bucket with the FOCUS files is kept unless --delete-data

Install options
  --release <tag>              REQUIRED. GitHub Release of cloudpi to install, for example ai-exporter-1.0.0
  --org-id <id>                REQUIRED. Your CloudPi organization id
  --providers <list>           anthropic,openai (default), anthropic or openai
  --region <region>            AWS region (default: AWS_REGION or the AWS CLI's region)
  --stack <name>               CloudFormation stack name (default cloudpi-ai-exporter)
  --backfill-months <n>        whole months before this one to collect once (default 0)
  --requester-mode <mode>      full (user ids, names, e-mails; default) or hashed
  --schedule <expression>      daily schedule, UTC (default "cron(0 6 * * ? *)")
  --alarm-email <address>      e-mail told when a run fails
  --output-bucket <name>       bucket for the FOCUS files (default cloudpi-ai-focus-<account>-<region>)
  --output-prefix <prefix>     folder in that bucket (default ai-billing)
  --code-bucket <name>         bucket for the Lambda zip (default cloudpi-ai-exporter-code-<account>-<region>)
  --cloudpi-account-id <id>    CloudPi's AWS account: creates the read-only role CloudPi uses to read the files
  --cloudpi-external-id <id>   required with --cloudpi-account-id

General options
  --dry-run                    print what would change, change nothing
  --yes                        do not ask (uninstall)
  --delete-data                uninstall: also delete the bucket and every FOCUS file in it
  -h, --help

Admin keys: the script asks for them with a hidden prompt. Without a terminal, set ANTHROPIC_ADMIN_KEY and/or
OPENAI_ADMIN_KEY in the environment instead.
EOF
}

# -- small helpers ---------------------------------------------------------------------------------------------------
need_tool() { command -v "$1" > /dev/null 2>&1 || die "$1 is not installed or not on the PATH"; }
sha256_of() {
    if command -v sha256sum > /dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
json_field() {  # json_field <file> <key>: a string value from the flat manifest.json
    sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -n 1
}
download() {  # download <url> <target>
    local url="$1" target="$2" tmp
    tmp="$(mktemp "$target.XXXXXX")"
    if ! curl -fsSL --retry 3 --retry-delay 2 -o "$tmp" "$url"; then
        rm -f "$tmp"
        die "could not download $url (is that release published?)"
    fi
    mv -f "$tmp" "$target"
}
check_value() {  # check_value <flag> <value> <regex> <what>
    [[ "$2" =~ $3 ]] || usage_error "$1 must be $4 (got '$2')"
}

# -- release files ---------------------------------------------------------------------------------------------------
# Downloads release <tag> into $WORK_ROOT/<tag> and checks the zip and the template against the manifest's SHA-256s.
fetch_release() {
    local tag="$1" base dir manifest zip_file template_file got want
    [[ "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || die "release '$tag' is not a valid tag (for example ai-exporter-1.0.0)"
    base="$RELEASE_BASE/$tag"; dir="$WORK_ROOT/$tag"
    mkdir -p "$dir"
    log_info "downloading release $tag from $base"
    download "$base/ai-exporter-manifest.json" "$dir/ai-exporter-manifest.json"
    manifest="$dir/ai-exporter-manifest.json"
    [ "$(json_field "$manifest" tag)" = "$tag" ] || die "the manifest of release $tag names release '$(json_field "$manifest" tag)': the release files do not belong together"
    zip_file="$(json_field "$manifest" zip_file)"; template_file="$(json_field "$manifest" template_file)"
    [[ "$zip_file" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.zip$ ]] || die "the manifest of release $tag has no valid zip_file"
    [[ "$template_file" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.yaml$ ]] || die "the manifest of release $tag has no valid template_file"
    download "$base/$template_file" "$dir/$template_file"
    if [ -f "$dir/$zip_file" ] && [ "$(sha256_of "$dir/$zip_file")" = "$(json_field "$manifest" zip_sha256)" ]; then
        log_info "$zip_file is already here and matches the release"
    else
        log_info "downloading $zip_file (about 40 MB)..."
        download "$base/$zip_file" "$dir/$zip_file"
    fi
    want="$(json_field "$manifest" template_sha256)"; got="$(sha256_of "$dir/$template_file")"
    [ -n "$want" ] && [ "$got" = "$want" ] || die "the template is damaged: its SHA-256 is ${got:0:12}..., the release says ${want:0:12}... (download the release again)"
    want="$(json_field "$manifest" zip_sha256)"; got="$(sha256_of "$dir/$zip_file")"
    [ -n "$want" ] && [ "$got" = "$want" ] || die "the Lambda zip is damaged: its SHA-256 is ${got:0:12}..., the release says ${want:0:12}... (download the release again)"
    ZIP_PATH="$dir/$zip_file"; TEMPLATE_PATH="$dir/$template_file"; ZIP_SHA="$want"; RELEASE="$tag"
    log_info "release $tag verified (zip SHA-256 ${ZIP_SHA:0:12}...)"
}

# -- AWS -------------------------------------------------------------------------------------------------------------
check_aws_identity() {
    local identity
    identity="$(query aws sts get-caller-identity --query Arn --output text)" || die "the AWS CLI is not signed in (run: aws configure, or use an instance role)"
    ACCOUNT="$(query aws sts get-caller-identity --query Account --output text)"
    [ -n "$REGION" ] || REGION="$(aws configure get region 2>/dev/null || true)"
    [ -n "$REGION" ] || die "no region: pass --region or set AWS_REGION"
    CODE_BUCKET="${CODE_BUCKET:-cloudpi-ai-exporter-code-$ACCOUNT-$REGION}"
    log_info "working as $identity, account $ACCOUNT, region $REGION"
}

ensure_code_bucket() {
    if query aws s3api head-bucket --bucket "$CODE_BUCKET" --region "$REGION" > /dev/null 2>&1; then
        log_info "code bucket $CODE_BUCKET exists"
        return 0
    fi
    local create=(aws s3api create-bucket --bucket "$CODE_BUCKET" --region "$REGION")
    [ "$REGION" = "us-east-1" ] || create+=(--create-bucket-configuration "LocationConstraint=$REGION")
    mutate "${create[@]}"
    mutate aws s3api put-public-access-block --bucket "$CODE_BUCKET" --region "$REGION" --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
    mutate aws s3api put-bucket-encryption --bucket "$CODE_BUCKET" --region "$REGION" --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
    log_info "code bucket $CODE_BUCKET created (private, encrypted)"
}

code_key() { echo "ai-exporter/bundle-$ZIP_SHA.zip"; }

upload_zip() {
    local key; key="$(code_key)"
    if query aws s3api head-object --bucket "$CODE_BUCKET" --key "$key" --region "$REGION" > /dev/null 2>&1; then
        log_info "$key is already in the code bucket: not uploaded again"
    else
        mutate aws s3 cp "$ZIP_PATH" "s3://$CODE_BUCKET/$key" --sse AES256 --region "$REGION"
    fi
}

deploy_stack() {  # deploy_stack <parameter overrides...>
    log_step "deploying stack $STACK"
    mutate aws cloudformation deploy --template-file "$TEMPLATE_PATH" --stack-name "$STACK" --region "$REGION" \
        --capabilities CAPABILITY_IAM --no-fail-on-empty-changeset --parameter-overrides "$@"
}

stack_output() {  # stack_output <OutputKey>: empty when the stack or the output does not exist
    local value
    value="$(query aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text 2>/dev/null)" || return 0
    [ "$value" = "None" ] || echo "$value"
}

# -- admin keys ------------------------------------------------------------------------------------------------------
provider_on() { [[ ",$PROVIDERS," == *",$1,"* ]]; }

read_key() {  # read_key <provider>: prints the key; from the environment, else a hidden prompt
    local provider="$1" var label key=""
    if [ "$provider" = "anthropic" ]; then var="ANTHROPIC_ADMIN_KEY"; label="Anthropic Admin API key"; else var="OPENAI_ADMIN_KEY"; label="OpenAI Admin API key"; fi
    key="${!var:-}"
    if [ -z "$key" ]; then
        [ -t 0 ] || die "no $label: set $var in the environment, or run this in a terminal to be asked for it"
        read -r -s -p "$label: " key; echo >&2
    fi
    [ -n "$key" ] || die "the $label is empty"
    [[ "$key" =~ ^[A-Za-z0-9_-]+$ ]] || die "the $label has unexpected characters (spaces or line breaks?)"
    if [ "$provider" = "anthropic" ] && [[ "$key" != sk-ant-admin* ]]; then
        log_warn "the Anthropic key does not start with sk-ant-admin: usage and cost reports need an Admin API key" >&2
    fi
    if [ "$provider" = "openai" ] && [[ "$key" != sk-admin-* ]]; then
        log_warn "the OpenAI key does not start with sk-admin-: usage and cost reports need an Admin key" >&2
    fi
    echo "$key"
}

store_key() {  # store_key <provider> <key>: through a private temporary file, never on a command line
    local provider="$1" key="$2" output arn tmp
    if [ "$provider" = "anthropic" ]; then output="AnthropicSecretArn"; else output="OpenAISecretArn"; fi
    arn="$(stack_output "$output")"
    if [ -z "$arn" ]; then
        $DRY_RUN && { echo "  (dry run) store the $provider admin key in the stack's secret"; return 0; }
        die "the stack has no $provider secret (is $provider turned on? see --providers)"
    fi
    tmp="$(umask 077; mktemp "${TMPDIR:-/tmp}/ai-exporter-key.XXXXXX")"
    printf '%s' "$key" > "$tmp"
    mutate aws secretsmanager put-secret-value --secret-id "$arn" --secret-string "file://$tmp" --region "$REGION" > /dev/null || { rm -f "$tmp"; die "could not store the $provider admin key"; }
    rm -f "$tmp"
    log_info "$provider admin key stored in Secrets Manager"
}

# -- state -----------------------------------------------------------------------------------------------------------
save_state() {  # ids and names only, never a key
    $DRY_RUN && return 0
    (umask 077; printf '%s\n' "STACK=$STACK" "REGION=$REGION" "RELEASE=$RELEASE" "CODE_BUCKET=$CODE_BUCKET" \
        "ORG_ID=$ORG_ID" "PROVIDERS=$PROVIDERS" > "$STATE_FILE")
}
state_get() { sed -n "s/^$1=//p" "$STATE_FILE" | head -n 1; }
load_state() {
    [ -f "$STATE_FILE" ] || die "no install found ($STATE_FILE is missing): run ./setup-ai-exporter.sh install first"
    STACK="$(state_get STACK)"; REGION="$(state_get REGION)"; RELEASE="$(state_get RELEASE)"
    CODE_BUCKET="$(state_get CODE_BUCKET)"; ORG_ID="$(state_get ORG_ID)"; PROVIDERS="$(state_get PROVIDERS)"
}

show_plan() {  # a dry run of today's plan: which provider-months the next run would collect
    local fn out
    fn="$(stack_output FunctionName)"
    [ -n "$fn" ] || { $DRY_RUN && return 0; die "the stack has no function output"; }
    out="$WORKDIR/plan.json"
    query aws lambda invoke --function-name "$fn" --payload '{"mode": "plan", "dry_run": true}' \
        --cli-binary-format raw-in-base64-out --region "$REGION" "$out" > /dev/null || die "the dry run of the exporter failed (see its CloudWatch logs)"
    log_info "the next run will collect:"
    cat "$out"; echo
}

# -- commands --------------------------------------------------------------------------------------------------------
cmd_install() {
    [ -n "$RELEASE" ] || usage_error "--release <tag> is required"
    [ -n "$ORG_ID" ] || usage_error "--org-id <id> is required"
    check_value --org-id "$ORG_ID" '^[A-Za-z0-9_-]+$' "letters, digits, '_' or '-'"
    [[ "$PROVIDERS" =~ ^(anthropic|openai)(,(anthropic|openai))?$ ]] || usage_error "--providers must be anthropic, openai or anthropic,openai (got '$PROVIDERS')"
    check_value --backfill-months "$BACKFILL" '^([0-9]|[1-9][0-9]|1[01][0-9]|120)$' "a whole number from 0 to 120"
    check_value --requester-mode "$REQUESTER_MODE" '^(full|hashed)$' "full or hashed"
    [ -z "$CLOUDPI_ACCOUNT" ] || check_value --cloudpi-account-id "$CLOUDPI_ACCOUNT" '^[0-9]{12}$' "a 12-digit AWS account id"
    [ -z "$CLOUDPI_ACCOUNT" ] || [ -n "$CLOUDPI_EXTERNAL_ID" ] || usage_error "--cloudpi-external-id is required with --cloudpi-account-id"
    need_tool aws; need_tool curl
    # Ask for the keys first, so a missing key stops the install before anything is created.
    if provider_on anthropic; then ANTHROPIC_KEY="$(read_key anthropic)"; fi
    if provider_on openai; then OPENAI_KEY="$(read_key openai)"; fi
    WORKDIR="$(mktemp -d)"
    check_aws_identity
    fetch_release "$RELEASE"
    ensure_code_bucket
    upload_zip
    local enable_anthropic=false enable_openai=false
    provider_on anthropic && enable_anthropic=true
    provider_on openai && enable_openai=true
    local params=("OrgId=$ORG_ID" "CodeBucket=$CODE_BUCKET" "CodeKey=$(code_key)" "EnableAnthropic=$enable_anthropic"
                  "EnableOpenAI=$enable_openai" "BackfillMonths=$BACKFILL" "RequesterMode=$REQUESTER_MODE"
                  "ScheduleExpression=$SCHEDULE" "OutputPrefix=$OUTPUT_PREFIX")
    [ -z "$OUTPUT_BUCKET_NAME" ] || params+=("OutputBucketName=$OUTPUT_BUCKET_NAME")
    [ -z "$ALARM_EMAIL" ] || params+=("AlarmEmail=$ALARM_EMAIL")
    [ -z "$CLOUDPI_ACCOUNT" ] || params+=("CloudPiAccountId=$CLOUDPI_ACCOUNT" "CloudPiExternalId=$CLOUDPI_EXTERNAL_ID")
    deploy_stack "${params[@]}"
    [ -z "$ANTHROPIC_KEY" ] || store_key anthropic "$ANTHROPIC_KEY"
    [ -z "$OPENAI_KEY" ] || store_key openai "$OPENAI_KEY"
    ANTHROPIC_KEY="" OPENAI_KEY=""
    save_state
    show_plan
    local bucket; bucket="$(stack_output OutputBucketName)"
    log_info "installed. Files go to s3://${bucket:-<output bucket>}/$OUTPUT_PREFIX/ every day at the scheduled time."
    log_info "start a run now with: ./setup-ai-exporter.sh run-now"
}

cmd_upgrade() {
    [ -n "$POSITIONAL" ] || usage_error "upgrade needs the release tag: ./setup-ai-exporter.sh upgrade <tag>"
    load_state
    need_tool aws; need_tool curl
    WORKDIR="$(mktemp -d)"
    check_aws_identity
    fetch_release "$POSITIONAL"
    ensure_code_bucket
    upload_zip
    # Only the code changes; CloudFormation keeps every other setting as it is.
    deploy_stack "CodeBucket=$CODE_BUCKET" "CodeKey=$(code_key)"
    save_state
    show_plan
    log_info "upgraded to $RELEASE"
}

cmd_set_key() {
    local provider="$POSITIONAL"
    [[ "$provider" =~ ^(anthropic|openai)$ ]] || usage_error "set-key needs the provider: anthropic or openai"
    load_state
    need_tool aws
    provider_on "$provider" || die "$provider is not turned on in this install"
    store_key "$provider" "$(read_key "$provider")"
}

cmd_run_now() {
    load_state
    need_tool aws
    WORKDIR="$(mktemp -d)"
    local fn; fn="$(stack_output FunctionName)"
    [ -n "$fn" ] || die "the stack $STACK was not found in $REGION"
    mutate aws lambda invoke --invocation-type Event --function-name "$fn" --payload '{"mode": "plan"}' \
        --cli-binary-format raw-in-base64-out --region "$REGION" "$WORKDIR/run.json" > /dev/null
    log_info "run started; see ./setup-ai-exporter.sh status in a few minutes"
}

cmd_status() {
    load_state
    need_tool aws
    local status bucket prefix latest
    status="$(query aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" --query "Stacks[0].StackStatus" --output text 2>/dev/null || true)"
    echo "stack:    $STACK (${status:-not found}) in $REGION"
    echo "release:  $RELEASE"
    bucket="$(stack_output OutputBucketName)"; prefix="$(stack_output OutputPrefix)"
    [ -n "$bucket" ] || return 0
    echo "files:    s3://$bucket/$prefix/"
    latest="$(query aws s3api list-objects-v2 --bucket "$bucket" --prefix "$prefix/_runs/" --region "$REGION" \
        --query "sort_by(Contents, &LastModified)[-1].Key" --output text 2>/dev/null || true)"
    if [ -z "$latest" ] || [ "$latest" = "None" ]; then echo "last run: none yet"; return 0; fi
    echo "last run: $latest"
    query aws s3 cp "s3://$bucket/$latest" - --region "$REGION" 2>/dev/null || true
}

cmd_uninstall() {
    load_state
    need_tool aws
    local bucket answer
    bucket="$(stack_output OutputBucketName)"
    if ! $ASSUME_YES; then
        [ -t 0 ] || die "uninstall deletes the stack $STACK: confirm by running it in a terminal, or add --yes"
        read -r -p "Delete the stack $STACK in $REGION? Type yes: " answer
        [ "$answer" = "yes" ] || die "not deleted"
    fi
    log_step "deleting stack $STACK"
    mutate aws cloudformation delete-stack --stack-name "$STACK" --region "$REGION"
    mutate aws cloudformation wait stack-delete-complete --stack-name "$STACK" --region "$REGION"
    if $DELETE_DATA && [ -n "$bucket" ]; then
        log_step "deleting the bucket $bucket and every file in it"
        mutate aws s3 rm "s3://$bucket" --recursive --region "$REGION"
        mutate aws s3api delete-bucket --bucket "$bucket" --region "$REGION"
    elif [ -n "$bucket" ]; then
        log_info "the bucket $bucket and its FOCUS files are kept (delete them with --delete-data)"
    fi
    log_info "the code bucket $CODE_BUCKET is kept; delete it yourself if it is no longer needed"
    $DRY_RUN || rm -f "$STATE_FILE"
}

main() {
    local cmd="${1:-}"
    [ $# -eq 0 ] || shift
    case "$cmd" in
        -h|--help|help) usage; exit 0 ;;
        install|upgrade|set-key|run-now|status|uninstall) ;;
        "") usage; exit 2 ;;
        *) usage_error "unknown command '$cmd'" ;;
    esac
    while [ $# -gt 0 ]; do
        case "$1" in
            --release) RELEASE="${2:-}"; shift 2 ;;
            --org-id) ORG_ID="${2:-}"; shift 2 ;;
            --providers) PROVIDERS="${2:-}"; shift 2 ;;
            --region) REGION="${2:-}"; shift 2 ;;
            --stack) STACK="${2:-}"; shift 2 ;;
            --backfill-months) BACKFILL="${2:-}"; shift 2 ;;
            --requester-mode) REQUESTER_MODE="${2:-}"; shift 2 ;;
            --schedule) SCHEDULE="${2:-}"; shift 2 ;;
            --alarm-email) ALARM_EMAIL="${2:-}"; shift 2 ;;
            --output-bucket) OUTPUT_BUCKET_NAME="${2:-}"; shift 2 ;;
            --output-prefix) OUTPUT_PREFIX="${2:-}"; shift 2 ;;
            --code-bucket) CODE_BUCKET="${2:-}"; shift 2 ;;
            --cloudpi-account-id) CLOUDPI_ACCOUNT="${2:-}"; shift 2 ;;
            --cloudpi-external-id) CLOUDPI_EXTERNAL_ID="${2:-}"; shift 2 ;;
            --dry-run) DRY_RUN=true; shift ;;
            --yes) ASSUME_YES=true; shift ;;
            --delete-data) DELETE_DATA=true; shift ;;
            -h|--help) usage; exit 0 ;;
            -*) usage_error "unknown option '$1'" ;;
            *) [ -z "$POSITIONAL" ] || usage_error "unexpected argument '$1'"; POSITIONAL="$1"; shift ;;
        esac
    done
    case "$cmd" in
        install) cmd_install ;;
        upgrade) cmd_upgrade ;;
        set-key) cmd_set_key ;;
        run-now) cmd_run_now ;;
        status) cmd_status ;;
        uninstall) cmd_uninstall ;;
    esac
}

main "$@"
