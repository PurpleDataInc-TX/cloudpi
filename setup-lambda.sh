#!/bin/bash
# =============================================================================
# CloudPi - Lambda ingestion setup
# =============================================================================
# Moves CloudPi's billing ingestion (Order 1) from this server onto AWS Lambda Managed Instances, in YOUR AWS account, and back.
# Nothing changes for you until you run `install`; without it CloudPi keeps collecting on this server (INGEST_INVOKER=local).
#
#   ./setup-lambda.sh install --release 1.5.0 --subnets subnet-a,subnet-b --security-group sg-x --database-secret-arn arn:aws:secretsmanager:...
#   ./setup-lambda.sh upgrade 1.6.0   # the Lambda moves to another release (cp_upgrade.sh does this for you, see "follow")
#   ./setup-lambda.sh local           # collect on this server again (the Lambda stays, switched off)
#   ./setup-lambda.sh lambda          # collect on Lambda again, with the settings of the last install
#   ./setup-lambda.sh status
#
# A release is a GitHub Release of the cloudpi repository named by the CloudPi image tag; its files (lambda-manifest.json, lambda-template.yaml,
# lambda-service-role.yaml and the bundle zip) are downloaded into ./lambda and the bundle is checked against its SHA-256 before anything is used.
# Needs: the AWS CLI signed in to the account that will host the function, curl, Docker with the Compose plugin. See --help.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOUDPI_DIR="${CLOUDPI_DIR:-$SCRIPT_DIR}"
LAMBDA_DIR="${LAMBDA_DIR:-$CLOUDPI_DIR/lambda}"
ENV_FILE="${ENV_FILE:-$CLOUDPI_DIR/.env}"
STATE_FILE="${STATE_FILE:-$CLOUDPI_DIR/.cloudpi-lambda.state}"
RELEASE_BASE="${CLOUDPI_RELEASE_BASE:-https://github.com/PurpleDataInc-TX/cloudpi/releases/download}"
HEARTBEAT_FRESH_S="${HEARTBEAT_FRESH_S:-300}"     # a job whose heartbeat is newer than this, and that has no result yet, is running
BEGIN_MARK="# >>> cloudpi-lambda (written by setup-lambda.sh, do not edit between the marks) >>>"
END_MARK="# <<< cloudpi-lambda <<<"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }
die() { log_error "$1"; exit 1; }

DRY_RUN=false
ASSUME_YES=false
FORCE=false
WORKDIR=""
trap '[ -z "$WORKDIR" ] || rm -rf "$WORKDIR"' EXIT

# The settings of one install. They are script-level so that install, upgrade and follow run the same steps below.
SUBNETS="" SG="" SECRET="" REGION="${AWS_REGION:-}" BUCKET="" STACK="cloudpi-lambda" FUNCTION="cloudpi-dlt-ingest"
INSTANCE_ROLE="" USE_ROLE=true DB_SG="" RELEASE=""
CH_SECRET="" REDIS_SECRET="" READ_SOURCE="" NO_CH=false      # optional: the function also writes ClickHouse (needs both secrets)
ACCOUNT="" BUNDLE_SHA="" BUNDLE_PATH="" ROLE_ARGS=()

# Reads change nothing and always run. Anything that changes AWS or this server goes through `mutate`, which a dry run only prints.
query() { "$@"; }
mutate() {
    if $DRY_RUN; then echo "  (dry run) $*"; return 0; fi
    "$@"
}

usage() {
    cat <<'EOF'
Usage: ./setup-lambda.sh <command> [options]

Commands
  install        create the Lambda in your AWS account; the imports of every org that the user marks Historical (one month at a time) run on it
  upgrade <tag>  move the Lambda to the release <tag> (the CloudPi image tag); refuses while a collection is running on it
  follow <tag>   what cp_upgrade.sh runs after the app is healthy on <tag>: upgrade if the Lambda is installed, nothing if it is not
  local          switch collection back to this server (keeps the Lambda, switched off)
  lambda         switch collection to Lambda again, with the settings of the last install
  status         show the current mode, the settings and the stack

install options
  --release <tag>                the release to install (the CloudPi image tag). Without it the files already in ./lambda are used.
  --subnets <a,b>                REQUIRED. Two subnets in different Availability Zones, e.g. subnet-0a1,subnet-0b2
  --security-group <sg-id>       REQUIRED. No inbound rules; outbound to S3, Secrets Manager and your database
  --database-secret-arn <arn>    REQUIRED. Secrets Manager secret whose value is the MySQL URL the function connects with
  --clickhouse-secret-arn <arn>  OPTIONAL. Secrets Manager secret (JSON: host, port, user, password, database, secure, ca_cert) of the ClickHouse the
                                 function also writes. Needs --redis-secret-arn. Without it the function uses MySQL only, as before.
  --redis-secret-arn <arn>       OPTIONAL. Secrets Manager secret (JSON: host, port, password) of the Redis that numbers the rows both databases hold
  --read-source <mysql|compare|clickhouse>  where the function reads from when ClickHouse is on (default clickhouse)
  --no-clickhouse                remove ClickHouse from the function. Without it, an install that gives no ClickHouse flags keeps the ClickHouse
                                 settings of the last install
  --database-security-group <sg> the security group of your database (RDS, or any MySQL host in the same VPC): port 3306 is opened on it to the
                                 function's group. Not needed for the CloudPi server created by cloud-template.yaml with
                                 EnableLambdaIngestion=true, which already allows the function.
  --region <region>              default: AWS_REGION, then the AWS CLI's default
  --bucket <name>                default: cloudpi-lambda-<account id>-<region> (created if missing)
  --stack <name>                 default: cloudpi-lambda (at most 24 characters; the deploy role's IAM names depend on it)
  --function <name>              default: cloudpi-dlt-ingest
  --instance-role <name>         IAM role of this server: the policy CloudPi needs is attached to it
  --no-service-role              deploy with your own permissions instead of a dedicated CloudFormation role (first trial)
  --dry-run                      print what would change, change nothing (the release files are still downloaded and checked)
  --yes                          do not ask before restarting the CloudPi app container

upgrade / follow options
  --force                        upgrade even if a collection seems to be running on the function (it may fail)
  --dry-run  --yes

Restarting the app container interrupts a collection that is running right now. Run install when none is.
EOF
}

# -- the release files ------------------------------------------------------------------------------------------------------------
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

# Downloads the files of release <tag> into $LAMBDA_DIR: the manifest, the two templates and the bundle zip the manifest names.
fetch_release() {
    local tag="$1" base manifest file
    [[ "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || die "release '$tag' is not a valid tag (the CloudPi image tag, e.g. 1.5.0)"
    base="$RELEASE_BASE/$tag"
    mkdir -p "$LAMBDA_DIR"
    log_info "downloading release $tag from $base"
    download "$base/lambda-manifest.json" "$LAMBDA_DIR/manifest.json"
    download "$base/lambda-template.yaml" "$LAMBDA_DIR/template.yaml"
    download "$base/lambda-service-role.yaml" "$LAMBDA_DIR/service-role.yaml"
    manifest="$LAMBDA_DIR/manifest.json"
    [ "$(json_field "$manifest" tag)" = "$tag" ] || die "the manifest of release $tag names release '$(json_field "$manifest" tag)': the release files do not belong together"
    file="$(json_field "$manifest" bundle_file)"
    [[ "$file" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "the manifest of release $tag has no valid bundle_file"
    if [ -f "$LAMBDA_DIR/$file" ] && [ "$(sha256sum "$LAMBDA_DIR/$file" | cut -d' ' -f1)" = "$(json_field "$manifest" bundle_sha256)" ]; then
        log_info "$file is already here and matches the release"
    else
        log_info "downloading $file (a few hundred MB)..."
        download "$base/$file" "$LAMBDA_DIR/$file"
    fi
    RELEASE="$tag"
}

# The bundle as one file at $1: the zip itself, or its parts joined. Fails unless it matches the SHA-256 in manifest.json. Prints that SHA-256.
assemble_bundle() {
    local target="$1" manifest="$LAMBDA_DIR/manifest.json" file want got
    [ -f "$manifest" ] || die "$manifest not found: the release files are missing (run with --release <tag>)"
    file="$(json_field "$manifest" bundle_file)"; want="$(json_field "$manifest" bundle_sha256)"
    [ -n "$file" ] && [ -n "$want" ] || die "$manifest has no bundle_file or bundle_sha256"
    if [ -f "$LAMBDA_DIR/$file" ]; then
        cp "$LAMBDA_DIR/$file" "$target"
    else
        local parts=("$LAMBDA_DIR/$file".part-*)
        [ -e "${parts[0]}" ] || die "neither $LAMBDA_DIR/$file nor its parts ($file.part-00, ...) exist"
        cat "${parts[@]}" > "$target"
    fi
    got="$(sha256sum "$target" | cut -d' ' -f1)"
    [ "$got" = "$want" ] || die "the bundle is damaged: its SHA-256 is ${got:0:12}..., the release says ${want:0:12}... (download the release again)"
    echo "$want"
}

# -- .env and the saved settings ------------------------------------------------------------------------------------------------------
BACKED_UP=false
write_env_block() {  # write_env_block <invoker> <function> <bucket> <region>
    local invoker="$1" fn="$2" bucket="$3" region="$4" tmp
    tmp="$(mktemp)"
    if [ -f "$ENV_FILE" ]; then
        awk -v b="$BEGIN_MARK" -v e="$END_MARK" '$0==b{skip=1;next} $0==e{skip=0;next} !skip' "$ENV_FILE" > "$tmp"
        if [ -s "$tmp" ] && [ -n "$(tail -c1 "$tmp")" ]; then echo >> "$tmp"; fi
        local clash
        clash="$(grep -E '^(INGEST_INVOKER|INGEST_MONTH_RUNNER|INGEST_LAMBDA_[A-Z_]+|AWS_REGION)=' "$tmp" || true)"
        if [ -n "$clash" ]; then
            log_warn "these settings are also set outside the cloudpi-lambda block in $ENV_FILE; the block comes last and wins:
$clash"
        fi
    fi
    {
        echo "$BEGIN_MARK"
        echo "INGEST_MONTH_RUNNER=dlt"
        echo "INGEST_INVOKER=$invoker"
        echo "INGEST_LAMBDA_FUNCTION=$fn"
        echo "INGEST_LAMBDA_BUCKET=$bucket"
        echo "INGEST_LAMBDA_ORGS=all"       # every org may use the Lambda path (PiFlask sends none unless a list or "all" is set); only its historical imports go
        echo "AWS_REGION=$region"
        echo "$END_MARK"
    } >> "$tmp"
    if $DRY_RUN; then
        echo "  (dry run) $ENV_FILE would get:"
        sed -n '/^# >>> cloudpi-lambda/,/^# <<< cloudpi-lambda/p' "$tmp" | sed 's/^/      /'
        rm -f "$tmp"
        return 0
    fi
    if [ -f "$ENV_FILE" ] && ! $BACKED_UP; then
        cp -p "$ENV_FILE" "$ENV_FILE.bak-lambda-$(date +%Y%m%d%H%M%S)"
        BACKED_UP=true
    fi
    cat "$tmp" > "$ENV_FILE"          # write into the existing file, so its owner and permissions stay
    rm -f "$tmp"
}

# SHA-256 of the two templates of the downloaded release (function stack, then service-role stack). A release can change only these (the loader
# is inline in the template, and so are the IAM policy, memory and timeout) and keep the same bundle, so the upgrade compares both.
templates_sha() {
    cat "$LAMBDA_DIR/template.yaml" "$LAMBDA_DIR/service-role.yaml" | sha256sum | cut -d' ' -f1
}

# Ids and names only, never a secret: what an upgrade needs to deploy the same stack again.
save_state() {
    if $DRY_RUN; then return 0; fi
    local tmp; tmp="$(mktemp)"
    printf '%s\n' "STACK=$STACK" "FUNCTION=$FUNCTION" "BUCKET=$BUCKET" "REGION=$REGION" "RELEASE=${RELEASE:-unknown}" \
        "BUNDLE_SHA256=$BUNDLE_SHA" "TEMPLATES_SHA256=$(templates_sha)" "SUBNETS=$SUBNETS" "SG=$SG" "SECRET=$SECRET" \
        "USE_ROLE=$USE_ROLE" "INSTANCE_ROLE=$INSTANCE_ROLE" "DB_SG=$DB_SG" > "$tmp"
    if [ -n "$CH_SECRET" ]; then printf '%s\n' "CH_SECRET=$CH_SECRET" "REDIS_SECRET=$REDIS_SECRET" >> "$tmp"; fi
    if [ -n "$READ_SOURCE" ]; then printf '%s\n' "READ_SOURCE=$READ_SOURCE" >> "$tmp"; fi
    cat "$tmp" > "$STATE_FILE"
    rm -f "$tmp"
}
state_get() {
    if [ -f "$STATE_FILE" ]; then sed -n "s/^$1=//p" "$STATE_FILE" | head -n 1; fi
}
load_state() {
    [ -f "$STATE_FILE" ] || die "no Lambda settings saved ($STATE_FILE): run ./setup-lambda.sh install first"
    STACK="$(state_get STACK)"; FUNCTION="$(state_get FUNCTION)"; BUCKET="$(state_get BUCKET)"
    REGION="$(state_get REGION)"; SUBNETS="$(state_get SUBNETS)"; SG="$(state_get SG)"; SECRET="$(state_get SECRET)"
    USE_ROLE="$(state_get USE_ROLE)"
    INSTANCE_ROLE="$(state_get INSTANCE_ROLE)"; DB_SG="$(state_get DB_SG)"
    CH_SECRET="$(state_get CH_SECRET)"; REDIS_SECRET="$(state_get REDIS_SECRET)"; READ_SOURCE="$(state_get READ_SOURCE)"
    [ "${#STACK}" -le 24 ] || die "the stack name '$STACK' (saved in $STATE_FILE) is longer than the 24 characters this release's deploy role supports (its permissions name the stack's IAM roles, which CloudFormation shortens for longer stack names). Install again under a shorter --stack name"
    if [ -z "$STACK" ] || [ -z "$FUNCTION" ] || [ -z "$BUCKET" ] || [ -z "$REGION" ] || [ -z "$SUBNETS" ] || [ -z "$SG" ] || [ -z "$SECRET" ]; then
        die "$STATE_FILE is incomplete (an install made by an older setup-lambda.sh?): run ./setup-lambda.sh install again"
    fi
    [ -n "$USE_ROLE" ] || USE_ROLE=true
}

recreate_app() {
    log_step "Restarting the CloudPi app container so it reads the new settings..."
    if ! $ASSUME_YES && ! $DRY_RUN; then
        local answer=""
        read -r -p "This interrupts any collection running now. Continue? [y/N] " answer || answer=""
        answer="${answer%$'\r'}"          # an answer piped in from Windows tools ends in CR LF
        case "$answer" in
            y|Y|yes|YES) ;;
            *) die "stopped before restarting the app. The settings are in $ENV_FILE; apply them with: cd $CLOUDPI_DIR && docker compose up -d --no-deps --force-recreate app";;
        esac
    fi
    mutate bash -c "cd '$CLOUDPI_DIR' && docker compose up -d --no-deps --force-recreate app"
}

# -- checks ------------------------------------------------------------------------------------------------------------------------
need_tool() { command -v "$1" > /dev/null 2>&1 || die "$1 is not installed or not on the PATH"; }
check_value() {  # check_value <flag> <value> <regex> <example>
    [ -n "$2" ] || die "$1 is required"
    [[ "$2" =~ $3 ]] || die "$1 '$2' is not valid (example: $4)"
}

# The number of jobs on the function right now: a heartbeat newer than HEARTBEAT_FRESH_S whose job has no result.json yet. dlt-jobs/ is the
# template's ProtocolPrefix default; this script never sets another, so the stacks it creates always use it.
# Prints how many collections are running on the function. Fails (and prints nothing) when the job files cannot be listed: a listing that
# failed must never read as "none running", or the guard would let an upgrade through while collections are running.
count_running_jobs() {
    local now key modified age prefix running=0 listing answer
    now="$(date -u +%s)"
    listing="$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "dlt-jobs/" --region "$REGION" \
        --query "Contents[?ends_with(Key, 'heartbeat.json')].[Key,LastModified]" --output text)" || return 1
    while IFS=$'\t' read -r key modified; do
        if [ -z "$key" ] || [ "$key" = "None" ]; then continue; fi
        age=$(( now - $(date -u -d "$modified" +%s) ))
        if [ "$age" -lt "$HEARTBEAT_FRESH_S" ]; then
            prefix="${key%heartbeat.json}"
            if answer="$(aws s3api head-object --bucket "$BUCKET" --key "${prefix}result.json" --region "$REGION" 2>&1)"; then
                :                                                          # result.json is there: the job is over
            elif [[ "$answer" == *"404"* || "$answer" == *"Not Found"* ]]; then
                running=$(( running + 1 ))                                 # no result yet
            else
                echo "$answer" >&2                                         # 403, throttling, network: only a 404 means "not finished"
                return 1
            fi
        fi
    done <<< "$listing"
    echo "$running"
}

# The database is in your VPC; the function gets to it through its security group, not through an address range. The rule stays when the
# stack is deleted (the group is yours): remove it with aws ec2 revoke-security-group-ingress.
allow_database() {  # allow_database <database security group> <function security group> <region>
    local db_sg="$1" fn_sg="$2" region="$3" out
    if $DRY_RUN; then
        echo "  (dry run) aws ec2 authorize-security-group-ingress --group-id $db_sg --protocol tcp --port 3306 --source-group $fn_sg --region $region"
        return 0
    fi
    if out="$(aws ec2 authorize-security-group-ingress --group-id "$db_sg" --protocol tcp --port 3306 --source-group "$fn_sg" --region "$region" 2>&1)"; then
        log_info "$db_sg now accepts the function's security group $fn_sg on port 3306"
    elif [[ "$out" == *InvalidPermission.Duplicate* ]]; then
        log_info "$db_sg already accepts $fn_sg on port 3306"
    else
        die "could not open port 3306 on $db_sg to $fn_sg (are both in the same VPC?): ${out:0:300}"
    fi
}

# -- the steps install and upgrade share ----------------------------------------------------------------------------------------------
check_release_files() {
    local f
    for f in template.yaml service-role.yaml manifest.json; do
        [ -f "$LAMBDA_DIR/$f" ] || die "$LAMBDA_DIR/$f not found: the release files are missing (run with --release <tag>)"
    done
}

check_aws_identity() {
    local identity
    identity="$(query aws sts get-caller-identity --query Arn --output text)" || die "the AWS CLI is not signed in (run: aws configure, or use an instance role)"
    ACCOUNT="$(query aws sts get-caller-identity --query Account --output text)"
    [ -n "$REGION" ] || REGION="$(aws configure get region 2>/dev/null || true)"
    [ -n "$REGION" ] || die "no region: pass --region or set AWS_REGION"
    BUCKET="${BUCKET:-cloudpi-lambda-$ACCOUNT-$REGION}"
    log_info "deploying as $identity, account $ACCOUNT, region $REGION"
}

verify_bundle() {
    WORKDIR="$(mktemp -d)"
    BUNDLE_PATH="$WORKDIR/bundle.zip"
    BUNDLE_SHA="$(assemble_bundle "$BUNDLE_PATH")"
    log_info "bundle verified (SHA-256 ${BUNDLE_SHA:0:12}..., $(( $(wc -c < "$BUNDLE_PATH") / 1048576 )) MB)"
}

ensure_bucket() {
    if query aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" > /dev/null 2>&1; then
        log_info "bucket $BUCKET exists"
        return 0
    fi
    local create=(aws s3api create-bucket --bucket "$BUCKET" --region "$REGION")
    [ "$REGION" = "us-east-1" ] || create+=(--create-bucket-configuration "LocationConstraint=$REGION")
    mutate "${create[@]}"
    mutate aws s3api put-public-access-block --bucket "$BUCKET" --region "$REGION" --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
    mutate aws s3api put-bucket-encryption --bucket "$BUCKET" --region "$REGION" --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
    mutate aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --region "$REGION" --lifecycle-configuration '{"Rules":[{"ID":"expire-job-files","Status":"Enabled","Filter":{"Prefix":"dlt-jobs/"},"Expiration":{"Days":7}}]}'
    log_info "bucket $BUCKET created (private, encrypted, job files expire after 7 days)"
}

upload_bundle() {
    local key="dlt/bundle-$BUNDLE_SHA.zip"
    if query aws s3api head-object --bucket "$BUCKET" --key "$key" --region "$REGION" > /dev/null 2>&1; then
        log_info "$key is already in the bucket: not uploaded again"
    else
        mutate aws s3 cp "$BUNDLE_PATH" "s3://$BUCKET/$key" --sse AES256 --region "$REGION"
    fi
}

deploy_role_stack() {   # sets ROLE_ARGS
    ROLE_ARGS=()
    if ! $USE_ROLE; then
        log_step "Skipped (--no-service-role): the stack is deployed with your own permissions"
        if [ -n "$INSTANCE_ROLE" ]; then log_warn "--instance-role is used only with the service role stack; attach the CloudPi policy to the server's role yourself"; fi
        return 0
    fi
    local deployer="$STACK-deployer" role_arn="<role arn>"
    local role_params=("StackName=$STACK" "FunctionName=$FUNCTION" "ArtifactBucket=$BUCKET")
    if [ -n "$INSTANCE_ROLE" ]; then role_params+=("InstanceRoleName=$INSTANCE_ROLE"); fi
    mutate aws cloudformation deploy --template-file "$LAMBDA_DIR/service-role.yaml" --stack-name "$deployer" --region "$REGION" \
        --capabilities CAPABILITY_IAM --no-fail-on-empty-changeset --parameter-overrides "${role_params[@]}"
    if ! $DRY_RUN; then
        role_arn="$(query aws cloudformation describe-stacks --stack-name "$deployer" --region "$REGION" --query "Stacks[0].Outputs[?OutputKey=='CloudFormationRoleArn'].OutputValue" --output text)"
    fi
    ROLE_ARGS=(--role-arn "$role_arn")
    if [ -z "$INSTANCE_ROLE" ]; then
        log_warn "no --instance-role: attach the policy in the output AppPolicyArn of stack $deployer to the AWS role of this server, or CloudPi cannot invoke the function"
    fi
}

deploy_function_stack() {
    local key="dlt/bundle-$BUNDLE_SHA.zip"
    local extra=()
    if [ -n "$CH_SECRET" ]; then extra+=("ClickHouseSecretArn=$CH_SECRET" "RedisSecretArn=$REDIS_SECRET"); fi
    if [ -n "$READ_SOURCE" ]; then extra+=("DatabaseReadSource=$READ_SOURCE"); fi
    mutate aws cloudformation deploy --template-file "$LAMBDA_DIR/template.yaml" --stack-name "$STACK" --region "$REGION" \
        --capabilities CAPABILITY_IAM --no-fail-on-empty-changeset ${ROLE_ARGS[@]+"${ROLE_ARGS[@]}"} --tags project=cloudpi-lambda \
        --parameter-overrides "FunctionName=$FUNCTION" "ArtifactBucket=$BUCKET" "BundleKey=$key" "BundleSha256=$BUNDLE_SHA" \
        "SubnetIds=$SUBNETS" "SecurityGroupId=$SG" "DatabaseSecretArn=$SECRET" ${extra[@]+"${extra[@]}"} \
        "ProjectTag=cloudpi-lambda"
}

switch_function_off() {
    # The stack deploys with one environment running; CloudPi switches machines on per job, so nothing runs idle.
    mutate aws lambda put-function-scaling-config --function-name "$FUNCTION" --qualifier '$LATEST.PUBLISHED' \
        --function-scaling-config MinExecutionEnvironments=0,MaxExecutionEnvironments=0 --region "$REGION"
}

# -- install ----------------------------------------------------------------------------------------------------------------------
cmd_install() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --release) RELEASE="${2:-}"; shift 2;;
            --subnets) SUBNETS="${2:-}"; shift 2;;
            --security-group) SG="${2:-}"; shift 2;;
            --database-secret-arn) SECRET="${2:-}"; shift 2;;
            --clickhouse-secret-arn) CH_SECRET="${2:-}"; shift 2;;
            --redis-secret-arn) REDIS_SECRET="${2:-}"; shift 2;;
            --read-source) READ_SOURCE="${2:-}"; shift 2;;
            --no-clickhouse) NO_CH=true; shift;;
            --database-security-group) DB_SG="${2:-}"; shift 2;;
            --region) REGION="${2:-}"; shift 2;;
            --bucket) BUCKET="${2:-}"; shift 2;;
            --stack) STACK="${2:-}"; shift 2;;
            --function) FUNCTION="${2:-}"; shift 2;;
            --instance-role) INSTANCE_ROLE="${2:-}"; shift 2;;
            --no-service-role) USE_ROLE=false; shift;;
            --dry-run) DRY_RUN=true; shift;;
            --yes) ASSUME_YES=true; shift;;
            -h|--help) usage; exit 0;;
            *) die "unknown option $1 (see ./setup-lambda.sh --help)";;
        esac
    done
    check_value --subnets "$SUBNETS" '^subnet-[0-9a-f]+(,subnet-[0-9a-f]+)+$' "subnet-0a1,subnet-0b2 (two or more)"
    check_value --security-group "$SG" '^sg-[0-9a-f]+$' "sg-0123abcd"
    # Never print this value back: a customer may have pasted the MySQL URL, with its password, where the secret's ARN belongs.
    [ -n "$SECRET" ] || die "--database-secret-arn is required"
    [[ "$SECRET" =~ ^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]+:secret:.+$ ]] || die "--database-secret-arn is not a Secrets Manager ARN (example: arn:aws:secretsmanager:us-east-1:123456789012:secret:cloudpi-db-AbCd). Give the ARN of a secret that holds the database URL, never the URL itself."
    # ClickHouse is kept across installs: running install again to change something else must not silently turn dual write off.
    if $NO_CH; then
        if [ -n "$CH_SECRET$REDIS_SECRET$READ_SOURCE" ]; then die "--no-clickhouse cannot be combined with --clickhouse-secret-arn, --redis-secret-arn or --read-source"; fi
    elif [ -z "$CH_SECRET" ] && [ -z "$REDIS_SECRET" ] && [ -n "$(state_get CH_SECRET)" ]; then
        CH_SECRET="$(state_get CH_SECRET)"; REDIS_SECRET="$(state_get REDIS_SECRET)"
        [ -n "$READ_SOURCE" ] || READ_SOURCE="$(state_get READ_SOURCE)"
        log_info "keeping the ClickHouse and Redis settings of the last install (--no-clickhouse removes them)"
    fi
    # The optional ClickHouse / Redis secrets: ARNs only (never echo a value back), and ClickHouse needs the Redis that numbers its rows.
    local pair flag value
    for pair in "--clickhouse-secret-arn=$CH_SECRET" "--redis-secret-arn=$REDIS_SECRET"; do
        flag="${pair%%=*}"; value="${pair#*=}"
        if [ -n "$value" ] && ! [[ "$value" =~ ^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]+:secret:.+$ ]]; then die "$flag is not a Secrets Manager ARN"; fi
    done
    if [ -n "$CH_SECRET" ] && [ -z "$REDIS_SECRET" ]; then die "--clickhouse-secret-arn needs --redis-secret-arn (the Redis that numbers the rows both databases hold)"; fi
    if [ -n "$REDIS_SECRET" ] && [ -z "$CH_SECRET" ]; then die "--redis-secret-arn is used only with --clickhouse-secret-arn"; fi
    if [ -n "$READ_SOURCE" ]; then
        [ -n "$CH_SECRET" ] || die "--read-source is used only with --clickhouse-secret-arn"
        case "$READ_SOURCE" in mysql|compare|clickhouse) ;; *) die "--read-source must be mysql, compare or clickhouse";; esac
    fi
    if [ -n "$DB_SG" ]; then check_value --database-security-group "$DB_SG" '^sg-[0-9a-f]+$' "sg-0123abcd"; fi
    check_value --stack "$STACK" '^[A-Za-z][A-Za-z0-9-]{0,60}$' "cloudpi-lambda"
    # CloudFormation names IAM roles <stack>-<resource>-<random 12>, and IAM allows 64 characters. The deployer stack is <stack>-deployer and its
    # role is <stack>-deployer-CloudFormationRole-<12>: that is the longest name, and it fits only up to 24 characters of <stack>. A longer name makes
    # CloudFormation shorten generated role names, and the deploy role's permissions name the function stack's roles as <stack>-OperatorRole-* and
    # <stack>-FunctionRole-*.
    [ "${#STACK}" -le 24 ] || die "--stack '$STACK' is too long: use at most 24 characters (IAM role names are limited to 64 characters and CloudFormation shortens the ones it generates from a longer stack name)"
    check_value --function "$FUNCTION" '^[A-Za-z0-9_-]{1,64}$' "cloudpi-dlt-ingest"

    if $DRY_RUN; then log_info "CloudPi Lambda ingestion setup (dry run: nothing is changed)"; else log_info "CloudPi Lambda ingestion setup"; fi
    log_step "Step 1: Checking this server and the release files..."
    need_tool aws; need_tool docker; need_tool sha256sum
    docker compose version > /dev/null 2>&1 || die "the Docker Compose plugin is not installed"
    [ -f "$CLOUDPI_DIR/docker-compose.yml" ] || die "docker-compose.yml not found in $CLOUDPI_DIR (set CLOUDPI_DIR)"
    [ -f "$ENV_FILE" ] || die "$ENV_FILE not found"
    if [ -n "$RELEASE" ]; then need_tool curl; fetch_release "$RELEASE"; fi
    check_release_files
    local tag; tag="$(json_field "$LAMBDA_DIR/manifest.json" tag)"
    RELEASE="${tag:-${RELEASE:-unknown}}"
    log_info "release: $RELEASE"

    log_step "Step 2: Checking your AWS account..."
    check_aws_identity
    log_info "the function ($FUNCTION), the bucket ($BUCKET) and the stack ($STACK) will be created in this account"

    log_step "Step 3: Verifying the bundle..."
    verify_bundle

    log_step "Step 4: Preparing the bucket and uploading the bundle..."
    ensure_bucket
    upload_bundle
    if [ -n "$DB_SG" ]; then
        log_step "Step 4b: Letting the function reach your database (security group $DB_SG, port 3306)..."
        allow_database "$DB_SG" "$SG" "$REGION"
    fi

    log_step "Step 5: Creating the CloudFormation role and CloudPi's policy (stack $STACK-deployer)..."
    deploy_role_stack

    log_step "Step 6: Deploying the function stack $STACK (this takes several minutes)..."
    deploy_function_stack

    log_step "Step 7: Switching the function off until a job needs it..."
    switch_function_off

    log_step "Step 8: Pointing CloudPi at the function..."
    write_env_block lambda "$FUNCTION" "$BUCKET" "$REGION"
    save_state
    recreate_app

    echo
    log_info "Done. The imports of every org that the user marks Historical on the import page now run on Lambda, one month at a time; regular imports and scheduled collection stay on this server."
    log_info "Back to this server at any time: ./setup-lambda.sh local"
}

# -- upgrade / follow -------------------------------------------------------------------------------------------------------------
cmd_upgrade() {
    local tag="${1:-}"
    if [ $# -gt 0 ]; then shift; fi
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) DRY_RUN=true; shift;;
            --yes) ASSUME_YES=true; shift;;
            --force) FORCE=true; shift;;
            *) die "unknown option $1 (see ./setup-lambda.sh --help)";;
        esac
    done
    [ -n "$tag" ] || die "upgrade needs the release to move to, e.g. ./setup-lambda.sh upgrade 1.6.0"
    load_state
    need_tool aws; need_tool curl; need_tool sha256sum
    if $DRY_RUN; then log_info "CloudPi Lambda upgrade to $tag (dry run: nothing is changed)"; else log_info "CloudPi Lambda upgrade to $tag"; fi

    log_step "Step 1: Fetching and verifying release $tag..."
    fetch_release "$tag"
    check_release_files
    verify_bundle
    check_aws_identity
    # An install made before TEMPLATES_SHA256 was recorded has none, so it deploys once (CloudFormation reports "no changes" if there are none).
    if [ "$BUNDLE_SHA" = "$(state_get BUNDLE_SHA256)" ] && [ "$(templates_sha)" = "$(state_get TEMPLATES_SHA256)" ]; then
        log_info "the Lambda already runs this bundle and these templates (release $(state_get RELEASE)): nothing to deploy"
        if [ "$(state_get RELEASE)" != "$tag" ]; then save_state; fi
        return 0
    fi

    log_step "Step 2: Checking that no collection is running on the function..."
    local running
    if ! running="$(count_running_jobs)"; then
        if $FORCE; then
            log_warn "could not read the job files in s3://$BUCKET/dlt-jobs/, so a running collection would not be seen; --force: upgrading anyway"
            running=0
        else
            die "could not read the job files in s3://$BUCKET/dlt-jobs/ (see the AWS message above), so I cannot tell whether a collection is running. Nothing was changed. Fix the access and run this again (--force to upgrade anyway)."
        fi
    fi
    if [ "$running" -gt 0 ]; then
        if $FORCE; then
            log_warn "$running collection(s) are running on the function; --force: upgrading anyway (they may fail)"
        else
            die "$running collection(s) are running on the function now. Wait for them to finish and run this again (--force to upgrade anyway)."
        fi
    else
        log_info "no collection is running"
    fi

    log_step "Step 3: Uploading the bundle..."
    ensure_bucket
    upload_bundle

    log_step "Step 4: Deploying release $tag (stack $STACK)..."
    deploy_role_stack
    deploy_function_stack
    switch_function_off
    save_state
    echo
    log_info "Done. The Lambda is on release $tag."
}

cmd_follow() {
    local tag="${1:-}"
    [ -n "$tag" ] || die "follow needs the release the app is now on, e.g. ./setup-lambda.sh follow 1.6.0"
    if [ ! -f "$STATE_FILE" ]; then
        log_info "Lambda ingestion is not installed on this server: nothing to do"
        return 0
    fi
    cmd_upgrade "$@"
}

# -- local / lambda / status --------------------------------------------------------------------------------------------------------
switch_mode() {  # switch_mode <invoker> [options]
    local mode="$1"; shift
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) DRY_RUN=true; shift;;
            --yes) ASSUME_YES=true; shift;;
            *) die "unknown option $1";;
        esac
    done
    [ -f "$STATE_FILE" ] || die "no Lambda settings saved ($STATE_FILE): run ./setup-lambda.sh install first"
    local fn bucket region
    fn="$(state_get FUNCTION)"; bucket="$(state_get BUCKET)"; region="$(state_get REGION)"
    if [ -z "$fn" ] || [ -z "$bucket" ] || [ -z "$region" ]; then die "$STATE_FILE is incomplete: run ./setup-lambda.sh install again"; fi
    need_tool docker
    write_env_block "$mode" "$fn" "$bucket" "$region"
    recreate_app
    if [ "$mode" = "local" ]; then
        # A collection that was running when CloudPi stopped leaves the machines switched on, and nothing starts them off again once
        # CloudPi no longer uses the function: switch them off here, so they do not bill.
        FUNCTION="$fn"; REGION="$region"
        if command -v aws > /dev/null 2>&1; then
            switch_function_off || log_warn "could not switch the Lambda ($fn) off: run  aws lambda put-function-scaling-config --function-name $fn --qualifier '\$LATEST.PUBLISHED' --function-scaling-config MinExecutionEnvironments=0,MaxExecutionEnvironments=0 --region $region"
        else
            log_warn "the aws CLI is not installed, so the Lambda ($fn) was not switched off: do it from the console or with the AWS CLI if a collection was running"
        fi
        log_info "Collection runs on this server again. The Lambda ($fn) stays in your account, switched off."
    else
        log_info "Historical imports of every org run on Lambda again; scheduled collection stays on this server."
    fi
}

cmd_status() {
    local mode=""
    if [ -f "$ENV_FILE" ]; then mode="$(sed -n 's/^INGEST_INVOKER=//p' "$ENV_FILE" | tail -n 1)"; fi
    echo "mode:      ${mode:-local (no cloudpi-lambda block in $ENV_FILE)}"
    if [ -f "$STATE_FILE" ]; then
        echo "release:   $(state_get RELEASE)"
        echo "stack:     $(state_get STACK)   function: $(state_get FUNCTION)   bucket: $(state_get BUCKET)"
        echo "orgs:      every org (historical imports)   region: $(state_get REGION)"
        if [ -n "$(state_get CH_SECRET)" ]; then echo "clickhouse: yes (the function writes MySQL and ClickHouse; reads: $(state_get READ_SOURCE | grep . || echo clickhouse))"; else echo "clickhouse: no (the function uses MySQL only)"; fi
        if command -v aws > /dev/null 2>&1; then
            local state
            state="$(query aws cloudformation describe-stacks --stack-name "$(state_get STACK)" --region "$(state_get REGION)" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || true)"
            echo "stack state: ${state:-not found}"
        fi
    else
        echo "Lambda ingestion has not been installed on this server."
    fi
}

main() {
    local command="${1:-}"
    if [ $# -gt 0 ]; then shift; fi
    case "$command" in
        install) cmd_install "$@";;
        upgrade) cmd_upgrade "$@";;
        follow) cmd_follow "$@";;
        local) switch_mode local "$@";;
        lambda) switch_mode lambda "$@";;
        status) cmd_status;;
        ""|-h|--help|help) usage;;
        *) usage; die "unknown command '$command'";;
    esac
}

main "$@"
