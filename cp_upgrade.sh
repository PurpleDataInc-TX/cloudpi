#!/bin/bash
#
# CloudPi Upgrade Script
#
# Purpose: Deploy a new CloudPi app image with automatic rollback on migration failure.
#
# Usage:
#   ./cp_upgrade.sh <new-tag>              # Deploy new version
#   ./cp_upgrade.sh --status               # Show current deployment state
#   ./cp_upgrade.sh --history              # List all deployment snapshots
#   ./cp_upgrade.sh --restore [N]          # Restore to snapshot N (interactive if N omitted)
#   ./cp_upgrade.sh --rollback             # Quick rollback to previous version
#   ./cp_upgrade.sh --prune [N]            # Delete old snapshots, keep last N
#   ./cp_upgrade.sh --delete <id>[,<id>...]  # Delete specific snapshot(s) by ID
#   ./cp_upgrade.sh --delete <id> --force  # Allow deleting the newest snapshot
#   ./cp_upgrade.sh --backup               # Ad-hoc snapshot (no tag change, brief downtime)
#   ./cp_upgrade.sh --backup --skip-prune  # Ad-hoc snapshot, keep all existing snapshots
#   ./cp_upgrade.sh --backup-dir /path <cmd>  # Override backup directory (works with any command)
#   ./cp_upgrade.sh --config-show          # Show current effective config + active file
#   ./cp_upgrade.sh --config-set KEY=VALUE # Persist a setting to cp_upgrade.conf
#   ./cp_upgrade.sh --init <app-tag> <db-tag>  # First-time deployment (no existing data)
#
# Config resolution (highest priority first):
#   1. CLI flag (--backup-dir, etc.)
#   2. Environment variable (BACKUP_DIR=/x ./cp_upgrade.sh ...)
#   3. Persistent config file (cp_upgrade.conf — see --config-set)
#   4. Built-in default
#
# Config file auto-loaded from first existing of:
#   $CP_UPGRADE_CONFIG > ${SCRIPT_DIR}/cp_upgrade.conf > /etc/cloudpi/cp_upgrade.conf
#   > ${HOME}/.cp_upgrade.conf
#
# Encryption (optional):
#   BACKUP_ENCRYPT=1 BACKUP_KEY_FILE=/etc/cloudpi/backup.key  ./cp_upgrade.sh <new-tag>
#   Backups are streamed through openssl AES-256-CBC+PBKDF2; files gain .enc suffix.
#   Key file: head -c 64 /dev/urandom | base64 > /etc/cloudpi/backup.key && chmod 600 $_
#
# What it does (deploy):
#   1. Verifies prerequisites (Docker, compose file, DB healthy)
#   2. Saves current image tag for rollback
#   3. Stops app and DB containers
#   4. Takes raw backup of MySQL data volume + creates versioned snapshot
#   5. Starts DB, waits for healthy
#   6. Clears migration lockout, updates image tag
#   7. Starts app container with new image
#   8. Monitors migration logs for success/failure
#   9. On failure: stops both → restores volume from backup → restarts with old image
#
# Snapshots:
#   Each deploy creates a snapshot (app_tag + db_tag + volume backup + sha256 checksum).
#   Use --history to view, --restore to downgrade to any previous snapshot.
#
set -euo pipefail
IFS=$'\n\t'

# ============================================================
# Configuration
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Auto-load persistent config file (no need to repeat flags on every invocation).
#
# Resolution chain for each setting: CLI flag > environment variable > config file > default
#
# Config file locations (first existing wins):
#   1. ${CP_UPGRADE_CONFIG}              — explicit override via env var
#   2. ${SCRIPT_DIR}/cp_upgrade.conf     — co-located with the script (recommended)
#   3. /etc/cloudpi/cp_upgrade.conf      — system-wide
#   4. ${HOME}/.cp_upgrade.conf          — per-user
#
# Format: plain shell assignments, one per line. Example:
#   BACKUP_DIR=/data/cloudpi-backups
#   BACKUP_ENCRYPT=1
#   BACKUP_KEY_FILE=/etc/cloudpi/backup.key
#   MAX_SNAPSHOTS=10
#
# Loaded values only apply if the variable is not already set in the environment,
# so `BACKUP_DIR=/other ./cp_upgrade.sh` still overrides the config file.
_load_config_file() {
    local candidates=(
        "${CP_UPGRADE_CONFIG:-}"
        "${SCRIPT_DIR}/cp_upgrade.conf"
        "/etc/cloudpi/cp_upgrade.conf"
        "${HOME}/.cp_upgrade.conf"
    )
    local cfg
    for cfg in "${candidates[@]}"; do
        [ -z "$cfg" ] && continue
        [ -f "$cfg" ] || continue
        [ -r "$cfg" ] || continue
        # SECURITY: the config file is NEVER sourced by the shell. It is parsed
        # line-by-line as plain text below. This prevents a writable (or tampered)
        # config file from executing arbitrary code via `$(...)`, backticks, or `;`.
        #
        # Structural validation: reject any line that isn't blank, a comment, or a
        # KEY=value assignment. This catches obvious attempts like `touch /tmp/pwn`
        # that would fail the pattern entirely.
        local bad_line
        bad_line=$(grep -vE '^[[:space:]]*(#|$|[A-Z_][A-Z0-9_]*=)' "$cfg" | head -1 || true)
        if [ -n "$bad_line" ]; then
            echo "Warning: config file $cfg contains non-assignment line: $bad_line" >&2
            echo "         Only lines of the form KEY=value are permitted. Skipping this file." >&2
            continue
        fi
        # Load only keys that aren't already set in the environment.
        # We read the file line-by-line and only assign if the target var is unset.
        local key value line
        while IFS= read -r line; do
            # Skip comments and blank lines
            case "$line" in
                ''|'#'*|*[![:space:]]*'#'*) ;;
            esac
            [[ "$line" =~ ^[[:space:]]*([A-Z_][A-Z0-9_]*)=(.*)$ ]] || continue
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            # Handle quoting and inline comments. Parsing rules match what Bourne shell
            # does when sourcing the same line:
            #   KEY=value           → "value"
            #   KEY=value # comment → "value"   (unquoted inline comment stripped)
            #   KEY="value # x"     → "value # x"   (quoted — comment is literal)
            #   KEY='value # x'     → "value # x"   (single-quoted — comment is literal)
            case "$value" in
                \"*\"*)
                    # Double-quoted: extract content between first and last double-quote.
                    # Anything after the closing quote is treated as a comment and dropped.
                    # Using a non-greedy regex to avoid swallowing `"` inside quoted value.
                    if [[ "$value" =~ ^\"([^\"]*)\" ]]; then
                        value="${BASH_REMATCH[1]}"
                    else
                        value="${value#\"}"; value="${value%\"}"
                    fi
                    ;;
                \'*\'*)
                    # Single-quoted: same treatment, single-quotes instead.
                    if [[ "$value" =~ ^\'([^\']*)\' ]]; then
                        value="${BASH_REMATCH[1]}"
                    else
                        value="${value#\'}"; value="${value%\'}"
                    fi
                    ;;
                *)
                    # Unquoted: strip trailing inline comment (whitespace + '#...')
                    # and any trailing whitespace. A bare '#' anywhere in the value is
                    # treated as a comment start only if preceded by whitespace, matching
                    # shell parsing for `KEY=foo#bar` (literal foo#bar) vs `KEY=foo #bar`.
                    if [[ "$value" =~ ^(.*[^[:space:]])[[:space:]]+#.*$ ]]; then
                        value="${BASH_REMATCH[1]}"
                    elif [[ "$value" =~ ^[[:space:]]*#.*$ ]]; then
                        # Entire value is a comment → empty
                        value=""
                    fi
                    # Trim trailing whitespace
                    value="${value%"${value##*[![:space:]]}"}"
                    ;;
            esac
            # SECURITY: reject values containing shell metacharacters. Even though
            # we never source the file, this defense-in-depth catches attempts to
            # smuggle shell-sensitive content that could cause surprises if the
            # value were later embedded in a shell pipeline without proper quoting.
            # Allowed: A-Z a-z 0-9 / . _ - : = + @ and space (for paths).
            # Rejected: $ ` \ ; | & ( ) < > newline and any unprintable byte.
            if printf '%s' "$value" | LC_ALL=C grep -qE '[][$`\\;|&()<>]|[[:cntrl:]]'; then
                echo "Warning: config $cfg — value for $key contains disallowed characters; skipping this key" >&2
                continue
            fi
            # Only apply if the env var is unset (environment wins over config file)
            if [ -z "${!key:-}" ]; then
                export "$key=$value"
            fi
        done < "$cfg"
        CP_UPGRADE_LOADED_CONFIG="$cfg"
        export CP_UPGRADE_LOADED_CONFIG
        break  # first match wins
    done
}
_load_config_file
unset -f _load_config_file

# Auto-detect compose file (supports .yml, .yaml, and compose.yml/compose.yaml)
COMPOSE_FILE=""
for _cf in "${SCRIPT_DIR}/docker-compose.yml" \
           "${SCRIPT_DIR}/docker-compose.yaml" \
           "${SCRIPT_DIR}/compose.yml" \
           "${SCRIPT_DIR}/compose.yaml"; do
    if [ -f "$_cf" ]; then
        COMPOSE_FILE="$_cf"
        break
    fi
done
unset _cf
# Fallback to the conventional name (error will be caught by require_compose_file/check_prerequisites)
COMPOSE_FILE="${COMPOSE_FILE:-${SCRIPT_DIR}/docker-compose.yml}"
ENV_FILE="${SCRIPT_DIR}/.env"
STATE_FILE="${SCRIPT_DIR}/.deploy_state"
# Pin the restore journal to SCRIPT_DIR so crash recovery works even if the
# operator changes BACKUP_DIR between the failing run and the recovery run.
# The journal records in-progress restore state (.restore_tmp / .restore_bak
# directories that live inside the Docker VOLUME path, not BACKUP_DIR), so it
# must not depend on BACKUP_DIR at all.
RESTORE_JOURNAL_FILE="${SCRIPT_DIR}/.restore_journal"
LOCKOUT_FILE_PATH="/app/backups/.migration_lockout"

APP_CONTAINER="cloudpi-app"
DB_CONTAINER="cloudpi-db"
DOCKER_REPOSITORY="cloudpi1/cloudpi"
# Backup directory — resolution priority:
#   1. --backup-dir <path>  CLI flag (highest, set by early arg parser below)
#   2. BACKUP_DIR env var    (e.g., in .env or shell environment)
#   3. ${SCRIPT_DIR}/backups default (original behavior)
# Relative paths are resolved relative to SCRIPT_DIR so behavior is predictable
# regardless of where the script was invoked from.
BACKUP_DIR="${BACKUP_DIR:-${SCRIPT_DIR}/backups}"
DEPLOY_IN_PROGRESS=false
AUTO_YES=false

# Compose project name (used to prefix volume names for unambiguous resolution).
# Priority: COMPOSE_PROJECT_NAME env > docker compose config > directory name fallback.
COMPOSE_PROJECT=""
if [ -n "${COMPOSE_PROJECT_NAME:-}" ]; then
    COMPOSE_PROJECT="$COMPOSE_PROJECT_NAME"
fi

# Timeouts
MIGRATION_TIMEOUT="${MIGRATION_TIMEOUT:-300}"  # 5 minutes max for migrations
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-120}"         # 2 minutes for health check after migrations
DB_WAIT_TIMEOUT="${DB_WAIT_TIMEOUT:-60}"        # 1 minute for DB readiness

# Snapshots
MAX_SNAPSHOTS="${MAX_SNAPSHOTS:-5}"             # Auto-prune oldest beyond this count (0 = unlimited)

# Backup encryption (AES-256-CBC via openssl). Disabled by default for backward compat.
# To enable:
#   1. Create a key file:  head -c 64 /dev/urandom | base64 > /etc/cloudpi/backup.key && chmod 600 /etc/cloudpi/backup.key
#   2. Export env vars:    BACKUP_ENCRYPT=1  BACKUP_KEY_FILE=/etc/cloudpi/backup.key
# Encrypted backups have a .enc suffix and cannot be restored without the key file.
BACKUP_ENCRYPT="${BACKUP_ENCRYPT:-0}"
BACKUP_KEY_FILE="${BACKUP_KEY_FILE:-}"
BACKUP_ENC_CIPHER="${BACKUP_ENC_CIPHER:-aes-256-cbc}"

# Validate all numeric configuration values at startup (prevents mid-deploy arithmetic errors)
for _cfg_var in MIGRATION_TIMEOUT HEALTH_TIMEOUT DB_WAIT_TIMEOUT MAX_SNAPSHOTS; do
    if ! [[ "${!_cfg_var}" =~ ^[0-9]+$ ]]; then
        echo "Error: $_cfg_var must be a non-negative integer (got: '${!_cfg_var}')" >&2
        exit 1
    fi
done
unset _cfg_var

# ============================================================
# Concurrent Execution Guard
# ============================================================
LOCK_FILE="${SCRIPT_DIR}/.deploy.lock"

LOCK_ACQUIRED=false

acquire_deploy_lock() {
    # Only called for mutating operations (deploy, rollback, restore, prune, init)
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        echo "Error: Another cp_upgrade.sh is already running (lock: $LOCK_FILE)" >&2
        echo "If this is stale, remove the lock: rm -f $LOCK_FILE" >&2
        exit 1
    fi
    LOCK_ACQUIRED=true
}

# Early argument normalization: strip global flags (--yes/-y, --force/-f,
# --backup-dir <path>) that can appear anywhere in the arg list so later subcommand
# detection sees the subcommand in $1. Without this, `cp_upgrade.sh -y --status`
# looked like a mutating command to the lock/sudo gates below.
#
# AUTO_YES, AUTO_FORCE, and BACKUP_DIR are set here for all downstream code to see.
AUTO_YES=${AUTO_YES:-false}
AUTO_FORCE=${AUTO_FORCE:-0}
_early_args=()
_expect_backup_dir=0
for _arg in "$@"; do
    if [ "$_expect_backup_dir" = "1" ]; then
        BACKUP_DIR="$_arg"
        _expect_backup_dir=0
        continue
    fi
    case "$_arg" in
        --yes|-y)          AUTO_YES=true ;;
        --force|-f)        AUTO_FORCE=1 ;;
        --backup-dir)      _expect_backup_dir=1 ;;      # next arg is the path
        --backup-dir=*)    BACKUP_DIR="${_arg#--backup-dir=}" ;;
        *)                 _early_args+=("$_arg") ;;
    esac
done
if [ "$_expect_backup_dir" = "1" ]; then
    echo "Error: --backup-dir requires a path argument" >&2
    exit 1
fi
set -- "${_early_args[@]+"${_early_args[@]}"}"
unset _early_args _arg _expect_backup_dir

# Resolve BACKUP_DIR: convert relative paths to absolute (relative to SCRIPT_DIR),
# reject empty values, expand ~ in case user passes --backup-dir=~/backups.
if [ -z "${BACKUP_DIR:-}" ]; then
    echo "Error: BACKUP_DIR is empty — set via .env or --backup-dir <path>" >&2
    exit 1
fi
# Expand leading tilde (shell already did this for bare args, but --backup-dir=~/x doesn't expand)
case "$BACKUP_DIR" in
    "~"|"~/"*) BACKUP_DIR="${HOME}${BACKUP_DIR#\~}" ;;
esac
# Resolve relative paths anchored at SCRIPT_DIR for predictability
case "$BACKUP_DIR" in
    /*) : ;;  # already absolute
    *)  BACKUP_DIR="${SCRIPT_DIR}/${BACKUP_DIR}" ;;
esac

# Skip lock for read-only + config-management commands. --config-set writes a
# text file atomically via rename, which doesn't conflict with an in-progress deploy.
case "${1:-}" in
    --status|-s|--history|-H|--help|-h|--config-show|--config-set|"")
        # No lock needed — these either read state or atomically write a config file
        ;;
    *)
        acquire_deploy_lock
        ;;
esac

# ============================================================
# Docker Command Detection
# ============================================================
SUDO_PID=""

cleanup_sudo_keepalive() {
    if [ -n "$SUDO_PID" ] && kill -0 "$SUDO_PID" 2>/dev/null; then
        kill "$SUDO_PID" 2>/dev/null || true
    fi
    rm -f "${SUDO_EXPIRED_MARKER:-}" 2>/dev/null || true
}

cleanup_on_exit() {
    local exit_code=$?
    cleanup_sudo_keepalive
    # Only remove the lock pathname if THIS process acquired it. Read-only commands
    # (--status, --history, --config-show, --config-set, --help) never call
    # acquire_deploy_lock, so they must not delete the pathname — another process
    # may be holding the flock on a file-descriptor that still points at this
    # pathname, and recreating the file would defeat the mutual-exclusion contract.
    if [ "$LOCK_ACQUIRED" = true ]; then
        rm -f "${LOCK_FILE:-}" 2>/dev/null || true
    fi

    if [ "$DEPLOY_IN_PROGRESS" = true ] && [ "$exit_code" -ne 0 ]; then
        local phase
        phase=$(cat "$DEPLOY_PHASE_FILE" 2>/dev/null | cut -d'|' -f1 || echo "unknown")
        echo ""
        echo -e "\033[1;33m[WARN]\033[0m  Deployment interrupted (exit code: $exit_code, phase: $phase)"
        echo -e "\033[1;33m[WARN]\033[0m  System may be in an inconsistent state."
        echo -e "\033[1;33m[WARN]\033[0m  Deploy phase preserved in .deploy_phase for recovery detection."
        echo -e "\033[1;33m[WARN]\033[0m  Recovery: run '$0 --status' to check, or '$0 --rollback' to recover."

        # Note: If interrupted during restore_volume, orphaned .restore_tmp/.restore_bak
        # directories may exist in Docker volume paths. Check with:
        #   sudo find /var/lib/docker/volumes -name '*.restore_tmp' -o -name '*.restore_bak'
    fi

    exit "$exit_code"
}

handle_signal() {
    local sig_name=$1
    local sig_code=$2
    echo ""
    echo -e "\033[1;33m[WARN]\033[0m  Received $sig_name signal"

    if [ "$DEPLOY_IN_PROGRESS" = true ]; then
        local phase
        phase=$(cat "$DEPLOY_PHASE_FILE" 2>/dev/null | cut -d'|' -f1 || echo "unknown")
        echo -e "\033[1;33m[WARN]\033[0m  Deploy in progress (phase: $phase)"

        case "$phase" in
            preflight|pulling)
                echo -e "\033[0;32m[OK]\033[0m    No changes made — safe to exit"
                ;;
            stopping|backing_up)
                echo -e "\033[1;33m[WARN]\033[0m  Interrupted during backup — containers may be stopped"
                echo -e "\033[1;33m[WARN]\033[0m  Re-run '$0 <tag>' to retry or '$0 --status' to check"
                ;;
            updating_tag|starting|monitoring|verifying)
                echo -e "\033[1;33m[WARN]\033[0m  Interrupted mid-deploy — rollback recommended"
                echo -e "\033[1;33m[WARN]\033[0m  Run '$0 --rollback' to recover"
                ;;
        esac
    fi
    exit "$sig_code"
}

trap cleanup_on_exit EXIT
trap 'handle_signal "interrupt (Ctrl+C)" 130' INT
trap 'handle_signal "termination" 143' TERM
trap 'handle_signal "terminal disconnect (HUP)" 129' HUP

# ============================================================
# Privilege Detection
# ============================================================
# Two separate concerns:
#   1. NEEDS_DOCKER_SUDO — can we run "docker" commands directly?
#   2. NEEDS_FS_SUDO     — can we read/write Docker volume directories?
#
# These differ when the user is in the "docker" group (Docker works without
# sudo) but volume files are owned by container UIDs (e.g., mysql UID 27/999)
# that the host user cannot read without sudo.
NEEDS_DOCKER_SUDO=false
NEEDS_FS_SUDO=false

# Forward the invoking user's Docker credentials so registry auth
# (manifest inspect, pull, compose pull) works correctly.
#
# Two scenarios:
#   A) "sudo ./cp_upgrade.sh"  → id -u==0, SUDO_USER set → use SUDO_USER's creds
#   B) "./cp_upgrade.sh" but Docker needs sudo → id -u!=0 → use current user's creds
#      (run_docker wraps with "sudo docker --config …")
#
# Without this, sudo docker looks in /root/.docker/config.json which is empty,
# causing "unauthorized" / "manifest unknown" even though the user ran
# "docker login" under their own account.
DOCKER_CONFIG_FLAG=()
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    # Case A: script invoked via "sudo ./cp_upgrade.sh"
    _sudo_user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    if [ -f "${_sudo_user_home}/.docker/config.json" ]; then
        DOCKER_CONFIG_FLAG=(--config "${_sudo_user_home}/.docker")
        export DOCKER_CONFIG="${_sudo_user_home}/.docker"
    fi
elif [ "$(id -u)" -ne 0 ] && [ -f "${HOME}/.docker/config.json" ]; then
    # Case B: script invoked as normal user — Docker may need sudo later.
    # Pre-set the flag so "sudo docker --config …" finds the user's creds.
    DOCKER_CONFIG_FLAG=(--config "${HOME}/.docker")
    export DOCKER_CONFIG="${HOME}/.docker"
fi

# Fast-path: config management commands don't need Docker at all.
# Installing a stub run_docker lets the rest of the script load cleanly without
# requiring a reachable Docker daemon when the user just wants to edit config.
case "${1:-}" in
    --config-show|--config-set|--help|-h|"")
        run_docker() { echo "Error: Docker not available in this invocation" >&2; return 1; }
        # Skip the Docker probe and the compose-project resolution below.
        _skip_docker_probe=1
        ;;
esac

if [ "${_skip_docker_probe:-0}" = "1" ]; then
    : # skip docker info + NEEDS_DOCKER_SUDO detection
elif docker "${DOCKER_CONFIG_FLAG[@]}" info >/dev/null 2>&1; then
    run_docker() { docker "${DOCKER_CONFIG_FLAG[@]}" "$@"; }
else
    # Check if sudo works without a password (NOPASSWD or cached)
    if sudo -n docker info >/dev/null 2>&1; then
        NEEDS_DOCKER_SUDO=true
    else
        # Sudo needs a password — ask the user explicitly
        echo "Docker requires sudo privileges on this system."
        echo "Please enter your password to continue:"
        if sudo docker info >/dev/null 2>&1; then
            NEEDS_DOCKER_SUDO=true
        else
            echo "Error: Cannot access Docker. Add your user to the 'docker' group or check sudo permissions." >&2
            exit 1
        fi
    fi

    run_docker() {
        if [ -f "${SUDO_EXPIRED_MARKER:-}" ]; then
            echo -e "\033[0;31m[ERROR]\033[0m sudo credentials have expired — re-run the script" >&2
            return 1
        fi
        sudo docker "${DOCKER_CONFIG_FLAG[@]}" "$@"
    }
fi

# Probe filesystem access to actual Docker volume mountpoints.
# Docker volume data directories (e.g., mysql_data/_data) are owned by
# container-internal UIDs (mysql=27/999, redis=999, etc.) and are often
# not readable by the host user even when the parent volumes/ dir is listable.
# This function probes the actual volume mountpoint — not just the parent dir —
# to correctly detect whether sudo is needed for tar/du/rm operations.
detect_fs_sudo() {
    local probe_path=""

    # Strategy 1: Inspect the DB container's /var/lib/mysql mount source.
    # This is the most accurate — it resolves named volumes, bind-mounts, and
    # external drivers, and is scoped to the correct Compose project's container.
    probe_path=$(run_docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/mysql"}}{{.Source}}{{end}}{{end}}' "$DB_CONTAINER" 2>/dev/null || echo "")

    # Strategy 2: Find the named volume directly (container may not exist yet on --init)
    if [ -z "$probe_path" ]; then
        local db_vol_name
        db_vol_name=$(run_docker volume ls -q --filter "name=mysql_data" 2>/dev/null | grep -E "mysql_data$" | head -1)
        if [ -n "$db_vol_name" ]; then
            probe_path=$(run_docker volume inspect -f '{{.Mountpoint}}' "$db_vol_name" 2>/dev/null || echo "")
        fi
    fi

    # Strategy 3: Probe Docker root volumes dir (last resort — less accurate)
    if [ -z "$probe_path" ]; then
        local docker_root
        docker_root=$(run_docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "/var/lib/docker")
        probe_path="${docker_root}/volumes"
    fi

    if test -r "$probe_path" 2>/dev/null && ls "$probe_path" >/dev/null 2>&1; then
        # Can read volume directory — no sudo needed for filesystem ops
        NEEDS_FS_SUDO=false
    elif sudo -n test -r "$probe_path" 2>/dev/null; then
        NEEDS_FS_SUDO=true
    elif sudo test -r "$probe_path" 2>/dev/null; then
        NEEDS_FS_SUDO=true
    else
        echo "Error: Cannot access Docker volume path: $probe_path" >&2
        echo "Run with sudo or fix directory permissions." >&2
        exit 1
    fi
}

# Only probe filesystem sudo for mutating commands that touch volumes.
# Read-only commands don't need volume access.
case "${1:-}" in
    --status|-s|--history|-H|--help|-h|--config-show|--config-set|"")
        # No FS sudo detection needed — these either read state or write a text config
        ;;
    *)
        detect_fs_sudo
        ;;
esac

# Start sudo keepalive if ANY operation requires sudo.
# Uses sudo -v (validate) which refreshes credentials without running a command.
# This is more portable than sudo -n true which may be blocked by restrictive
# sudoers configs that only allow NOPASSWD for specific commands.
if [ "$NEEDS_DOCKER_SUDO" = true ] || [ "$NEEDS_FS_SUDO" = true ]; then
    SUDO_EXPIRED_MARKER="${SCRIPT_DIR}/.sudo_expired"
    rm -f "$SUDO_EXPIRED_MARKER"
    ( while true; do
        if ! sudo -n -v 2>/dev/null; then
            touch "$SUDO_EXPIRED_MARKER" 2>/dev/null
            break
        fi
        sleep 50
    done ) &
    SUDO_PID=$!
fi

# Helper: run a filesystem command with sudo when volume paths aren't readable.
# Used for tar, du, chmod, rm on Docker volume directories.
run_maybe_sudo() {
    if [ "$NEEDS_FS_SUDO" = true ]; then
        if [ -f "${SUDO_EXPIRED_MARKER:-}" ]; then
            echo -e "\033[0;31m[ERROR]\033[0m sudo credentials have expired during operation" >&2
            echo -e "\033[0;31m[ERROR]\033[0m Re-run the script or refresh with: sudo -v" >&2
            return 1
        fi
        if ! sudo -n -v 2>/dev/null; then
            echo -e "\033[0;31m[ERROR]\033[0m sudo authentication failed — credentials may have expired" >&2
            echo -e "\033[0;31m[ERROR]\033[0m Re-run the script or refresh with: sudo -v" >&2
            return 1
        fi
        sudo "$@"
    else
        "$@"
    fi
}

# Detect compose command: v2 plugin ("docker compose") vs v1 standalone ("docker-compose").
# Skip when running a config-management or help-only subcommand — those must work on
# hosts where compose isn't installed (e.g., setting up config before Docker is ready).
if [ "${_skip_docker_probe:-0}" = "1" ]; then
    run_compose() {
        echo "Error: Docker Compose not available in this invocation" >&2
        return 1
    }
elif run_docker compose version >/dev/null 2>&1; then
    run_compose() { run_docker compose "$@"; }
elif command -v docker-compose >/dev/null 2>&1; then
    # docker-compose is a standalone binary, needs sudo separately
    if [ "$NEEDS_DOCKER_SUDO" = true ]; then
        run_compose() {
            if [ -f "${SUDO_EXPIRED_MARKER:-}" ]; then
                echo -e "\033[0;31m[ERROR]\033[0m sudo credentials have expired — re-run the script" >&2
                return 1
            fi
            sudo docker-compose "$@"
        }
    else
        run_compose() { docker-compose "$@"; }
    fi
else
    echo "Error: Docker Compose not found (neither 'docker compose' nor 'docker-compose')" >&2
    exit 1
fi

# ============================================================
# Compose Project Name Resolution (deferred until compose is available)
# ============================================================
resolve_compose_project() {
    # Resolve once, cache the result
    if [ -n "$COMPOSE_PROJECT" ]; then
        return
    fi
    # Try docker compose config (outputs resolved 'name:' field — most accurate)
    # --project-directory ensures .env is loaded from the compose file's directory
    if [ -f "$COMPOSE_FILE" ]; then
        local compose_dir
        compose_dir="$(dirname "$COMPOSE_FILE")"
        COMPOSE_PROJECT=$(run_compose --project-directory "$compose_dir" -f "$COMPOSE_FILE" config 2>/dev/null \
            | sed -n 's/^name: *//p' | head -1 || echo "")
    fi
    # Fallback 1: check .env file for COMPOSE_PROJECT_NAME (covers docker-compose v1 and
    # cases where `docker compose config` doesn't support --project-directory)
    if [ -z "$COMPOSE_PROJECT" ] && [ -f "$COMPOSE_FILE" ]; then
        local compose_dir
        compose_dir="$(dirname "$COMPOSE_FILE")"
        if [ -f "${compose_dir}/.env" ]; then
            COMPOSE_PROJECT=$(grep -E '^\s*COMPOSE_PROJECT_NAME\s*=' "${compose_dir}/.env" 2>/dev/null \
                | head -1 | sed 's/^[^=]*=\s*//' | sed 's/\s*$//' | sed "s/^['\"]//; s/['\"]$//" || echo "")
        fi
    fi
    # Fallback 2: derive from directory name (Docker Compose default behavior)
    if [ -z "$COMPOSE_PROJECT" ]; then
        COMPOSE_PROJECT="$(basename "$(dirname "$COMPOSE_FILE")" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g')"
    fi
}
# Skip compose-project resolution for config-management subcommands — they touch
# neither Docker nor compose. Otherwise a missing/unreachable compose file would
# block `--config-set` purely for bookkeeping.
if [ "${_skip_docker_probe:-0}" != "1" ]; then
    resolve_compose_project
    # Export so all run_compose calls use the correct project regardless of cwd
    if [ -n "$COMPOSE_PROJECT" ]; then
        export COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT"
    fi
fi

# ============================================================
# Logging
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()  { echo -e "${BLUE}[INFO]${NC}  $(date +%H:%M:%S) $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $(date +%H:%M:%S) $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date +%H:%M:%S) $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date +%H:%M:%S) $*"; }

# Diagnose why a docker pull failed and log the specific error category
diagnose_pull_failure() {
    local image=$1 output=$2
    if echo "$output" | grep -qiE 'unauthorized|denied|authentication|403|401'; then
        log_error "Authentication error for $image — run: docker login ${DOCKER_REPOSITORY%%/*}"
    elif echo "$output" | grep -qiE 'not found|manifest unknown|404'; then
        log_error "Tag not found in registry for $image — verify the tag exists"
    elif echo "$output" | grep -qiE 'timeout|connection refused|no such host|network'; then
        log_error "Network error pulling $image — check connectivity to Docker registry"
    else
        log_error "Pull failed for $image — docker output below:"
    fi
    # Always show raw output so the user sees the exact error from Docker
    if [ -n "$output" ]; then
        echo "$output" | while IFS= read -r line; do
            echo -e "         $line"
        done
    fi
}

# ============================================================
# State Management
# ============================================================
save_state() {
    local current_tag=$1
    local status=$2
    local rollback_tag=${3:-}
    local backup=${4:-}
    local backup_redis=${5:-}
    local backup_app=${6:-}
    local backup_checksum=${7:-}
    local db_tag=${8:-}
    local rollback_db_tag=${9:-}
    # Arg 10: optional backup_dir_hint override. Default to current $BACKUP_DIR,
    # but callers on failure paths (where they know the original hint must be
    # preserved) can pass the original value explicitly to avoid overwriting it.
    local backup_dir_hint=${10:-$BACKUP_DIR}
    local tmp="${STATE_FILE}.tmp"
    if ! {
        echo "current_tag=${current_tag}"
        echo "rollback_tag=${rollback_tag}"
        echo "status=${status}"
        echo "backup=${backup}"
        echo "backup_redis=${backup_redis}"
        echo "backup_app=${backup_app}"
        echo "backup_checksum=${backup_checksum}"
        echo "db_tag=${db_tag}"
        echo "rollback_db_tag=${rollback_db_tag}"
        # Record the active BACKUP_DIR (or whatever the caller passed as arg 10)
        # purely as a human-readable hint shown in error messages if the operator
        # later tries to rollback with a different BACKUP_DIR. This field MUST NOT
        # be used as a trust anchor: it lives in the same state file as the path
        # it would "trust", so anyone who can tamper with backup= can also tamper
        # with backup_dir_hint. The only trusted prefix for path validation is
        # whatever BACKUP_DIR the current invocation resolved from CLI/env/config
        # — i.e., operator intent, not state content.
        echo "backup_dir_hint=${backup_dir_hint}"
        echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$tmp"; then
        log_warn "Failed to write state file: $tmp (permission denied or disk full)"
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    if ! mv "$tmp" "$STATE_FILE"; then
        log_warn "Failed to save state file: $STATE_FILE"
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
}

read_state_field() {
    # Read a named field from .deploy_state
    local field=$1
    if [ -f "$STATE_FILE" ]; then
        grep -m1 "^${field}=" "$STATE_FILE" 2>/dev/null | cut -d= -f2- || echo ""
    else
        echo ""
    fi
}

read_state() {
    # Backward compat: returns the rollback tag (what we'd revert to)
    local val
    val=$(read_state_field "rollback_tag")
    # Fallback for old-format state files that only have "tag="
    if [ -z "$val" ]; then
        val=$(read_state_field "tag")
    fi
    echo "$val"
}

read_state_status() {
    read_state_field "status"
}

read_state_backup() {
    read_state_field "backup"
}

# ============================================================
# Deploy Phase Tracking (transaction state machine)
# ============================================================
DEPLOY_PHASE_FILE="${SCRIPT_DIR}/.deploy_phase"

save_deploy_phase() {
    # Persist the current deploy phase so interrupted deploys can be detected/recovered.
    # Format: phase|new_tag|rollback_tag|backup_path|timestamp
    # Uses atomic write (tmp+mv) to prevent truncation on crash.
    local phase=$1
    local new_tag=${2:-}
    local rollback_tag=${3:-}
    local backup=${4:-}
    local tmp="${DEPLOY_PHASE_FILE}.tmp"
    if echo "${phase}|${new_tag}|${rollback_tag}|${backup}|$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$DEPLOY_PHASE_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    else
        # Write failed — non-fatal, continue without phase tracking
        rm -f "$tmp" 2>/dev/null || true
    fi
}

read_deploy_phase() {
    if [ -f "$DEPLOY_PHASE_FILE" ]; then
        cut -d'|' -f1 < "$DEPLOY_PHASE_FILE"
    else
        echo ""
    fi
}

read_deploy_phase_field() {
    # Fields: 1=phase, 2=new_tag, 3=rollback_tag, 4=backup, 5=timestamp
    local field_num=$1
    if [ -f "$DEPLOY_PHASE_FILE" ]; then
        cut -d'|' -f"$field_num" < "$DEPLOY_PHASE_FILE"
    else
        echo ""
    fi
}

clear_deploy_phase() {
    rm -f "$DEPLOY_PHASE_FILE" 2>/dev/null || true
}

check_interrupted_restore() {
    # Detect orphaned .restore_bak / .restore_tmp from a crashed restore_volume operation.
    # Called early to alert the operator before they start a new deploy/restore.
    # Journal path is pinned to SCRIPT_DIR (RESTORE_JOURNAL_FILE) to ensure crash
    # recovery works regardless of --backup-dir / BACKUP_DIR changes between runs.
    local journal_file="$RESTORE_JOURNAL_FILE"
    # Legacy location (pre-fix) — check for orphans left by older script versions.
    local legacy_journal="${BACKUP_DIR}/.restore_journal"
    if [ ! -f "$journal_file" ] && [ -f "$legacy_journal" ]; then
        # Migrate: move legacy journal to the pinned location on a best-effort basis
        if mv "$legacy_journal" "$journal_file" 2>/dev/null; then
            log_info "Migrated restore journal from legacy path: $legacy_journal"
        else
            # If we can't move it, still use it in place for this recovery run
            journal_file="$legacy_journal"
        fi
    fi
    if [ ! -f "$journal_file" ]; then
        return 0
    fi

    local j_label j_vol j_state
    j_label=$(grep -o 'label=[^|]*' "$journal_file" 2>/dev/null | cut -d= -f2- || true)
    j_vol=$(grep -o 'vol_path=[^|]*' "$journal_file" 2>/dev/null | cut -d= -f2- || true)
    j_state=$(grep -o 'state=[^|]*' "$journal_file" 2>/dev/null | cut -d= -f2- || true)

    echo ""
    log_warn "=========================================="
    log_warn "  INTERRUPTED VOLUME RESTORE DETECTED"
    log_warn "=========================================="
    log_warn "  Volume:   ${j_label:-unknown}"
    log_warn "  Path:     ${j_vol:-unknown}"
    log_warn "  State:    ${j_state:-unknown}"
    log_warn "=========================================="

    if [ -z "$j_vol" ]; then
        log_warn "Restore journal has empty volume path — removing stale journal"
        run_maybe_sudo rm -f "$journal_file" 2>/dev/null || true
        return 0
    fi

    # Validate j_vol looks like a Docker volume mountpoint (safety against corrupted/tampered journal)
    # Supports standard Docker (/var/lib/docker/volumes/), rootless (~/.local/share/docker/volumes/),
    # and custom data-root configurations
    if [[ "$j_vol" != */volumes/*/_data ]]; then
        log_error "Journal vol_path '${j_vol}' does not look like a Docker volume mountpoint — refusing auto-recovery"
        log_error "Remove the journal manually: ${journal_file}"
        return 1
    fi

    # Check container state — warn if containers are running (data could be in use)
    if is_container_running "$APP_CONTAINER" 2>/dev/null || is_container_running "$DB_CONTAINER" 2>/dev/null; then
        log_warn "Containers are running — auto-recovery will stop them first"
        if ! confirm_action "Stop containers to perform crash recovery?"; then
            log_warn "Skipping auto-recovery — manual intervention may be needed"
            return 0
        fi
        run_compose -f "$COMPOSE_FILE" stop 2>&1 || true
        sleep 2
        # Verify containers actually stopped before touching volume data
        if is_container_running "$APP_CONTAINER" 2>/dev/null || is_container_running "$DB_CONTAINER" 2>/dev/null; then
            log_warn "Containers still running after stop — escalating to docker kill"
            run_docker kill "$APP_CONTAINER" 2>/dev/null || true
            run_docker kill "$DB_CONTAINER" 2>/dev/null || true
            sleep 2
            if is_container_running "$APP_CONTAINER" 2>/dev/null || is_container_running "$DB_CONTAINER" 2>/dev/null; then
                log_error "Containers could not be stopped — skipping auto-recovery to prevent corruption"
                return 1
            fi
        fi
    fi

    if [ -n "$j_vol" ]; then
        if run_maybe_sudo test -d "${j_vol}.restore_bak" 2>/dev/null; then
            if run_maybe_sudo test -d "$j_vol" 2>/dev/null; then
                # New data in place, old data still as backup — restore succeeded, cleanup needed
                log_info "Restored data appears in place. Cleaning up backup..."
                run_maybe_sudo rm -rf "${j_vol}.restore_bak" 2>/dev/null || true
                run_maybe_sudo rm -rf "${j_vol}.restore_tmp" 2>/dev/null || true
                run_maybe_sudo rm -f "$journal_file" 2>/dev/null || true
                log_ok "Cleanup complete"
            else
                # Vol path missing but backup exists — recover from backup
                log_warn "Volume path missing but original backup exists — recovering..."
                if run_maybe_sudo mv "${j_vol}.restore_bak" "$j_vol" 2>/dev/null; then
                    log_ok "Original ${j_label} data recovered from backup"
                else
                    log_error "Failed to recover — manual intervention needed"
                    log_error "Original data at: ${j_vol}.restore_bak"
                fi
                run_maybe_sudo rm -rf "${j_vol}.restore_tmp" 2>/dev/null || true
                run_maybe_sudo rm -f "$journal_file" 2>/dev/null || true
            fi
        elif run_maybe_sudo test -d "${j_vol}.restore_tmp" 2>/dev/null; then
            # Extraction was in progress — clean up temp
            log_info "Incomplete extraction found — cleaning up..."
            run_maybe_sudo rm -rf "${j_vol}.restore_tmp" 2>/dev/null || true
            run_maybe_sudo rm -f "$journal_file" 2>/dev/null || true
            log_ok "Cleanup complete — original data is intact"
        else
            # Journal exists but no orphaned dirs — just clean journal
            run_maybe_sudo rm -f "$journal_file" 2>/dev/null || true
        fi
    fi
    echo ""
}

check_interrupted_deploy() {
    # Called at the start of a new deploy to detect and warn about interrupted prior deploys
    local phase
    phase=$(read_deploy_phase)
    if [ -z "$phase" ] || [ "$phase" = "complete" ]; then
        return 0
    fi

    local phase_tag phase_rollback phase_time
    phase_tag=$(read_deploy_phase_field 2)
    phase_rollback=$(read_deploy_phase_field 3)
    phase_time=$(read_deploy_phase_field 5)

    echo ""
    log_warn "=========================================="
    log_warn "  INTERRUPTED DEPLOY DETECTED"
    log_warn "=========================================="
    log_warn "  Phase:      ${phase}"
    log_warn "  Tag:        ${phase_tag}"
    log_warn "  Rollback:   ${phase_rollback}"
    log_warn "  Timestamp:  ${phase_time}"
    log_warn "=========================================="
    echo ""

    case "$phase" in
        preflight|pulling)
            log_info "Interrupted before any changes — safe to proceed"
            clear_deploy_phase
            ;;
        stopping|backing_up)
            log_warn "Interrupted during backup phase — containers may be stopped"
            log_warn "Recommend: check container status with --status before proceeding"
            if ! confirm_action "Clear interrupted state and proceed with new deploy?"; then
                log_info "Use '$0 --status' to check, or '$0 --rollback' to recover"
                exit 1
            fi
            clear_deploy_phase
            ;;
        updating_tag|starting|monitoring|verifying)
            log_warn "Interrupted mid-deploy — system may be in inconsistent state"
            log_warn "Recommended action: rollback to $phase_rollback"
            echo ""
            echo "  1) Rollback to previous version ($phase_rollback)"
            echo "  2) Continue with new deploy (overwrite)"
            echo "  3) Cancel"
            echo ""
            local choice
            read -r -p "  Choose (1/2/3): " choice
            case "$choice" in
                1)
                    if do_rollback_internal "$phase_rollback" "Recovery from interrupted deploy"; then
                        clear_deploy_phase
                        exit 0
                    else
                        save_deploy_phase "rollback_failed" "$phase_tag" "$phase_rollback"
                        exit 1
                    fi
                    ;;
                2)
                    log_info "Clearing interrupted state and proceeding..."
                    clear_deploy_phase
                    ;;
                *)
                    log_info "Cancelled. Use '$0 --status' to check state."
                    exit 0
                    ;;
            esac
            ;;
        *)
            log_warn "Unknown phase '$phase' — clearing"
            clear_deploy_phase
            ;;
    esac
}

validate_tag() {
    local tag=$1
    # Docker tags: alphanumeric, periods, hyphens, underscores, max 128 chars
    if [[ ! "$tag" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$ ]]; then
        log_error "Invalid tag format: '$tag'"
        log_error "Tags must start with alphanumeric, contain only [a-zA-Z0-9._-], max 128 chars"
        exit 1
    fi
}

_get_service_tag() {
    # Extract image tag for a specific compose service by name (app or db).
    # Scoped to the services: section, then finds the named service block.
    # End-of-block is detected by the next service header (same indent level),
    # a top-level key, or EOF — so key ordering within a service doesn't matter.
    local service=$1
    local tag=""

    # Extract the services: section first, then find the named service block.
    # Service headers are at 2-space indent; their properties at 4+ spaces.
    # The range ends at the next 2-space key (next service) or top-level key or EOF.
    # Escape DOCKER_REPOSITORY for safe use in grep/sed regex (handles dots, etc.)
    local escaped_repo
    escaped_repo=$(printf '%s' "$DOCKER_REPOSITORY" | sed 's/[.[\*^$()+?{|\\]/\\&/g')
    tag=$(sed -n '/^services:/,/^[a-z]/p' "$COMPOSE_FILE" 2>/dev/null | \
        sed -n "/^  ${service}:/,/^  [a-z]/p" | \
        grep -v '^\s*#' | grep -m1 "image:.*${escaped_repo}:" | \
        sed "s|.*${escaped_repo}:||" | sed 's/#.*//' | tr -d ' "'"'"'' || echo "")
    echo "$tag"
}

get_current_tag() {
    # Parse app image tag from compose file by service name
    _get_service_tag "app"
}

get_db_tag() {
    # Parse db image tag from compose file by service name
    _get_service_tag "db"
}

set_image_tag() {
    local new_tag=$1
    local current_tag
    current_tag=$(get_current_tag)
    # Update only the app image tag (not db)
    if [ -z "$current_tag" ]; then
        log_error "Cannot determine current app image tag from $COMPOSE_FILE"
        return 1
    fi
    if [ ! -w "$COMPOSE_FILE" ]; then
        log_error "Cannot write to $COMPOSE_FILE — check file permissions"
        return 1
    fi
    # Backup compose file before modification (auto-restore on failure)
    if [ ! -f "${COMPOSE_FILE}.bak" ]; then
        cp "$COMPOSE_FILE" "${COMPOSE_FILE}.bak"
    fi
    # Escape current_tag for safe use in sed (handles dots, plus signs, etc.)
    local escaped_tag
    escaped_tag=$(printf '%s' "$current_tag" | sed 's/[.[\*^$()+?{|\\]/\\&/g')
    # Scope replacement to the 'app:' service block only (prevents cross-service collision)
    sed -i "/^  app:/,/^  [a-z]/ s|image: ${DOCKER_REPOSITORY}:${escaped_tag}|image: ${DOCKER_REPOSITORY}:${new_tag}|" "$COMPOSE_FILE"
    # Verify the replacement actually happened
    local verify_tag
    verify_tag=$(get_current_tag)
    if [ "$verify_tag" != "$new_tag" ]; then
        log_error "Image tag update failed: expected '$new_tag', found '$verify_tag' in $COMPOSE_FILE"
        log_warn "Restoring docker-compose.yml from backup"
        cp "${COMPOSE_FILE}.bak" "$COMPOSE_FILE"
        return 1
    fi
}

set_db_image_tag() {
    local new_tag=$1
    local current_db_tag
    current_db_tag=$(get_db_tag)
    # Update only the db image tag (not app)
    if [ -z "$current_db_tag" ]; then
        log_error "Cannot determine current DB image tag from $COMPOSE_FILE"
        return 1
    fi
    if [ ! -w "$COMPOSE_FILE" ]; then
        log_error "Cannot write to $COMPOSE_FILE — check file permissions"
        return 1
    fi
    # Backup compose file before modification (auto-restore on failure)
    if [ ! -f "${COMPOSE_FILE}.bak" ]; then
        cp "$COMPOSE_FILE" "${COMPOSE_FILE}.bak"
    fi
    # Escape current_db_tag for safe use in sed
    local escaped_db_tag
    escaped_db_tag=$(printf '%s' "$current_db_tag" | sed 's/[.[\*^$()+?{|\\]/\\&/g')
    # Scope replacement to the 'db:' service block only (prevents cross-service collision)
    sed -i "/^  db:/,/^  [a-z]/ s|image: ${DOCKER_REPOSITORY}:${escaped_db_tag}|image: ${DOCKER_REPOSITORY}:${new_tag}|" "$COMPOSE_FILE"
    # Verify the replacement actually happened
    local verify_tag
    verify_tag=$(get_db_tag)
    if [ "$verify_tag" != "$new_tag" ]; then
        log_error "DB image tag update failed: expected '$new_tag', found '$verify_tag' in $COMPOSE_FILE"
        log_warn "Restoring docker-compose.yml from backup"
        cp "${COMPOSE_FILE}.bak" "$COMPOSE_FILE"
        return 1
    fi
}

validate_backup_path() {
    # Security: ensure backup_file has a safe filename pattern and lives under a
    # trusted backup directory. Prevents path traversal via tampered .meta or
    # .deploy_state files.
    #
    # Usage:
    #   validate_backup_path <filepath>                   # uses current BACKUP_DIR
    #   validate_backup_path <filepath> <extra_prefix>    # allows files under <extra_prefix>
    #
    # SECURITY: the <extra_prefix> argument is only for prefixes that were set by
    # OPERATOR INTENT in the current invocation (e.g., via --backup-dir CLI flag
    # or the active BACKUP_DIR env/config at script startup). Callers MUST NOT
    # derive the extra prefix from untrusted on-disk state (e.g., .deploy_state
    # fields, snapshot .meta fields, or dirname() of a path read from those
    # files) — doing so creates a circular trust relationship that defeats this
    # function's guarantees.
    local filepath=$1
    local extra_prefix=${2:-}
    if [ -z "$filepath" ]; then
        return 1
    fi
    # Resolve to absolute path (without requiring file to exist)
    local resolved
    resolved=$(cd "$(dirname "$filepath")" 2>/dev/null && pwd)/$(basename "$filepath") 2>/dev/null || resolved=""
    if [ -z "$resolved" ]; then
        return 1
    fi

    # Strict filename pattern — non-negotiable (prevents path traversal / arbitrary paths)
    local base
    base=$(basename "$resolved")
    if ! [[ "$base" =~ ^(db|redis|cloudpi)_volume_[0-9]{8}_[0-9]{6}\.tar(\.enc)?$ ]]; then
        return 1
    fi

    # Resolve trusted prefixes. We accept the current BACKUP_DIR plus the optional
    # extra prefix (used by rollback). Both are resolved to absolute form.
    local abs_backup_dir abs_extra
    abs_backup_dir=$(cd "$BACKUP_DIR" 2>/dev/null && pwd) || abs_backup_dir="$BACKUP_DIR"
    abs_extra=""
    if [ -n "$extra_prefix" ]; then
        abs_extra=$(cd "$extra_prefix" 2>/dev/null && pwd) || abs_extra="$extra_prefix"
    fi

    case "$resolved" in
        "${abs_backup_dir}"/*) return 0 ;;
    esac
    if [ -n "$abs_extra" ]; then
        case "$resolved" in
            "${abs_extra}"/*) return 0 ;;
        esac
    fi
    return 1
}

# ============================================================
# Compose File Guard (for read-only commands)
# ============================================================
require_compose_file() {
    if [ ! -f "$COMPOSE_FILE" ]; then
        log_error "docker-compose.yml not found at: $COMPOSE_FILE"
        log_error "cp_upgrade.sh must be located in the same directory as docker-compose.yml"
        exit 1
    fi
}

# ============================================================
# Prerequisites
# ============================================================
check_prerequisites() {
    log_info "Checking prerequisites..."
    local failed=false

    # Docker (already detected above, just report)
    log_ok "Docker: $(run_docker --version | head -1)"
    if [ "$NEEDS_DOCKER_SUDO" = true ]; then
        log_info "Using sudo for Docker commands"
    fi
    if [ "$NEEDS_FS_SUDO" = true ]; then
        log_info "Using sudo for volume filesystem operations (volume files owned by container UIDs)"
    fi

    # Docker Compose (already detected above, just report)
    log_ok "Docker Compose: $(run_compose version --short 2>/dev/null || run_compose --version 2>/dev/null | head -1)"

    # Compose file
    if [ ! -f "$COMPOSE_FILE" ]; then
        log_error "docker-compose.yml not found at: $COMPOSE_FILE"
        failed=true
    else
        log_ok "Compose file: $COMPOSE_FILE"
    fi

    # .env file (needed for DB secrets, etc.)
    if [ ! -f "$ENV_FILE" ]; then
        log_warn ".env file not found at: $ENV_FILE — compose may fail if it references env vars"
    else
        log_ok "Environment file: $ENV_FILE"
    fi

    # Secrets file — resolve path from docker compose config (handles env vars, anchors, etc.)
    local secrets_path=""
    if [ -f "$COMPOSE_FILE" ]; then
        # docker compose config outputs fully resolved YAML with absolute paths
        secrets_path=$(run_compose -f "$COMPOSE_FILE" config 2>/dev/null \
            | sed -n '/^secrets:/,/^[a-z]/{ /file:/{ s/.*file: *//; s/ *$//; p; q; } }' || echo "")
    fi
    if [ -n "$secrets_path" ]; then
        if [ ! -f "$secrets_path" ]; then
            log_warn "Secrets file not found: $secrets_path (resolved from $COMPOSE_FILE)"
        else
            log_ok "Secrets file: $secrets_path"
        fi
    else
        log_warn "Could not resolve secrets file path from $COMPOSE_FILE — verify secrets config"
    fi

    if [ "$failed" = true ]; then
        log_error "Prerequisites check failed"
        exit 1
    fi

    log_ok "All prerequisites passed"
}

# ============================================================
# Pre-flight Checks (run before any destructive deploy action)
# ============================================================
preflight_check() {
    # Usage: preflight_check <new_tag> [db_tag]
    # Validates everything BEFORE stopping containers or modifying state.
    local new_tag=$1
    local db_tag=${2:-}
    local failed=false

    log_info "Running pre-flight checks..."

    # 1. Compose file syntax validation
    #    Catches corruption from a previous failed run (e.g., broken sed)
    #    Try --quiet first (compose v2.20+), fall back to redirecting output (older versions)
    if run_compose -f "$COMPOSE_FILE" config --quiet 2>/dev/null || run_compose -f "$COMPOSE_FILE" config >/dev/null 2>&1; then
        log_ok "Compose file syntax valid"
    else
        log_error "docker-compose.yml is invalid — run: docker compose -f $COMPOSE_FILE config"
        log_error "This may indicate corruption from a previous failed deployment"
        failed=true
    fi

    # 2. State file sanity check
    #    Detect truncated/corrupted state from a prior crash during save_state
    if [ -f "$STATE_FILE" ]; then
        local state_lines
        state_lines=$(wc -l < "$STATE_FILE" 2>/dev/null || echo "0")
        if [ "$state_lines" -lt 3 ]; then
            log_warn "State file appears truncated ($state_lines lines) — may be from a crashed deploy"
            log_warn "Rollback info may be unreliable"
        fi
        # Check for temp state file left behind (crash during atomic write)
        if [ -f "${STATE_FILE}.tmp" ]; then
            log_warn "Found stale ${STATE_FILE}.tmp — removing (from previous crash)"
            rm -f "${STATE_FILE}.tmp" 2>/dev/null || true
        fi
    fi

    # 3. Registry connectivity + image existence check
    #    Verify the image exists BEFORE stopping anything.
    #    Falls back to local cache if registry is unreachable (air-gapped/offline deploys).
    local full_image="${DOCKER_REPOSITORY}:${new_tag}"
    log_info "Verifying image exists: $full_image"
    if run_docker manifest inspect "$full_image" >/dev/null 2>&1; then
        log_ok "Image verified (registry): $full_image"
    elif run_docker image inspect "$full_image" >/dev/null 2>&1; then
        log_warn "Registry unreachable but image found in local cache: $full_image"
        log_warn "Proceeding with cached image — no registry verification"
    elif run_docker pull "$full_image" >/dev/null 2>&1; then
        log_ok "Image pulled from registry: $full_image"
    else
        log_error "Image not accessible: $full_image"
        log_error "Not found in registry or local cache"
        failed=true
    fi

    # Verify DB image if provided
    if [ -n "$db_tag" ]; then
        local full_db_image="${DOCKER_REPOSITORY}:${db_tag}"
        log_info "Verifying DB image exists: $full_db_image"
        if run_docker manifest inspect "$full_db_image" >/dev/null 2>&1; then
            log_ok "DB image verified (registry): $full_db_image"
        elif run_docker image inspect "$full_db_image" >/dev/null 2>&1; then
            log_warn "Registry unreachable but DB image found in local cache: $full_db_image"
        elif run_docker pull "$full_db_image" >/dev/null 2>&1; then
            log_ok "DB image pulled from registry: $full_db_image"
        else
            log_error "DB image not accessible: $full_db_image"
            failed=true
        fi
    fi

    # 4. Disk space check for backup directory
    #    Estimate needed space from current DB volume size
    local db_vol_path
    db_vol_path=$(get_volume_path "mysql_data" "$DB_CONTAINER" "/var/lib/mysql")
    if [ -n "$db_vol_path" ]; then
        local vol_size_kb avail_kb
        vol_size_kb=$(run_maybe_sudo du -sk "$db_vol_path" 2>/dev/null | cut -f1 || echo "0")
        avail_kb=$(df -k "$BACKUP_DIR" 2>/dev/null | tail -1 | awk '{print $4}' || echo "0")
        # Need ~1.5x volume size: DB tar is roughly 1x, Redis + App backups are negligible
        local needed_kb=$((vol_size_kb * 3 / 2))
        if [ "$vol_size_kb" -gt 0 ] && [ "$avail_kb" -gt 0 ] && [ "$avail_kb" -lt "$needed_kb" ]; then
            log_error "Insufficient disk space for backups"
            log_error "  Estimated need: ~$((needed_kb / 1024))MB, Available: ~$((avail_kb / 1024))MB"
            failed=true
        elif [ "$vol_size_kb" -gt 0 ] && [ "$avail_kb" -gt 0 ]; then
            log_ok "Disk space OK (~$((avail_kb / 1024))MB available, ~$((needed_kb / 1024))MB needed)"
        fi
    fi

    # 5. Backup directory writable
    if ! mkdir -p "$BACKUP_DIR" 2>/dev/null; then
        log_error "Cannot create backup directory: $BACKUP_DIR"
        failed=true
    elif [ ! -w "$BACKUP_DIR" ]; then
        log_error "Backup directory not writable: $BACKUP_DIR"
        failed=true
    fi

    # 6. Compose file writable (needed for tag update)
    if [ ! -w "$COMPOSE_FILE" ]; then
        log_error "docker-compose.yml is not writable — check file permissions"
        failed=true
    fi

    if [ "$failed" = true ]; then
        log_error "Pre-flight checks failed — no changes made"
        return 1
    fi

    log_ok "All pre-flight checks passed"
    return 0
}

# ============================================================
# Container Helpers
# ============================================================
is_container_running() {
    local name=$1
    run_docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -q "true"
}

stop_and_remove_app() {
    log_info "Stopping app container..."
    run_compose -f "$COMPOSE_FILE" stop app 2>&1 || true

    # Verify container actually stopped (don't proceed with backup if still writing)
    sleep 2
    if is_container_running "$APP_CONTAINER"; then
        log_warn "App container still running after stop — escalating to docker kill"
        run_docker kill "$APP_CONTAINER" 2>/dev/null || true
        sleep 2
        if is_container_running "$APP_CONTAINER"; then
            log_error "App container did not stop even after docker kill"
            return 1
        fi
    fi

    run_compose -f "$COMPOSE_FILE" rm -f app 2>&1 || true
}

stop_db_verified() {
    local timeout=${1:-60}
    log_info "Stopping DB container (timeout: ${timeout}s)..."

    # Don't swallow stderr — log it so failures are visible
    if ! run_compose -f "$COMPOSE_FILE" stop -t "$timeout" db 2>&1; then
        log_warn "docker compose stop returned non-zero — checking container state..."
    fi

    # Give Docker a moment to update container state after stop returns
    sleep 3

    # Verify container actually stopped
    local state
    state=$(run_docker inspect -f '{{.State.Running}}' "$DB_CONTAINER" 2>/dev/null || echo "false")
    if [ "$state" = "true" ]; then
        log_warn "DB container still running after graceful stop — escalating to docker kill"
        run_docker kill "$DB_CONTAINER" 2>/dev/null || true
        sleep 3

        # Re-check after kill
        state=$(run_docker inspect -f '{{.State.Running}}' "$DB_CONTAINER" 2>/dev/null || echo "false")
        if [ "$state" = "true" ]; then
            log_error "DB container did not stop even after docker kill"
            log_error "Docker daemon may be unresponsive — manual intervention required"
            return 1
        fi
        log_warn "DB container stopped via docker kill (ungraceful shutdown)"
    fi

    sleep 2
}

confirm_action() {
    local prompt=${1:-"Proceed?"}
    if [ "$AUTO_YES" = true ]; then
        echo "$prompt (y/N): y (--yes)"
        return 0
    fi
    # In non-interactive mode (no TTY), default to "no" to prevent hangs
    if [ ! -t 0 ]; then
        echo "$prompt (y/N): n (non-interactive, use --yes to auto-confirm)"
        return 1
    fi
    local response
    read -r -p "$prompt (y/N): " response
    [ "$response" = "y" ] || [ "$response" = "Y" ]
}

wait_for_db() {
    log_info "Waiting for DB container to be healthy (max ${DB_WAIT_TIMEOUT}s)..."
    local elapsed=0

    while [ "$elapsed" -lt "$DB_WAIT_TIMEOUT" ]; do
        local health
        health=$(run_docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' "$DB_CONTAINER" 2>/dev/null || echo "missing")

        if [ "$health" = "healthy" ]; then
            log_ok "DB container is healthy"
            return 0
        fi

        # Fallback: if no Docker healthcheck defined, probe MySQL directly
        if [ "$health" = "missing" ] || [ "$health" = "" ] || [ "$health" = "<no value>" ]; then
            if is_container_running "$DB_CONTAINER"; then
                if run_docker exec "$DB_CONTAINER" mysqladmin ping -h 127.0.0.1 --silent 2>/dev/null; then
                    log_ok "DB container is responding (no Docker healthcheck, mysqladmin ping OK)"
                    return 0
                fi
            fi
        fi

        # Check if container died
        if ! is_container_running "$DB_CONTAINER"; then
            log_error "DB container stopped while waiting for health"
            return 1
        fi

        sleep 3
        elapsed=$((elapsed + 3))
    done

    # Final fallback: container running but health never reported
    if is_container_running "$DB_CONTAINER"; then
        if run_docker exec "$DB_CONTAINER" mysqladmin ping -h 127.0.0.1 --silent 2>/dev/null; then
            log_warn "No Docker healthcheck — DB responding to mysqladmin ping, treating as healthy"
            return 0
        fi
    fi

    log_error "DB container not healthy after ${DB_WAIT_TIMEOUT}s"
    return 1
}

clear_migration_lockout() {
    # Find the volume mount path on the host filesystem.
    # Works even when the container is stopped/removed by inspecting the named volume directly.
    local volume_mount=""
    volume_mount=$(get_volume_path "cloudpi$" "$APP_CONTAINER" "/app/backups")

    if [ -n "$volume_mount" ]; then
        if run_maybe_sudo test -f "${volume_mount}/.migration_lockout" 2>/dev/null; then
            run_maybe_sudo rm -f "${volume_mount}/.migration_lockout" 2>/dev/null || true
            log_info "Cleared migration lockout file"
        fi
    fi
}

# ============================================================
# Volume Backup / Restore (generic)
# ============================================================
get_volume_path() {
    # Usage: get_volume_path <volume_filter> <container> <mount_dest>
    local volume_filter=$1
    local container=$2
    local mount_dest=$3

    # Try via container mount first (container can be stopped but must exist)
    local vol_path
    vol_path=$(run_docker inspect -f "{{range .Mounts}}{{if eq .Destination \"${mount_dest}\"}}{{.Source}}{{end}}{{end}}" "$container" 2>/dev/null || echo "")

    # Fallback: find the named volume using compose project prefix for unambiguous matching.
    # Docker Compose names volumes as {project}_{volume} (e.g., dockerbuilds_mysql_data).
    # First try exact project-scoped match, then fall back to substring match.
    if [ -z "$vol_path" ]; then
        local vol_name=""
        local docker_filter="${volume_filter%\$}"  # Strip trailing $ if present (Docker uses substring match)
        local escaped_filter
        escaped_filter=$(printf '%s' "${docker_filter}" | sed 's/[.[\*^$()+?{|\\]/\\&/g')

        # Try project-scoped exact match first (e.g., "dockerbuilds_mysql_data")
        if [ -n "$COMPOSE_PROJECT" ]; then
            local project_vol="${COMPOSE_PROJECT}_${docker_filter}"
            vol_name=$(run_docker volume ls -q --filter "name=${project_vol}" 2>/dev/null \
                | grep -Fx "$project_vol" | head -1 || true)
        fi

        # Fall back to escaped regex match (handles non-standard project names)
        if [ -z "$vol_name" ]; then
            vol_name=$(run_docker volume ls -q --filter "name=${docker_filter}" 2>/dev/null \
                | grep -E "${escaped_filter}\$" | head -1 || true)
        fi

        if [ -n "$vol_name" ]; then
            vol_path=$(run_docker volume inspect -f '{{.Mountpoint}}' "$vol_name" 2>/dev/null || echo "")
        fi
    fi

    echo "$vol_path"
}

# ============================================================
# Backup Encryption Helpers (openssl AES-256-CBC + PBKDF2)
# ============================================================
# When BACKUP_ENCRYPT=1, tar streams are piped through openssl enc.
# Files get ".enc" suffix. Restore auto-detects via filename or meta.
is_encryption_enabled() {
    [ "${BACKUP_ENCRYPT:-0}" = "1" ] || [ "${BACKUP_ENCRYPT:-0}" = "true" ]
}

# Validate key file is usable. Call at start of any op that creates/reads encrypted backups.
require_encryption_key() {
    if ! is_encryption_enabled; then
        return 0
    fi
    if ! command -v openssl >/dev/null 2>&1; then
        log_error "BACKUP_ENCRYPT=1 but 'openssl' binary not found in PATH"
        return 1
    fi
    if [ -z "${BACKUP_KEY_FILE:-}" ]; then
        log_error "BACKUP_ENCRYPT=1 but BACKUP_KEY_FILE is not set"
        return 1
    fi
    if [ ! -f "$BACKUP_KEY_FILE" ]; then
        log_error "Backup key file not found: $BACKUP_KEY_FILE"
        return 1
    fi
    if [ ! -r "$BACKUP_KEY_FILE" ]; then
        log_error "Backup key file not readable (check permissions): $BACKUP_KEY_FILE"
        return 1
    fi
    local perms
    perms=$(stat -c '%a' "$BACKUP_KEY_FILE" 2>/dev/null || stat -f '%A' "$BACKUP_KEY_FILE" 2>/dev/null || echo "")
    if [ -n "$perms" ] && [ "${perms: -2}" != "00" ]; then
        log_warn "Backup key file has loose permissions ($perms) — recommend chmod 600"
    fi
    local size
    size=$(stat -c '%s' "$BACKUP_KEY_FILE" 2>/dev/null || stat -f '%z' "$BACKUP_KEY_FILE" 2>/dev/null || echo "0")
    if [ "$size" -lt 16 ]; then
        log_error "Backup key file is suspiciously small ($size bytes) — min 16 bytes recommended"
        return 1
    fi
    return 0
}

# Append ".enc" to a tar filename when encryption is enabled
maybe_enc_suffix() {
    local f=$1
    if is_encryption_enabled; then
        echo "${f}.enc"
    else
        echo "$f"
    fi
}

# Check if a backup file is encrypted (by filename or meta hint)
is_backup_encrypted() {
    local backup_file=$1
    case "$backup_file" in
        *.tar.enc|*.enc) return 0 ;;
        *) return 1 ;;
    esac
}

backup_volume() {
    # Usage: backup_volume <label> <volume_filter> <container> <mount_dest> <backup_file>
    local label=$1
    local volume_filter=$2
    local container=$3
    local mount_dest=$4
    local backup_file=$5

    local vol_path
    vol_path=$(get_volume_path "$volume_filter" "$container" "$mount_dest")

    if [ -z "$vol_path" ]; then
        log_error "Cannot find ${label} volume path"
        return 1
    fi

    log_info "Backing up ${label} volume: $vol_path"

    # Pre-check sudo before multi-step backup operation
    if [ "$NEEDS_FS_SUDO" = true ] && ! sudo -n -v 2>/dev/null; then
        log_error "sudo credentials expired before ${label} backup — re-run the script"
        return 1
    fi

    if ! mkdir -p "$BACKUP_DIR" 2>/dev/null; then
        log_error "Cannot create backup directory: $BACKUP_DIR — check permissions"
        return 1
    fi
    if [ ! -w "$BACKUP_DIR" ]; then
        log_error "Backup directory is not writable: $BACKUP_DIR — check permissions"
        return 1
    fi

    # Check available disk space vs volume size (rough estimate)
    local vol_size_kb avail_kb
    vol_size_kb=$(run_maybe_sudo du -sk "$vol_path" 2>/dev/null | cut -f1 || echo "0")
    avail_kb=$(df -k "$BACKUP_DIR" 2>/dev/null | tail -1 | awk '{print $4}' || echo "0")
    if [ "$vol_size_kb" -gt 0 ] && [ "$avail_kb" -gt 0 ] && [ "$avail_kb" -lt "$vol_size_kb" ]; then
        log_error "Insufficient disk space for ${label} backup"
        log_error "  Volume size: ~$((vol_size_kb / 1024))MB, Available: ~$((avail_kb / 1024))MB"
        return 1
    fi

    # tar the volume directory (preserves permissions, ownership, symlinks).
    # The caller decides the filename convention: pass a path ending in `.tar` for plain
    # backups, `.tar.enc` for encrypted backups. This function does NOT rename the output.
    # When BACKUP_ENCRYPT=1, stream through openssl enc (no plaintext on disk).
    # Consistency check: mismatch between BACKUP_ENCRYPT and filename extension is a bug.
    if is_encryption_enabled; then
        case "$backup_file" in
            *.enc) : ;;  # OK
            *)
                log_error "Internal: BACKUP_ENCRYPT=1 but caller passed non-.enc path: $backup_file"
                log_error "Caller must use maybe_enc_suffix() to derive the correct filename"
                return 1
                ;;
        esac
        if ! require_encryption_key; then
            return 1
        fi
    else
        case "$backup_file" in
            *.enc)
                log_error "Internal: BACKUP_ENCRYPT=0 but caller passed .enc path: $backup_file"
                return 1
                ;;
        esac
    fi

    local tar_rc=0
    if is_encryption_enabled; then
        log_info "Encrypting ${label} backup with ${BACKUP_ENC_CIPHER}"
        # pipefail captures either tar or openssl exit codes
        set -o pipefail
        run_maybe_sudo bash -c "tar --selinux -cf - -C '$vol_path' . | openssl enc -${BACKUP_ENC_CIPHER} -pbkdf2 -salt -pass file:'$BACKUP_KEY_FILE' -out '$backup_file'" || tar_rc=$?
        set +o pipefail
        if [ "$tar_rc" -ne 0 ]; then
            log_error "encrypted tar pipeline failed (exit $tar_rc) — ${label} backup incomplete"
            run_maybe_sudo rm -f "$backup_file" 2>/dev/null || true
            return 1
        fi
    else
        # --selinux preserves SELinux labels on RHEL/AlmaLinux; silently ignored when SELinux is inactive
        run_maybe_sudo tar --selinux -cf "$backup_file" -C "$vol_path" . || tar_rc=$?
        if [ "$tar_rc" -ne 0 ]; then
            log_error "tar command failed (exit $tar_rc) — ${label} backup incomplete"
            run_maybe_sudo rm -f "$backup_file" 2>/dev/null || true
            return 1
        fi
    fi

    # Restrict backup file permissions (contains sensitive DB data)
    run_maybe_sudo chmod 600 "$backup_file" 2>/dev/null || true

    if [ ! -s "$backup_file" ]; then
        log_error "${label} backup file is empty"
        return 1
    fi

    # Validate archive integrity (decrypt inline if encrypted)
    if is_backup_encrypted "$backup_file"; then
        if ! run_maybe_sudo bash -c "openssl enc -d -${BACKUP_ENC_CIPHER} -pbkdf2 -pass file:'$BACKUP_KEY_FILE' -in '$backup_file' | tar -tf - >/dev/null" 2>/dev/null; then
            log_error "${label} encrypted backup failed integrity check (bad key or corrupt file)"
            run_maybe_sudo rm -f "$backup_file" 2>/dev/null || true
            return 1
        fi
    else
        if ! run_maybe_sudo tar -tf "$backup_file" >/dev/null 2>&1; then
            log_error "${label} backup archive is corrupt (tar -tf failed)"
            run_maybe_sudo rm -f "$backup_file" 2>/dev/null || true
            return 1
        fi
    fi

    # Size sanity check: compare backup with source volume (non-fatal)
    local size size_kb
    size=$(run_maybe_sudo du -sh "$backup_file" 2>/dev/null | cut -f1 || echo "?")
    size_kb=$(run_maybe_sudo du -sk "$backup_file" 2>/dev/null | cut -f1 || echo "0")
    if [ "$size_kb" -gt 0 ] && [ "$vol_size_kb" -gt 0 ]; then
        # Warn if backup is less than 10% of source volume (likely truncated)
        local min_expected=$((vol_size_kb / 10))
        if [ "$size_kb" -lt "$min_expected" ] && [ "$min_expected" -gt 100 ]; then
            log_warn "${label} backup seems unusually small ($size vs ~$((vol_size_kb / 1024))MB source)"
            log_warn "Archive may be incomplete — verify manually if concerned"
        fi
    fi

    log_ok "${label} volume backup saved: $backup_file ($size, verified)"
}

restore_volume() {
    # Usage: restore_volume <label> <volume_filter> <container> <mount_dest> <backup_file>
    local label=$1
    local volume_filter=$2
    local container=$3
    local mount_dest=$4
    local backup_file=$5

    local vol_path
    vol_path=$(get_volume_path "$volume_filter" "$container" "$mount_dest")

    if [ -z "$vol_path" ]; then
        log_error "Cannot find ${label} volume path"
        return 1
    fi

    if [ ! -f "$backup_file" ] || [ ! -s "$backup_file" ]; then
        log_error "${label} backup file not found or empty: $backup_file"
        return 1
    fi

    log_info "Restoring ${label} volume from: $backup_file"

    # Pre-check sudo before multi-step restore operation
    if [ "$NEEDS_FS_SUDO" = true ] && ! sudo -n -v 2>/dev/null; then
        log_error "sudo credentials expired before ${label} restore — re-run the script"
        return 1
    fi

    # Check available disk space before extraction
    local backup_size_kb avail_kb
    backup_size_kb=$(run_maybe_sudo du -sk "$backup_file" 2>/dev/null | cut -f1 || echo "0")
    avail_kb=$(df -k "$(dirname "$vol_path")" 2>/dev/null | tail -1 | awk '{print $4}' || echo "0")
    # Extracted data is typically larger than the tar (uncompressed), use 1.5x estimate
    local needed_kb=$(( backup_size_kb * 3 / 2 ))
    if [ "$needed_kb" -gt 0 ] && [ "$avail_kb" -gt 0 ] && [ "$avail_kb" -lt "$needed_kb" ]; then
        log_error "Insufficient disk space for ${label} restore"
        log_error "  Backup size: ~$((backup_size_kb / 1024))MB, Available: ~$((avail_kb / 1024))MB, Needed: ~$((needed_kb / 1024))MB"
        return 1
    fi

    # Detect encryption; verify key is available before touching anything
    local encrypted=0
    if is_backup_encrypted "$backup_file"; then
        encrypted=1
        if ! require_encryption_key; then
            log_error "Cannot restore encrypted backup without BACKUP_KEY_FILE"
            return 1
        fi
    fi

    # Validate tar archive paths — reject entries with absolute paths or ../
    local bad_paths
    if [ "$encrypted" -eq 1 ]; then
        bad_paths=$(run_maybe_sudo bash -c "openssl enc -d -${BACKUP_ENC_CIPHER} -pbkdf2 -pass file:'$BACKUP_KEY_FILE' -in '$backup_file' | tar -tf -" 2>/dev/null | grep -E '(^/|\.\.)' || true)
    else
        bad_paths=$(run_maybe_sudo tar -tf "$backup_file" 2>/dev/null | grep -E '(^/|\.\.)' || true)
    fi
    if [ -n "$bad_paths" ]; then
        log_error "Tar archive contains unsafe paths (absolute or ../) — refusing to extract"
        log_error "Offending entries: $(echo "$bad_paths" | head -5)"
        return 1
    fi

    # Safety: extract to temp, then atomic swap preserving original until copy verified.
    # Original data is kept as .restore_bak until the new data is fully in place.
    # A journal file tracks restore state for crash recovery. The journal path is
    # SCRIPT_DIR-pinned so recovery works even if the next invocation changes
    # BACKUP_DIR (--backup-dir override between crashed run and recovery run).
    local temp_restore="${vol_path}.restore_tmp"
    local original_bak="${vol_path}.restore_bak"
    local journal_file="$RESTORE_JOURNAL_FILE"

    # Write journal BEFORE any destructive action (for crash recovery)
    if ! printf '%s\n' "label=${label}|vol_path=${vol_path}|backup_file=${backup_file}|state=extracting|ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        | run_maybe_sudo tee "$journal_file" > /dev/null; then
        log_warn "Could not write restore journal — crash recovery will not be available"
    fi

    run_maybe_sudo rm -rf "$temp_restore" "$original_bak"
    run_maybe_sudo mkdir -p "$temp_restore"
    local extract_rc=0
    if [ "$encrypted" -eq 1 ]; then
        set -o pipefail
        run_maybe_sudo bash -c "openssl enc -d -${BACKUP_ENC_CIPHER} -pbkdf2 -pass file:'$BACKUP_KEY_FILE' -in '$backup_file' | tar --selinux -xf - -C '$temp_restore'" || extract_rc=$?
        set +o pipefail
    else
        run_maybe_sudo tar --selinux -xf "$backup_file" -C "$temp_restore" || extract_rc=$?
    fi
    if [ "$extract_rc" -ne 0 ]; then
        log_error "Tar extraction failed (rc=$extract_rc) — original ${label} data is intact"
        run_maybe_sudo rm -rf "$temp_restore"
        run_maybe_sudo rm -f "$journal_file" 2>/dev/null || true
        return 1
    fi

    # Move original data aside (preserves it until copy verified)
    printf '%s\n' "label=${label}|vol_path=${vol_path}|backup_file=${backup_file}|state=swapping|ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        | run_maybe_sudo tee "$journal_file" > /dev/null 2>&1 || true
    if ! run_maybe_sudo mv "$vol_path" "$original_bak"; then
        log_error "Failed to move original ${label} data aside — aborting restore"
        run_maybe_sudo rm -rf "$temp_restore"
        run_maybe_sudo rm -f "$journal_file" 2>/dev/null || true
        return 1
    fi

    # Put restored data in place
    if ! run_maybe_sudo mv "$temp_restore" "$vol_path"; then
        log_error "Failed to move restored data into place — recovering original"
        run_maybe_sudo mv "$original_bak" "$vol_path" 2>/dev/null || true
        run_maybe_sudo rm -f "$journal_file" 2>/dev/null || true
        return 1
    fi

    # Success — clean up original backup and journal
    run_maybe_sudo rm -rf "$original_bak"
    run_maybe_sudo rm -f "$journal_file" 2>/dev/null || true

    log_ok "${label} volume restored from backup"
}

# Convenience wrappers for the three volumes
backup_db_volume()      { backup_volume "MySQL"   "mysql_data" "$DB_CONTAINER"  "/var/lib/mysql"  "$1"; }
restore_db_volume()     { restore_volume "MySQL"   "mysql_data" "$DB_CONTAINER"  "/var/lib/mysql"  "$1"; }
backup_redis_volume()   { backup_volume "Redis"   "redis_data" "$APP_CONTAINER" "/var/lib/redis"  "$1"; }
restore_redis_volume()  { restore_volume "Redis"   "redis_data" "$APP_CONTAINER" "/var/lib/redis"  "$1"; }
backup_app_volume()     { backup_volume "App"     "cloudpi$"   "$APP_CONTAINER" "/app/backups"    "$1"; }
restore_app_volume()    { restore_volume "App"     "cloudpi$"   "$APP_CONTAINER" "/app/backups"    "$1"; }

backup_current_state() {
    # Take a snapshot of the current state (DB + Redis + App volumes).
    # Requires containers to already be stopped.
    # Usage: backup_current_state [--skip-prune] [--source=<tag>]
    #   --skip-prune   don't auto-prune snapshots (protects target snapshot during restore)
    #   --source=<tag> reason tag recorded in .meta (manual | pre-restore | unknown)
    # Returns 0 on success, 1 on failure.
    local skip_prune=false
    local snap_source="unknown"
    while [ $# -gt 0 ]; do
        case "$1" in
            --skip-prune)   skip_prune=true ;;
            --source=*)     snap_source="${1#--source=}" ;;
            *) ;;
        esac
        shift
    done

    local backup_ts
    backup_ts=$(date +%Y%m%d_%H%M%S)
    mkdir -p "$BACKUP_DIR"

    local pre_db
    local pre_redis
    local pre_app
    pre_db=$(maybe_enc_suffix "${BACKUP_DIR}/db_volume_${backup_ts}.tar")
    pre_redis=$(maybe_enc_suffix "${BACKUP_DIR}/redis_volume_${backup_ts}.tar")
    pre_app=$(maybe_enc_suffix "${BACKUP_DIR}/cloudpi_volume_${backup_ts}.tar")

    # Expose pre-restore backup paths as globals for callers that need them
    # (do_restore stores them in state so --rollback can later find them).
    # PRE_RESTORE_BACKUP_CHECKSUM is populated after create_snapshot runs below,
    # using LAST_SNAPSHOT_CHECKSUM from create_snapshot. We initialize to empty
    # here so early failures don't leave stale values from a prior invocation.
    PRE_RESTORE_BACKUP_FILE="$pre_db"
    PRE_RESTORE_REDIS_BACKUP="$pre_redis"
    PRE_RESTORE_APP_BACKUP="$pre_app"
    PRE_RESTORE_BACKUP_CHECKSUM=""

    log_info "Backing up current state before rollback/restore..."

    if ! backup_db_volume "$pre_db"; then
        log_error "Current state DB backup failed"
        return 1
    fi

    # Redis and App are non-fatal
    if ! backup_redis_volume "$pre_redis"; then
        log_warn "Current state Redis backup failed — continuing"
        pre_redis=""
        PRE_RESTORE_REDIS_BACKUP=""
    fi
    if ! backup_app_volume "$pre_app"; then
        log_warn "Current state App backup failed — continuing"
        pre_app=""
        PRE_RESTORE_APP_BACKUP=""
    fi

    # Temporarily disable auto-prune if requested (to protect target snapshot)
    local saved_max_snapshots="$MAX_SNAPSHOTS"
    if [ "$skip_prune" = true ]; then
        MAX_SNAPSHOTS=0
    fi

    if ! create_snapshot "$pre_db" "$pre_redis" "$pre_app" "$snap_source"; then
        log_warn "Snapshot metadata write failed — backup files exist but snapshot not recorded"
        MAX_SNAPSHOTS="$saved_max_snapshots"
        return 1
    fi
    # Propagate the checksum that create_snapshot just computed so do_restore can
    # store it in .deploy_state and do_rollback_internal can verify it later.
    PRE_RESTORE_BACKUP_CHECKSUM="${LAST_SNAPSHOT_CHECKSUM:-}"

    MAX_SNAPSHOTS="$saved_max_snapshots"
    log_ok "Current state backed up as snapshot (can restore later with --restore)"
    return 0
}

# ============================================================
# Deployment Snapshots
# ============================================================
next_snapshot_id() {
    local max_id=0
    local meta_file
    for meta_file in "$BACKUP_DIR"/snapshot_*.meta; do
        [ -f "$meta_file" ] || continue
        local id
        id=$(grep -m1 '^id=' "$meta_file" 2>/dev/null | cut -d= -f2- || true)
        if [ -n "$id" ] && [ "$id" -gt "$max_id" ] 2>/dev/null; then
            max_id=$id
        fi
    done
    echo $((max_id + 1))
}

create_snapshot() {
    # Args:
    #   $1 backup_file        — path to DB tar (required)
    #   $2 redis_backup_file  — path to Redis tar (may be empty/missing)
    #   $3 app_backup_file    — path to App tar (may be empty/missing)
    #   $4 source             — reason tag: one of "deploy" | "manual" | "pre-restore" |
    #                           "init" | "unknown". Displayed in --history so operators
    #                           can tell manual ad-hoc backups from automated ones.
    local backup_file=$1
    local redis_backup_file=${2:-}
    local app_backup_file=${3:-}
    local snap_source=${4:-unknown}
    # Whitelist allowed sources to keep .meta parseable
    case "$snap_source" in
        deploy|manual|pre-restore|pre-rollback|init|unknown) ;;
        *) snap_source="unknown" ;;
    esac
    local snap_app_tag
    local snap_db_tag
    local snap_id
    local snap_checksum
    local snap_size
    local snap_timestamp
    local meta_file

    snap_app_tag=$(get_current_tag)
    snap_db_tag=$(get_db_tag)
    snap_id=$(next_snapshot_id)
    snap_timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Warn if tags could not be parsed (snapshot still created for backup value)
    if [ -z "$snap_app_tag" ]; then
        log_warn "Could not parse app tag from docker-compose.yml — snapshot will have empty app_tag"
    fi
    if [ -z "$snap_db_tag" ]; then
        log_warn "Could not parse DB tag from docker-compose.yml — snapshot will have empty db_tag"
    fi

    # Compute sha256 checksum for DB backup (verify exit status)
    snap_checksum="unavailable"
    # LAST_SNAPSHOT_CHECKSUM — exposed as a global so callers (backup_current_state)
    # can propagate it into .deploy_state, enabling rollback-time integrity checks.
    LAST_SNAPSHOT_CHECKSUM=""
    if command -v sha256sum >/dev/null 2>&1; then
        local hash_output
        hash_output=$(run_maybe_sudo sha256sum "$backup_file" 2>/dev/null)
        local hash_value
        hash_value=$(echo "$hash_output" | cut -d' ' -f1)
        # Validate hash is exactly 64 hex characters
        if [[ "$hash_value" =~ ^[0-9a-f]{64}$ ]]; then
            snap_checksum="sha256:${hash_value}"
            LAST_SNAPSHOT_CHECKSUM="$snap_checksum"
        else
            log_warn "sha256sum returned invalid hash — checksum not recorded"
        fi
    else
        log_warn "sha256sum not found — snapshot checksum not recorded"
    fi

    snap_size=$(du -sh "$backup_file" 2>/dev/null | cut -f1)

    # Store only basenames (reconstruct path on read for safety)
    local backup_basename
    backup_basename=$(basename "$backup_file")
    local redis_basename=""
    [ -n "$redis_backup_file" ] && [ -f "$redis_backup_file" ] && redis_basename=$(basename "$redis_backup_file")
    local app_basename=""
    [ -n "$app_backup_file" ] && [ -f "$app_backup_file" ] && app_basename=$(basename "$app_backup_file")

    # Atomic write: write to temp file, then move
    meta_file=$(printf "%s/snapshot_%03d.meta" "$BACKUP_DIR" "$snap_id")
    local tmp_meta="${meta_file}.tmp"
    {
        echo "id=${snap_id}"
        echo "timestamp=${snap_timestamp}"
        echo "app_tag=${snap_app_tag}"
        echo "db_tag=${snap_db_tag}"
        echo "backup_file=${backup_basename}"
        echo "backup_redis=${redis_basename}"
        echo "backup_app=${app_basename}"
        echo "checksum=${snap_checksum}"
        echo "size=${snap_size}"
        echo "source=${snap_source}"
        # Derive encrypted=1 from the actual filename on disk, not the global flag —
        # this ensures mixed plain/encrypted backup directories stay correct.
        if [[ "$backup_basename" == *.enc ]]; then
            echo "encrypted=1"
            echo "cipher=${BACKUP_ENC_CIPHER}"
        else
            echo "encrypted=0"
        fi
    } > "$tmp_meta"

    if ! mv "$tmp_meta" "$meta_file"; then
        log_warn "Failed to write snapshot metadata — snapshot not recorded"
        rm -f "$tmp_meta"
        return 1
    fi

    log_ok "Snapshot #${snap_id} created [${snap_source}] (${snap_app_tag} / ${snap_db_tag}, ${snap_size})"

    # Auto-prune if MAX_SNAPSHOTS > 0
    if [ "$MAX_SNAPSHOTS" -gt 0 ] 2>/dev/null; then
        prune_snapshots "$MAX_SNAPSHOTS"
    fi
}

read_snapshot_field() {
    local snap_id=$1
    local field=$2
    local meta_file
    meta_file=$(printf "%s/snapshot_%03d.meta" "$BACKUP_DIR" "$snap_id")
    if [ -f "$meta_file" ]; then
        grep -m1 "^${field}=" "$meta_file" 2>/dev/null | cut -d= -f2- || true
    fi
}

resolve_backup_path() {
    # Reconstruct full path from basename stored in .meta
    # Handles both legacy (full path) and new (basename-only) formats
    local raw_path=$1
    if [ -z "$raw_path" ]; then
        echo ""
        return
    fi
    # If it's already an absolute path, use it as-is (legacy snapshots)
    if [[ "$raw_path" == /* ]]; then
        echo "$raw_path"
    else
        echo "${BACKUP_DIR}/${raw_path}"
    fi
}

verify_snapshot() {
    local snap_id=$1
    local raw_backup
    local backup_file
    local stored_checksum
    local actual_checksum

    raw_backup=$(read_snapshot_field "$snap_id" "backup_file")
    stored_checksum=$(read_snapshot_field "$snap_id" "checksum")

    if [ -z "$raw_backup" ]; then
        log_error "Snapshot #${snap_id}: metadata missing or corrupt"
        return 1
    fi

    backup_file=$(resolve_backup_path "$raw_backup")

    # Security: validate path is under BACKUP_DIR and matches expected pattern
    if ! validate_backup_path "$backup_file"; then
        log_error "Snapshot #${snap_id}: backup path failed validation: $backup_file"
        return 1
    fi

    if [ ! -f "$backup_file" ] || [ ! -s "$backup_file" ]; then
        log_error "Snapshot #${snap_id}: backup file missing or empty: $backup_file"
        return 1
    fi

    # Verify checksum if available and valid format
    if [ "$stored_checksum" != "unavailable" ] && [ -n "$stored_checksum" ]; then
        local expected_hash="${stored_checksum#sha256:}"
        # Validate stored hash format (must be 64 hex chars)
        if ! [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]]; then
            log_warn "Snapshot #${snap_id}: stored checksum has invalid format — skipping verification"
            return 0
        fi
        if ! command -v sha256sum >/dev/null 2>&1; then
            log_warn "Snapshot #${snap_id}: sha256sum not available — skipping verification"
            return 0
        fi
        actual_checksum=$(run_maybe_sudo sha256sum "$backup_file" 2>/dev/null | cut -d' ' -f1)
        if [ "$actual_checksum" != "$expected_hash" ]; then
            log_error "Snapshot #${snap_id}: checksum mismatch"
            log_error "  Expected: ${expected_hash}"
            log_error "  Actual:   ${actual_checksum}"
            return 1
        fi
    fi

    # Verify Redis and App backup files exist (if recorded in snapshot)
    local raw_redis raw_app
    raw_redis=$(read_snapshot_field "$snap_id" "backup_redis")
    raw_app=$(read_snapshot_field "$snap_id" "backup_app")

    if [ -n "$raw_redis" ]; then
        local redis_file
        redis_file=$(resolve_backup_path "$raw_redis")
        if ! validate_backup_path "$redis_file" || [ ! -f "$redis_file" ] || [ ! -s "$redis_file" ]; then
            log_warn "Snapshot #${snap_id}: Redis backup missing or invalid — Redis will not be restored"
        fi
    fi

    if [ -n "$raw_app" ]; then
        local app_file
        app_file=$(resolve_backup_path "$raw_app")
        if ! validate_backup_path "$app_file" || [ ! -f "$app_file" ] || [ ! -s "$app_file" ]; then
            log_warn "Snapshot #${snap_id}: App backup missing or invalid — App volume will not be restored"
        fi
    fi

    return 0
}

list_snapshots() {
    local meta_files=()
    local meta_file
    for meta_file in "$BACKUP_DIR"/snapshot_*.meta; do
        [ -f "$meta_file" ] && meta_files+=("$meta_file")
    done

    if [ ${#meta_files[@]} -eq 0 ]; then
        echo "  No snapshots found. Snapshots are created automatically during deployment."
        return
    fi

    # Sort numerically by snapshot ID extracted from filename (handles >999 correctly)
    IFS=$'\n' meta_files=($(printf '%s\n' "${meta_files[@]}" | sort -t_ -k2,2n)); IFS=$'\n\t'

    printf "  %-4s %-17s %-12s %-22s %-22s %-8s %s\n" \
        "#" "Date" "Source" "App Tag" "DB Tag" "Size" "Enc"
    for meta_file in "${meta_files[@]}"; do
        local s_id s_ts s_app s_db s_size s_date s_source s_enc s_enc_label
        s_id=$(grep -m1 '^id=' "$meta_file" | cut -d= -f2- || true)
        s_ts=$(grep -m1 '^timestamp=' "$meta_file" | cut -d= -f2- || true)
        s_app=$(grep -m1 '^app_tag=' "$meta_file" | cut -d= -f2- || true)
        s_db=$(grep -m1 '^db_tag=' "$meta_file" | cut -d= -f2- || true)
        s_size=$(grep -m1 '^size=' "$meta_file" | cut -d= -f2- || true)
        s_source=$(grep -m1 '^source=' "$meta_file" | cut -d= -f2- || true)
        s_enc=$(grep -m1 '^encrypted=' "$meta_file" | cut -d= -f2- || true)
        # Snapshots created by older script versions lack source= — label them "legacy"
        [ -z "$s_source" ] && s_source="legacy"
        s_enc_label="no"
        [ "$s_enc" = "1" ] && s_enc_label="yes"
        # Format timestamp: 2026-02-17T14:30:22Z → 2026-02-17 14:30
        s_date=$(echo "$s_ts" | sed 's/T/ /;s/:..Z$//')
        printf "  %-4s %-17s %-12s %-22s %-22s %-8s %s\n" \
            "$s_id" "$s_date" "$s_source" "$s_app" "$s_db" "$s_size" "$s_enc_label"
    done
}

snapshot_count() {
    local count=0
    local meta_file
    for meta_file in "$BACKUP_DIR"/snapshot_*.meta; do
        [ -f "$meta_file" ] && count=$((count + 1))
    done
    echo "$count"
}

prune_snapshots() {
    local keep=${1:-$MAX_SNAPSHOTS}

    # 0 means unlimited
    [ "$keep" -eq 0 ] 2>/dev/null && return

    local meta_files=()
    local meta_file
    for meta_file in "$BACKUP_DIR"/snapshot_*.meta; do
        [ -f "$meta_file" ] && meta_files+=("$meta_file")
    done

    local total=${#meta_files[@]}
    [ "$total" -le "$keep" ] && return

    # Sort numerically by snapshot ID (handles >999 correctly)
    IFS=$'\n' meta_files=($(printf '%s\n' "${meta_files[@]}" | sort -t_ -k2,2n)); IFS=$'\n\t'

    local to_remove=$((total - keep))
    local removed=0
    for meta_file in "${meta_files[@]}"; do
        [ "$removed" -ge "$to_remove" ] && break

        local sid
        sid=$(grep -m1 '^id=' "$meta_file" 2>/dev/null | cut -d= -f2- || true)

        # Delete all backup tars (db, redis, app) associated with this snapshot
        local field_name raw_path resolved_path
        for field_name in backup_file backup_redis backup_app; do
            raw_path=$(grep -m1 "^${field_name}=" "$meta_file" 2>/dev/null | cut -d= -f2- || true)
            [ -z "$raw_path" ] && continue
            resolved_path=$(resolve_backup_path "$raw_path")
            if [ -n "$resolved_path" ] && validate_backup_path "$resolved_path" && [ -f "$resolved_path" ]; then
                run_maybe_sudo rm -f "$resolved_path"
            elif [ -n "$resolved_path" ] && [ -f "$resolved_path" ]; then
                log_warn "Snapshot #${sid}: ${field_name} path failed validation, skipping deletion: $resolved_path"
            fi
        done

        # Delete meta file
        rm -f "$meta_file"
        removed=$((removed + 1))
        log_info "Pruned snapshot #${sid}"
    done

    if [ "$removed" -gt 0 ]; then
        log_ok "Pruned $removed old snapshot(s) (kept last $keep)"
    fi
}

# ============================================================
# Monitor Migration
# ============================================================
monitor_migration() {
    log_info "Monitoring migration (timeout: ${MIGRATION_TIMEOUT}s)..."

    local start_time
    start_time=$(date +%s)

    # Use container start time as initial since_time to avoid missing early logs
    local since_time
    since_time=$(run_docker inspect -f '{{.State.StartedAt}}' "$APP_CONTAINER" 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)

    local found_success=false
    local found_failure=false

    # Track restart count to detect crash-loops under restart: always
    local prev_restart_count
    prev_restart_count=$(run_docker inspect -f '{{.RestartCount}}' "$APP_CONTAINER" 2>/dev/null || echo "0")

    while true; do
        local now
        now=$(date +%s)
        local elapsed=$((now - start_time))

        # Check timeout
        if [ "$elapsed" -ge "$MIGRATION_TIMEOUT" ]; then
            log_error "Migration timed out after ${MIGRATION_TIMEOUT}s"
            return 1
        fi

        # Detect crash-loop: container restarts under "restart: always" appear as running
        local cur_restart_count
        cur_restart_count=$(run_docker inspect -f '{{.RestartCount}}' "$APP_CONTAINER" 2>/dev/null || echo "0")
        if [ "$cur_restart_count" -gt "$prev_restart_count" ] 2>/dev/null; then
            log_error "Container is crash-looping (restart count: ${prev_restart_count} -> ${cur_restart_count})"
            local err_logs
            err_logs=$(run_docker logs --tail 20 "$APP_CONTAINER" 2>&1 | grep '\[migration\]' | tail -10 || true)
            if [ -n "$err_logs" ]; then
                while IFS= read -r line; do
                    log_error "  $line"
                done <<< "$err_logs"
            fi
            return 1
        fi

        # Check if container is still running
        if ! is_container_running "$APP_CONTAINER"; then
            local exit_code
            exit_code=$(run_docker inspect -f '{{.State.ExitCode}}' "$APP_CONTAINER" 2>/dev/null || echo "unknown")
            if [ "$exit_code" != "0" ]; then
                log_error "Container exited with code $exit_code"
                # Show last migration log lines (|| true guards against set -e + pipefail)
                local err_logs
                err_logs=$(run_docker logs "$APP_CONTAINER" 2>&1 | grep '\[migration\]' | tail -10 || true)
                if [ -n "$err_logs" ]; then
                    while IFS= read -r line; do
                        log_error "  $line"
                    done <<< "$err_logs"
                fi
                return 1
            fi
        fi

        # Fetch only new log lines since last check (incremental)
        # Use --timestamps so we can advance since_time to the last log timestamp
        local raw_logs
        raw_logs=$(run_docker logs --since "$since_time" --timestamps "$APP_CONTAINER" 2>&1 || true)
        local logs
        logs=$(echo "$raw_logs" | grep '\[migration\]' || true)

        # Advance since_time to the latest timestamp from the logs (prevents re-fetch/gaps)
        local last_ts
        last_ts=$(echo "$raw_logs" | tail -1 | sed -n 's/^\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}T[0-9:.]*Z\).*/\1/p' || true)
        if [ -n "$last_ts" ]; then
            since_time="$last_ts"
        fi

        # Print new migration log lines (skip if empty)
        if [ -n "$logs" ]; then
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                case "$line" in
                    *FAILED*|*ERROR*|*"Unhandled error"*)
                        log_error "  $line" ;;
                    *"Applied:"*|*"completed successfully"*|*"Advisory lock acquired"*)
                        log_ok "  $line" ;;
                    *"Applying:"*|*"Pre-batch backup"*|*"Backup:"*)
                        log_info "  $line" ;;
                    *"Crash recovery"*|*"Restoring"*|*"LOCKED"*)
                        log_warn "  $line" ;;
                    *)
                        echo "        $line" ;;
                esac
            done <<< "$logs"
        fi

        # Check for definitive success/failure in the fetched chunk
        if [ -n "$logs" ]; then
            case "$logs" in
                *"Database migrations completed successfully"*|*"migrations completed successfully"*)
                    found_success=true ;;
            esac
            case "$logs" in
                *"DATABASE MIGRATION FAILED"*|*"MIGRATION LOCKED OUT"*)
                    found_failure=true ;;
            esac
        fi

        # Detect lockout sleep state: container stays alive but migration failed.
        # The entrypoint writes a lockout file and enters sleep instead of exiting.
        if [ "$found_success" != true ] && [ "$found_failure" != true ]; then
            if run_docker exec "$APP_CONTAINER" test -f "$LOCKOUT_FILE_PATH" 2>/dev/null; then
                log_warn "Lockout file detected — migration entered lockout sleep"
                found_failure=true
            fi
        fi

        if [ "$found_success" = true ]; then
            return 0
        fi
        if [ "$found_failure" = true ]; then
            return 1
        fi

        sleep 2
    done
}

# ============================================================
# Wait for App Health
# ============================================================
wait_for_healthy() {
    log_info "Waiting for app health check (max ${HEALTH_TIMEOUT}s)..."
    local elapsed=0

    while [ "$elapsed" -lt "$HEALTH_TIMEOUT" ]; do
        local health
        # Use Go template that returns "missing" when .State.Health is nil (no healthcheck defined).
        # Without this, docker inspect returns "<no value>" which doesn't match any case.
        health=$(run_docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' "$APP_CONTAINER" 2>/dev/null || echo "missing")

        case "$health" in
            healthy)
                log_ok "App container is healthy"
                return 0
                ;;
            unhealthy)
                log_warn "Health check: unhealthy (retrying...)"
                ;;
            starting)
                # Normal during startup
                ;;
            missing|""|"<no value>"|"null")
                # No healthcheck defined on this container — fall back to HTTP probe.
                # This avoids a false timeout+rollback when the app is actually running fine.
                if is_container_running "$APP_CONTAINER"; then
                    local http_code
                    http_code=$(run_docker exec "$APP_CONTAINER" curl -sf -o /dev/null -w '%{http_code}' http://127.0.0.1:5001/monitor 2>/dev/null || echo "000")
                    if [ "$http_code" = "200" ]; then
                        log_ok "App container is responding (no Docker healthcheck, HTTP probe 200)"
                        return 0
                    fi
                fi
                ;;
        esac

        # Also check if container died
        if ! is_container_running "$APP_CONTAINER"; then
            log_error "Container stopped while waiting for health"
            return 1
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    # No success path after timeout.
    # A running container without a successful HEALTHCHECK or HTTP 200 on /monitor
    # is NOT healthy — it may be crash-looping internally, PM2 may be restarting the
    # Node process, or the app could be stuck in startup. Declaring success here
    # caused silent deployment failures (see .reports/bug-node-heap-oom-cascade.md).
    #
    # Fall through to the explicit failure return below.
    log_error "Health check timed out after ${HEALTH_TIMEOUT}s"
    local final_health
    final_health=$(run_docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' "$APP_CONTAINER" 2>/dev/null || echo "missing")
    case "$final_health" in
        missing|""|"<no value>"|"null")
            log_error "  → Container has no Docker HEALTHCHECK defined AND HTTP probe to /monitor never returned 200"
            log_error "  → Add a HEALTHCHECK to the Dockerfile or verify /monitor is reachable inside the container:"
            log_error "    docker exec $APP_CONTAINER curl -v http://127.0.0.1:5001/monitor"
            ;;
        unhealthy)
            log_error "  → Docker HEALTHCHECK is reporting unhealthy"
            log_error "    docker inspect --format '{{json .State.Health}}' $APP_CONTAINER"
            ;;
        *)
            log_error "  → Last health state: $final_health"
            ;;
    esac

    log_error "App health check timed out after ${HEALTH_TIMEOUT}s"
    return 1
}

# ============================================================
# Deploy
# ============================================================
do_deploy() {
    local new_tag=$1
    DEPLOY_IN_PROGRESS=true

    # Validate tag format before any operations
    validate_tag "$new_tag"

    local current_tag
    current_tag=$(get_current_tag)
    local current_db_tag
    current_db_tag=$(get_db_tag)

    # Check for interrupted previous operations
    check_interrupted_restore
    check_interrupted_deploy

    save_deploy_phase "preflight" "$new_tag" "$current_tag"

    echo ""
    echo "=========================================="
    echo "  CloudPi Deployment"
    echo "=========================================="
    echo "  Current tag:  ${current_tag:-<not set>}"
    echo "  New tag:      ${new_tag}"
    echo "  Repository:   ${DOCKER_REPOSITORY}"
    echo "=========================================="
    echo ""

    # Refuse to deploy the same tag
    if [ "$new_tag" = "$current_tag" ]; then
        log_warn "New tag is the same as current tag: $new_tag"
        if ! confirm_action "Continue anyway?"; then
            log_info "Deployment cancelled"
            exit 0
        fi
    fi

    # --- Step 1: Prerequisites ---
    check_prerequisites

    # --- Step 1.5: Pre-flight checks (before any destructive action) ---
    if ! preflight_check "$new_tag"; then
        exit 1
    fi

    # --- Step 2: Validate rollback info ---
    if [ -n "$current_tag" ]; then
        log_info "Rollback target: $current_tag"
    else
        log_warn "No current tag found — rollback will not be available"
    fi

    # --- Step 2.5: Pull image BEFORE stopping containers (minimizes downtime) ---
    save_deploy_phase "pulling" "$new_tag" "$current_tag"
    local app_image="${DOCKER_REPOSITORY}:${new_tag}"
    log_info "Pre-pulling new image (containers still running)..."
    local pull_output
    if pull_output=$(run_docker pull "$app_image" 2>&1); then
        log_ok "Image pre-pulled (cached for deploy)"
    elif run_docker image inspect "$app_image" >/dev/null 2>&1; then
        log_warn "Pull failed but image exists in local cache — proceeding with cached image"
        diagnose_pull_failure "$app_image" "$pull_output"
    else
        log_error "Failed to pull image $app_image and no local cache"
        diagnose_pull_failure "$app_image" "$pull_output"
        log_error "No changes made — containers are still running"
        clear_deploy_phase
        exit 1
    fi

    # --- Step 3: Stop app container ---
    save_deploy_phase "stopping" "$new_tag" "$current_tag"
    if ! stop_and_remove_app; then
        log_error "App container did not stop — cannot proceed with backup"
        exit 1
    fi

    # --- Step 4: Stop DB and take volume backups (DB, Redis, App) ---
    if ! stop_db_verified 60; then
        log_error "DB container did not stop cleanly — aborting backup"
        log_error "Try: docker compose -f $COMPOSE_FILE stop -t 120 db"
        exit 1
    fi

    save_deploy_phase "backing_up" "$new_tag" "$current_tag"
    local backup_ts
    backup_ts=$(date +%Y%m%d_%H%M%S)
    # maybe_enc_suffix appends .enc when BACKUP_ENCRYPT=1 so the path matches the actual on-disk file
    CURRENT_BACKUP=$(maybe_enc_suffix "${BACKUP_DIR}/db_volume_${backup_ts}.tar")
    CURRENT_REDIS_BACKUP=$(maybe_enc_suffix "${BACKUP_DIR}/redis_volume_${backup_ts}.tar")
    CURRENT_APP_BACKUP=$(maybe_enc_suffix "${BACKUP_DIR}/cloudpi_volume_${backup_ts}.tar")

    if ! backup_db_volume "$CURRENT_BACKUP"; then
        log_error "Database backup failed — aborting deployment"
        log_info "Restarting containers..."
        run_compose -f "$COMPOSE_FILE" up -d db || log_warn "Failed to restart DB"
        wait_for_db || true
        run_compose -f "$COMPOSE_FILE" up -d app || log_warn "Failed to restart app"
        exit 1
    fi

    # Compute checksum of DB backup for rollback verification
    CURRENT_BACKUP_CHECKSUM=""
    if command -v sha256sum >/dev/null 2>&1; then
        local hash_value
        hash_value=$(run_maybe_sudo sha256sum "$CURRENT_BACKUP" 2>/dev/null | cut -d' ' -f1)
        if [[ "$hash_value" =~ ^[0-9a-f]{64}$ ]]; then
            CURRENT_BACKUP_CHECKSUM="sha256:${hash_value}"
        fi
    fi

    # Redis and App volume backups are non-fatal — warn and continue if they fail
    if ! backup_redis_volume "$CURRENT_REDIS_BACKUP"; then
        log_warn "Redis backup failed — continuing without Redis backup"
        CURRENT_REDIS_BACKUP=""
    fi
    if ! backup_app_volume "$CURRENT_APP_BACKUP"; then
        log_warn "App volume backup failed — continuing without App backup"
        CURRENT_APP_BACKUP=""
    fi

    save_state "$current_tag" "rollback_target" "$current_tag" "$CURRENT_BACKUP" "$CURRENT_REDIS_BACKUP" "$CURRENT_APP_BACKUP" "$CURRENT_BACKUP_CHECKSUM" "$current_db_tag" "$current_db_tag"
    # Create deployment snapshot (for multi-level rollback via --history/--restore)
    if ! create_snapshot "$CURRENT_BACKUP" "$CURRENT_REDIS_BACKUP" "$CURRENT_APP_BACKUP" "deploy"; then
        log_warn "Snapshot metadata write failed — backup files exist but snapshot not recorded"
        log_warn "Rollback via --restore may not list this deployment"
    fi

    # --- Step 5: Start DB container ---
    log_info "Starting DB container..."
    if ! run_compose -f "$COMPOSE_FILE" up -d db; then
        log_error "Failed to start DB container — compose error"
        log_error "Recovery: run 'docker compose -f $COMPOSE_FILE up -d db' manually"
        exit 1
    fi
    if ! wait_for_db; then
        log_error "DB failed to come back up after backup — aborting"
        exit 1
    fi

    # --- Step 6: Clear migration lockout ---
    log_info "Clearing migration lockout (if any)..."
    clear_migration_lockout

    # --- Step 7: Update image tag ---
    save_deploy_phase "updating_tag" "$new_tag" "$current_tag" "$CURRENT_BACKUP"
    log_info "Setting image tag to: $new_tag"
    if ! set_image_tag "$new_tag"; then
        log_error "Failed to update image tag in $COMPOSE_FILE"
        do_rollback_internal "$current_tag" "Failed to update image tag"
        return 1
    fi

    # (Image was pre-pulled in step 2.5 — already cached locally)

    # --- Step 8: Start app container ---
    save_deploy_phase "starting" "$new_tag" "$current_tag" "$CURRENT_BACKUP"
    log_info "Starting app container with new image..."
    if ! run_compose -f "$COMPOSE_FILE" up -d app; then
        log_error "Failed to start app container"
        do_rollback_internal "$current_tag" "Failed to start app container"
        return 1
    fi

    # Wait for container to start (up to 30s — slow pulls/restarts need more than 3s)
    local startup_wait=0
    local startup_max=30
    while [ "$startup_wait" -lt "$startup_max" ]; do
        if is_container_running "$APP_CONTAINER"; then
            break
        fi
        # Check if container exited (not just slow to start)
        local state
        state=$(run_docker inspect -f '{{.State.Status}}' "$APP_CONTAINER" 2>/dev/null || echo "missing")
        if [ "$state" = "exited" ] || [ "$state" = "dead" ]; then
            log_error "Container exited before startup completed (state: $state)"
            do_rollback_internal "$current_tag" "Container failed to start"
            return 1
        fi
        sleep 3
        startup_wait=$((startup_wait + 3))
    done

    if ! is_container_running "$APP_CONTAINER"; then
        log_error "Container not running after ${startup_max}s"
        do_rollback_internal "$current_tag" "Container failed to start"
        return 1
    fi

    # --- Step 9: Monitor migration ---
    save_deploy_phase "monitoring" "$new_tag" "$current_tag" "$CURRENT_BACKUP"
    if monitor_migration; then
        log_ok "Migration succeeded"
    else
        log_error "Migration failed"
        do_rollback_internal "$current_tag" "Migration failed"
        return 1
    fi

    # --- Step 10: Wait for health ---
    save_deploy_phase "verifying" "$new_tag" "$current_tag" "$CURRENT_BACKUP"
    if wait_for_healthy; then
        log_ok "Deployment successful"
    else
        log_error "App failed health check after migration"
        do_rollback_internal "$current_tag" "Health check failed"
        return 1
    fi

    # --- Step 11: Update state ---
    save_state "$new_tag" "deployed" "$current_tag" "$CURRENT_BACKUP" "$CURRENT_REDIS_BACKUP" "$CURRENT_APP_BACKUP" "$CURRENT_BACKUP_CHECKSUM" "$current_db_tag" "$current_db_tag"
    clear_deploy_phase
    DEPLOY_IN_PROGRESS=false

    echo ""
    echo "=========================================="
    log_ok "DEPLOYMENT COMPLETE"
    echo "=========================================="
    echo "  Image:   ${DOCKER_REPOSITORY}:${new_tag}"
    echo "  Status:  healthy"
    echo "  Rollback available: ${current_tag:-none}"
    echo "=========================================="
    echo ""
}

# ============================================================
# Rollback
# ============================================================
do_rollback_internal() {
    local rollback_tag=$1
    local reason=${2:-"Manual rollback"}

    # INVARIANT: all rollback_failed save_state() calls below preserve $rollback_tag
    # as the third arg (the "intended rollback target"). Clearing it would cause a
    # subsequent `--rollback` to read an empty rollback_tag from .deploy_state and
    # fall into do_rollback()'s "latest snapshot" fallback path — a DIFFERENT
    # recovery than the one the first attempt was trying. Preserving the tag lets
    # the operator retry the same operation after fixing whatever caused the failure.
    if [ -z "$rollback_tag" ]; then
        log_error "No rollback tag available — manual intervention required"
        log_error "Check .deploy_state or edit the image tag in docker-compose.yml manually"
        return 1
    fi

    echo ""
    log_warn "=========================================="
    log_warn "  ROLLING BACK: $reason"
    log_warn "  Reverting to: $rollback_tag"
    log_warn "=========================================="
    echo ""

    # Resolve backup paths from state file or current deploy run variables.
    # We do this BEFORE stopping the app so we can pre-flight-validate paths and
    # fail fast — keeping the app running if rollback is going to abort anyway.
    local backup_path="" redis_backup_path="" app_backup_path=""
    if [ -f "$STATE_FILE" ]; then
        backup_path=$(read_state_field "backup")
        redis_backup_path=$(read_state_field "backup_redis")
        app_backup_path=$(read_state_field "backup_app")
    fi
    # Also check CURRENT_* variables (set during this deploy run)
    backup_path="${backup_path:-${CURRENT_BACKUP:-}}"
    redis_backup_path="${redis_backup_path:-${CURRENT_REDIS_BACKUP:-}}"
    app_backup_path="${app_backup_path:-${CURRENT_APP_BACKUP:-}}"

    # PRE-FLIGHT validation: if the DB backup path won't validate, abort BEFORE
    # stopping the app. do_rollback_internal()'s contract is "DB restore is
    # mandatory" (see the explicit refusal later at ~L2866 when no DB backup
    # is found), so a failing DB path means the rollback can't proceed no
    # matter what — there's no reason to tear down the live stack first.
    #
    # We intentionally only pre-flight the DB path here; Redis/App validation
    # stays further down where it can gracefully skip non-fatal volumes.
    if [ -n "$backup_path" ] && ! validate_backup_path "$backup_path"; then
        log_error "Rollback pre-flight FAILED — DB backup path not accepted:"
        log_error "  $backup_path"
        local _saved_dir=""
        local _hint=""
        [ -f "$STATE_FILE" ] && _hint=$(read_state_field "backup_dir_hint")
        _saved_dir=$(dirname "$backup_path")
        if [ -n "$_hint" ] && [ "$_hint" != "$BACKUP_DIR" ]; then
            log_error "  Deploy recorded BACKUP_DIR=${_hint} but current BACKUP_DIR=${BACKUP_DIR}."
            log_error "  Retry with:  $0 --backup-dir ${_hint} --rollback"
        elif [ "$_saved_dir" != "$BACKUP_DIR" ]; then
            log_error "  Saved path lives under ${_saved_dir} but current BACKUP_DIR=${BACKUP_DIR}."
            log_error "  Retry with:  $0 --backup-dir ${_saved_dir} --rollback"
        else
            log_error "  Filename pattern check failed (state file may be corrupt)."
        fi
        log_error "  App container was NOT stopped — it is still running."
        return 1
    fi

    # Stop app (now that pre-flight passed)
    if ! stop_and_remove_app; then
        log_error "App container did not stop — cannot safely rollback"
        return 1
    fi

    # IMPORTANT: preserve the ORIGINAL recovery info before any validator nulls
    # them out. If this rollback attempt was started with the wrong BACKUP_DIR,
    # the validator below will clear backup_path/redis/app — but the failure
    # state we write must still record the ORIGINAL paths and the ORIGINAL
    # backup_dir_hint so the operator can retry with --backup-dir <correct>.
    local orig_backup_path="$backup_path"
    local orig_redis_backup_path="$redis_backup_path"
    local orig_app_backup_path="$app_backup_path"
    local orig_backup_dir_hint=""
    if [ -f "$STATE_FILE" ]; then
        orig_backup_dir_hint=$(read_state_field "backup_dir_hint")
    fi
    # Read the original checksum too — it's per-backup-file, not per-invocation
    local orig_stored_checksum=""
    # DB tags are ALSO critical recovery info: rollback_db_tag tells a retried
    # rollback which DB image to revert to. Clearing these on failure would let
    # a retried rollback restore OLD data under a NEWER DB binary, causing
    # schema mismatch and data corruption.
    local orig_db_tag=""
    local orig_rollback_db_tag=""
    if [ -f "$STATE_FILE" ]; then
        orig_stored_checksum=$(read_state_field "backup_checksum")
        orig_db_tag=$(read_state_field "db_tag")
        orig_rollback_db_tag=$(read_state_field "rollback_db_tag")
    fi

    # Validate backup paths before using them (prevents path traversal from corrupted
    # or tampered state). The ONLY trusted prefix is the current BACKUP_DIR — i.e.,
    # whatever the operator explicitly picked for THIS invocation via --backup-dir,
    # env var, or config file. We do NOT derive trust from anything inside .deploy_state,
    # because a tampered state file could then self-authenticate an arbitrary path.
    #
    # If the original deploy used a different BACKUP_DIR and the operator wants to
    # rollback, they must pass --backup-dir <old-path> explicitly. We surface that
    # as an actionable error message instead of silently failing.
    local backup_dir_hint=""
    if [ -f "$STATE_FILE" ]; then
        backup_dir_hint=$(read_state_field "backup_dir_hint")
    fi

    _explain_path_rejection() {
        local label=$1 saved_path=$2
        local saved_dir
        saved_dir=$(dirname "$saved_path")
        log_warn "${label} backup path failed validation: $saved_path"
        if [ -n "$backup_dir_hint" ] && [ "$backup_dir_hint" != "$BACKUP_DIR" ]; then
            log_warn "  Deploy recorded BACKUP_DIR=${backup_dir_hint} but current BACKUP_DIR=${BACKUP_DIR}."
            log_warn "  To rollback using the original backups, re-run:"
            log_warn "    $0 --backup-dir ${backup_dir_hint} --rollback"
        elif [ "$saved_dir" != "$BACKUP_DIR" ]; then
            log_warn "  Saved path lives under ${saved_dir} but current BACKUP_DIR=${BACKUP_DIR}."
            log_warn "  If that location is legitimate, re-run:"
            log_warn "    $0 --backup-dir ${saved_dir} --rollback"
        fi
        log_warn "  ${label} restore will be skipped."
    }

    # Helper: write rollback_failed state while preserving ALL original recovery
    # info (backup paths, checksum, db_tag, rollback_db_tag, backup_dir_hint) as
    # read from state. Uses orig_* captures from above, not the possibly-cleared
    # runtime variables.
    #
    # Preserving rollback_db_tag is critical: a retried rollback needs to know
    # which DB image to revert to. Losing it would let the retry restore OLD data
    # under a NEWER DB binary → schema mismatch → data corruption.
    _save_rollback_failed() {
        save_state \
            "$rollback_tag" \
            "rollback_failed" \
            "$rollback_tag" \
            "$orig_backup_path" \
            "$orig_redis_backup_path" \
            "$orig_app_backup_path" \
            "$orig_stored_checksum" \
            "$orig_db_tag" \
            "$orig_rollback_db_tag" \
            "${orig_backup_dir_hint:-$BACKUP_DIR}"
    }

    if [ -n "$backup_path" ] && ! validate_backup_path "$backup_path"; then
        _explain_path_rejection "DB" "$backup_path"
        backup_path=""
    fi
    if [ -n "$redis_backup_path" ] && ! validate_backup_path "$redis_backup_path"; then
        _explain_path_rejection "Redis" "$redis_backup_path"
        redis_backup_path=""
    fi
    if [ -n "$app_backup_path" ] && ! validate_backup_path "$app_backup_path"; then
        _explain_path_rejection "App" "$app_backup_path"
        app_backup_path=""
    fi

    # Verify DB backup checksum before restoring (prevents restoring corrupted data)
    local stored_checksum=""
    if [ -f "$STATE_FILE" ]; then
        stored_checksum=$(read_state_field "backup_checksum")
    fi
    if [ -n "$backup_path" ] && [ -f "$backup_path" ] && [ -n "$stored_checksum" ] && [ "$stored_checksum" != "" ]; then
        if [[ "$stored_checksum" == sha256:* ]]; then
            local expected_hash="${stored_checksum#sha256:}"
            if command -v sha256sum >/dev/null 2>&1; then
                local actual_hash
                actual_hash=$(run_maybe_sudo sha256sum "$backup_path" 2>/dev/null | cut -d' ' -f1)
                if [ "$actual_hash" != "$expected_hash" ]; then
                    log_error "DB backup checksum mismatch — backup file may be corrupted"
                    log_error "  Expected: ${expected_hash}"
                    log_error "  Actual:   ${actual_hash}"
                    log_error "Aborting rollback to prevent restoring corrupt data"
                    _save_rollback_failed
                    return 1
                fi
                log_ok "DB backup checksum verified"
            fi
        fi
    fi

    # Determine if any volume needs restoring (requires stopping DB)
    local has_any_backup=false
    [ -n "$backup_path" ] && [ -f "$backup_path" ] && has_any_backup=true
    [ -n "$redis_backup_path" ] && [ -f "$redis_backup_path" ] && has_any_backup=true
    [ -n "$app_backup_path" ] && [ -f "$app_backup_path" ] && has_any_backup=true

    if [ "$has_any_backup" = true ]; then
        log_info "Stopping DB container for volume restore..."
        if ! stop_db_verified 60; then
            log_error "DB container did not stop — cannot safely restore volumes"
            log_error "Manual intervention required: docker compose -f $COMPOSE_FILE stop -t 120 db"
            _save_rollback_failed
            return 1
        fi

        # Restore DB volume (critical — abort rollback if this fails)
        if [ -n "$backup_path" ] && [ -f "$backup_path" ]; then
            if restore_db_volume "$backup_path"; then
                log_ok "Database volume restored"
            else
                log_error "Database volume restore failed — aborting rollback to prevent data corruption"
                log_error "Original data may still be intact. Manual intervention required."
                _save_rollback_failed
                return 1
            fi
        else
            log_error "No DB backup found — cannot rollback without database restore"
            log_error "App would start against migrated data with old code — aborting"
            _save_rollback_failed
            return 1
        fi

        # Restore Redis volume (non-fatal)
        if [ -n "$redis_backup_path" ] && [ -f "$redis_backup_path" ]; then
            if restore_redis_volume "$redis_backup_path"; then
                log_ok "Redis volume restored"
            else
                log_warn "Redis volume restore failed — continuing"
            fi
        fi

        # Restore App volume (non-fatal)
        if [ -n "$app_backup_path" ] && [ -f "$app_backup_path" ]; then
            if restore_app_volume "$app_backup_path"; then
                log_ok "App volume restored"
            else
                log_warn "App volume restore failed — continuing"
            fi
        fi

        log_info "Starting DB container..."
        if ! run_compose -f "$COMPOSE_FILE" up -d db; then
            log_error "Failed to start DB container after restore"
            _save_rollback_failed
            return 1
        fi
        if ! wait_for_db; then
            log_error "DB failed to start after restore — manual intervention needed"
            _save_rollback_failed
            return 1
        fi
    else
        log_error "No volume backups found — cannot rollback without DB restore"
        log_error "Rolling back the app without restoring the database would run old code against migrated data"
        _save_rollback_failed
        return 1
    fi

    # Clear lockout after container is stopped
    clear_migration_lockout

    # Revert app tag
    log_info "Reverting app image tag to: $rollback_tag"
    # Clear .bak so set_image_tag creates a fresh backup of current state
    rm -f "${COMPOSE_FILE}.bak" 2>/dev/null || true
    if ! set_image_tag "$rollback_tag"; then
        log_error "Failed to revert image tag in docker-compose.yml — file may be corrupted"
        log_error "Manual fix: edit $COMPOSE_FILE and set the app image tag to $rollback_tag"
        _save_rollback_failed
        return 1
    fi

    # Revert DB tag if stored in state (prevents old data + new DB binary mismatch)
    local rollback_db_tag=""
    if [ -f "$STATE_FILE" ]; then
        rollback_db_tag=$(read_state_field "rollback_db_tag")
    fi
    if [ -n "$rollback_db_tag" ]; then
        local current_db_tag
        current_db_tag=$(get_db_tag)
        if [ -n "$current_db_tag" ] && [ "$current_db_tag" != "$rollback_db_tag" ]; then
            log_info "Reverting DB image tag: ${current_db_tag} → ${rollback_db_tag}"
            if ! set_db_image_tag "$rollback_db_tag"; then
                log_warn "Failed to revert DB image tag — continuing with current DB image"
                log_warn "Manual fix: edit $COMPOSE_FILE and set the DB image tag to $rollback_db_tag"
            fi
        fi
    fi

    # Verify rollback image exists (pre-check before starting)
    if ! run_docker image inspect "${DOCKER_REPOSITORY}:${rollback_tag}" >/dev/null 2>&1; then
        log_warn "Rollback image not in local cache — pulling from registry..."
        local rb_pull_output
        if ! rb_pull_output=$(run_docker pull "${DOCKER_REPOSITORY}:${rollback_tag}" 2>&1); then
            log_error "Cannot pull rollback image ${DOCKER_REPOSITORY}:${rollback_tag} — registry unreachable and image not cached"
            diagnose_pull_failure "${DOCKER_REPOSITORY}:${rollback_tag}" "$rb_pull_output"
            log_error "Manual fix: docker pull ${DOCKER_REPOSITORY}:${rollback_tag}, then re-run $0 --rollback"
            _save_rollback_failed
            return 1
        fi
    fi

    # Start with old image
    log_info "Starting app with previous image..."
    if ! run_compose -f "$COMPOSE_FILE" up -d app; then
        log_error "Failed to start app container with rollback image"
        _save_rollback_failed
        return 1
    fi

    sleep 3

    # Wait for health. Rollback MUST succeed strictly — a "container is running but
    # not healthy" outcome hides silent failures (Node crash-looping inside a container
    # that stays up, etc.). Previous soft-success path was removed intentionally; let
    # wait_for_healthy be the single source of truth here.
    if wait_for_healthy; then
        save_state "$rollback_tag" "rolled_back" "" "$backup_path" "$redis_backup_path" "$app_backup_path"
        clear_deploy_phase
        echo ""
        log_ok "=========================================="
        log_ok "  ROLLBACK COMPLETE"
        log_ok "  Running: ${DOCKER_REPOSITORY}:${rollback_tag}"
        log_ok "=========================================="
        echo ""
        return 0
    fi

    # Health check failed. Distinguish between "container died" and "container alive
    # but not healthy" for the error message, but treat BOTH as rollback failure.
    if is_container_running "$APP_CONTAINER"; then
        log_error "Rollback container is running but never became healthy — treating as FAILURE"
        log_error "  → Monitor:  docker logs -f $APP_CONTAINER"
        log_error "  → Inspect:  docker inspect --format '{{json .State.Health}}' $APP_CONTAINER"
    else
        log_error "Rollback container is not running — rollback failed"
        log_error "  → Logs:     docker logs $APP_CONTAINER"
    fi
    log_error "Rollback did not produce a healthy container — manual intervention needed"
    _save_rollback_failed
    return 1
}

do_rollback() {
    check_interrupted_restore

    local rollback_tag
    rollback_tag=$(read_state)

    if [ -z "$rollback_tag" ]; then
        # Fallback: try the most recent snapshot
        local snap_count
        snap_count=$(snapshot_count)
        if [ "$snap_count" -gt 0 ]; then
            log_info "No .deploy_state — falling back to latest snapshot"
            # Derive latest ID from filenames (more robust than next_snapshot_id - 1)
            local latest_id
            latest_id=$(printf '%s\n' "$BACKUP_DIR"/snapshot_*.meta | sort -t_ -k2,2n | tail -1 | sed 's/.*snapshot_0*\([0-9]*\)\.meta/\1/')
            if [ -z "$latest_id" ] || ! [[ "$latest_id" =~ ^[0-9]+$ ]]; then
                log_error "Could not determine latest snapshot ID from filenames"
                exit 1
            fi
            do_restore "$latest_id"
            return $?
        fi
        log_error "No rollback target found in .deploy_state and no snapshots available"
        log_error "Set the tag manually: edit the image tag in docker-compose.yml"
        exit 1
    fi

    local current_tag
    current_tag=$(get_current_tag)

    echo ""
    echo "=========================================="
    echo "  Manual Rollback"
    echo "=========================================="
    echo "  Current tag:  ${current_tag:-<not set>}"
    echo "  Rollback to:  ${rollback_tag}"
    echo "=========================================="
    echo ""

    if ! confirm_action "Proceed with rollback?"; then
        log_info "Rollback cancelled"
        exit 0
    fi

    # Offer to backup current state before rolling back
    if confirm_action "Take a backup of the current state before rolling back?"; then
        if ! stop_and_remove_app; then
            log_error "App container did not stop — cannot take pre-rollback backup"
            if ! confirm_action "Continue rollback WITHOUT backup?"; then
                log_info "Rollback cancelled"
                exit 1
            fi
        elif ! stop_db_verified 60; then
            log_error "DB did not stop cleanly — cannot take pre-rollback backup"
            if ! confirm_action "Continue rollback WITHOUT backup?"; then
                log_info "Rollback cancelled — restarting containers..."
                run_compose -f "$COMPOSE_FILE" up -d db
                wait_for_db || true
                run_compose -f "$COMPOSE_FILE" up -d app || true
                exit 1
            fi
        elif ! backup_current_state --source=pre-rollback; then
            log_warn "Pre-rollback backup failed"
            if ! confirm_action "Continue rollback WITHOUT backup?"; then
                log_info "Rollback cancelled — restarting containers..."
                run_compose -f "$COMPOSE_FILE" up -d db
                wait_for_db || true
                run_compose -f "$COMPOSE_FILE" up -d app || true
                exit 1
            fi
        fi
        # Restart DB + app so do_rollback_internal can stop them cleanly
        # (do_rollback_internal expects containers to be running)
        log_info "Restarting containers for rollback..."
        run_compose -f "$COMPOSE_FILE" up -d db
        wait_for_db || true
        run_compose -f "$COMPOSE_FILE" up -d app || true
    fi

    do_rollback_internal "$rollback_tag" "Manual rollback requested"
}

# ============================================================
# Status
# ============================================================
do_status() {
    require_compose_file
    local current_tag
    current_tag=$(get_current_tag)
    local state_tag
    state_tag=$(read_state)
    local state_status
    state_status=$(read_state_status)

    echo ""
    echo "=========================================="
    echo "  CloudPi Deployment Status"
    echo "=========================================="
    echo "  Current image tag:   ${current_tag:-<not set>}"
    echo "  Rollback target:     ${state_tag:-<none>}"
    echo "  Last deploy status:  ${state_status:-<unknown>}"

    # Interrupted deploy detection
    local interrupted_phase
    interrupted_phase=$(read_deploy_phase)
    if [ -n "$interrupted_phase" ] && [ "$interrupted_phase" != "complete" ]; then
        local int_tag int_time
        int_tag=$(read_deploy_phase_field 2)
        int_time=$(read_deploy_phase_field 5)
        echo ""
        echo -e "  ${YELLOW}INTERRUPTED DEPLOY${NC}"
        echo "    Phase:     ${interrupted_phase}"
        echo "    Tag:       ${int_tag}"
        echo "    Time:      ${int_time}"
        echo "    Recovery:  run '$0 --rollback' or '$0 <tag>' to re-deploy"
    fi
    echo ""

    # Container status
    if is_container_running "$APP_CONTAINER"; then
        local health
        health=$(run_docker inspect -f '{{.State.Health.Status}}' "$APP_CONTAINER" 2>/dev/null || echo "unknown")
        echo "  App container:       running (health: $health)"
    else
        echo "  App container:       stopped"
    fi

    if is_container_running "$DB_CONTAINER"; then
        local db_health
        db_health=$(run_docker inspect -f '{{.State.Health.Status}}' "$DB_CONTAINER" 2>/dev/null || echo "unknown")
        echo "  DB container:        running (health: $db_health)"
    else
        echo "  DB container:        stopped"
    fi

    # Migration lockout
    if is_container_running "$APP_CONTAINER"; then
        if run_docker exec "$APP_CONTAINER" test -f "$LOCKOUT_FILE_PATH" 2>/dev/null; then
            echo ""
            log_warn "  Migration lockout:   ACTIVE"
            run_docker exec "$APP_CONTAINER" cat "$LOCKOUT_FILE_PATH" 2>/dev/null | while IFS= read -r line; do
                echo "                       $line"
            done
        else
            echo "  Migration lockout:   none"
        fi
    fi

    # Snapshots
    local snap_count
    snap_count=$(snapshot_count)
    echo "  Snapshots:           ${snap_count} (max: ${MAX_SNAPSHOTS})"
    if [ "$snap_count" -gt 0 ]; then
        echo "                       Run '$0 --history' for details"
    fi

    echo "=========================================="
    echo ""
}

# ============================================================
# History
# ============================================================
do_history() {
    require_compose_file
    local current_tag
    current_tag=$(get_current_tag)
    local current_db_tag
    current_db_tag=$(get_db_tag)
    local count
    count=$(snapshot_count)

    echo ""
    echo "=========================================="
    echo "  CloudPi Deployment History"
    echo "=========================================="

    list_snapshots

    echo ""
    echo "  Current: ${current_tag:-<not set>} / ${current_db_tag:-<not set>}"
    echo "  Snapshots: ${count} (max: ${MAX_SNAPSHOTS})"
    echo "=========================================="
    echo ""

    if [ "$count" -gt 0 ]; then
        echo "  Restore:  $0 --restore <#>"
        echo "  Prune:    $0 --prune [keep-count]"
        echo ""
    fi
}

# ============================================================
# Restore from Snapshot
# ============================================================
do_restore() {
    check_interrupted_restore

    local target_id=${1:-}

    local count
    count=$(snapshot_count)

    if [ "$count" -eq 0 ]; then
        log_error "No snapshots available"
        echo "Snapshots are created automatically during deployment."
        exit 1
    fi

    # If no ID provided, show interactive picker
    if [ -z "$target_id" ]; then
        echo ""
        echo "=========================================="
        echo "  Restore to Previous Deployment"
        echo "=========================================="

        list_snapshots

        echo ""
        read -r -p "  Enter snapshot # to restore (or 'q' to cancel): " target_id
        if [ "$target_id" = "q" ] || [ "$target_id" = "Q" ] || [ -z "$target_id" ]; then
            log_info "Restore cancelled"
            exit 0
        fi
    fi

    # Validate snapshot ID is a number
    if ! [[ "$target_id" =~ ^[0-9]+$ ]]; then
        log_error "Invalid snapshot ID: $target_id"
        exit 1
    fi

    # Check snapshot exists
    local meta_file
    meta_file=$(printf "%s/snapshot_%03d.meta" "$BACKUP_DIR" "$target_id")
    if [ ! -f "$meta_file" ]; then
        log_error "Snapshot #${target_id} not found"
        echo "Run '$0 --history' to see available snapshots"
        exit 1
    fi

    # Read snapshot details
    local snap_app_tag snap_db_tag snap_backup_raw snap_backup snap_size snap_checksum
    local snap_redis_raw snap_redis_backup snap_app_raw snap_app_backup
    snap_app_tag=$(read_snapshot_field "$target_id" "app_tag")
    snap_db_tag=$(read_snapshot_field "$target_id" "db_tag")
    snap_backup_raw=$(read_snapshot_field "$target_id" "backup_file")
    snap_backup=$(resolve_backup_path "$snap_backup_raw")
    snap_redis_raw=$(read_snapshot_field "$target_id" "backup_redis")
    snap_redis_backup=$(resolve_backup_path "$snap_redis_raw")
    snap_app_raw=$(read_snapshot_field "$target_id" "backup_app")
    snap_app_backup=$(resolve_backup_path "$snap_app_raw")
    snap_size=$(read_snapshot_field "$target_id" "size")
    snap_checksum=$(read_snapshot_field "$target_id" "checksum")

    # Validate tags are non-empty and well-formed (prevents corrupting docker-compose.yml)
    if [ -z "$snap_app_tag" ]; then
        log_error "Snapshot #${target_id}: app_tag is empty — cannot restore"
        log_error "This snapshot's metadata may be corrupt. Run '$0 --prune' to clean."
        exit 1
    fi
    if [[ ! "$snap_app_tag" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$ ]]; then
        log_error "Snapshot #${target_id}: app_tag has invalid format: '$snap_app_tag'"
        log_error "This snapshot's metadata may be tampered. Aborting."
        exit 1
    fi
    if [ -n "$snap_db_tag" ] && [[ ! "$snap_db_tag" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$ ]]; then
        log_error "Snapshot #${target_id}: db_tag has invalid format: '$snap_db_tag'"
        log_error "This snapshot's metadata may be tampered. Aborting."
        exit 1
    fi

    # Warn if db_tag is missing — restoring old data against a newer DB image can cause corruption
    if [ -z "$snap_db_tag" ]; then
        local current_db_img
        current_db_img=$(get_db_tag)
        log_warn "Snapshot #${target_id}: db_tag is empty (snapshot was created before db_tag tracking)"
        log_warn "Current DB image tag: ${current_db_img:-unknown}"
        log_warn "Restoring old data against a mismatched DB version can cause MySQL errors"
        if ! confirm_action "Continue restore without DB version verification?"; then
            log_info "Restore cancelled"
            exit 0
        fi
    fi

    # Verify snapshot integrity
    echo ""
    log_info "Verifying snapshot #${target_id}..."
    if ! verify_snapshot "$target_id"; then
        log_error "Snapshot verification failed — cannot restore"
        exit 1
    fi

    local current_tag
    current_tag=$(get_current_tag)
    local current_db_tag
    current_db_tag=$(get_db_tag)

    # Build checksum status message
    local checksum_msg="checksum not available"
    if [ "$snap_checksum" != "unavailable" ] && [ -n "$snap_checksum" ]; then
        local expected_hash="${snap_checksum#sha256:}"
        if [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]]; then
            checksum_msg="checksum verified"
        fi
    fi

    # Show restore plan
    echo ""
    echo "=========================================="
    echo "  Restore Plan — Snapshot #${target_id}"
    echo "=========================================="
    echo "  App tag:    ${current_tag:-<not set>}  →  ${snap_app_tag}"
    echo "  DB tag:     ${current_db_tag:-<not set>}  →  ${snap_db_tag:-<same>}"
    echo "  DB backup:  ${snap_size} (${checksum_msg})"
    echo "=========================================="
    echo ""

    if ! confirm_action "Proceed with restore?"; then
        log_info "Restore cancelled"
        exit 0
    fi

    DEPLOY_IN_PROGRESS=true

    # --- Stop app ---
    if ! stop_and_remove_app; then
        log_error "App container did not stop — cannot proceed with restore"
        DEPLOY_IN_PROGRESS=false
        exit 1
    fi

    # --- Stop DB (generous timeout) ---
    if ! stop_db_verified 60; then
        log_error "DB container did not stop cleanly — aborting restore"
        DEPLOY_IN_PROGRESS=false
        exit 1
    fi

    # --- Capture pre-restore app+db tags so a later --rollback can revert correctly ---
    # These MUST be captured before set_image_tag changes the compose file.
    local pre_restore_app_tag pre_restore_db_tag
    pre_restore_app_tag="$current_tag"
    pre_restore_db_tag=$(get_db_tag)

    # Helper: record a restore_failed marker that still points --rollback at the
    # PRE-RESTORE backup (not the snapshot we tried to restore to). This ensures a
    # later --rollback can recover the operator's original state even if the restore
    # aborted partway through.
    # Args: $1 = current_tag marker (what compose.yml says right now; snap_app_tag
    #            if the tag was already flipped, pre_restore_app_tag otherwise)
    _restore_fail_save_state() {
        local cur_marker=${1:-$pre_restore_app_tag}
        save_state \
            "$cur_marker" \
            "restore_failed" \
            "$pre_restore_app_tag" \
            "${PRE_RESTORE_BACKUP_FILE:-}" \
            "${PRE_RESTORE_REDIS_BACKUP:-}" \
            "${PRE_RESTORE_APP_BACKUP:-}" \
            "${PRE_RESTORE_BACKUP_CHECKSUM:-}" \
            "" \
            "$pre_restore_db_tag"
    }

    # --- Offer to backup current state before restoring ---
    # backup_current_state() sets PRE_RESTORE_BACKUP_FILE / PRE_RESTORE_REDIS_BACKUP /
    # PRE_RESTORE_APP_BACKUP globals which we capture below. On failure/decline these
    # stay empty; save_state will record empty fields, and --rollback will refuse to
    # run without a valid pre-restore backup path (which is the correct behavior).
    PRE_RESTORE_BACKUP_FILE=""
    PRE_RESTORE_REDIS_BACKUP=""
    PRE_RESTORE_APP_BACKUP=""
    PRE_RESTORE_BACKUP_CHECKSUM=""
    if confirm_action "Take a backup of the current state before restoring?"; then
        if ! backup_current_state --skip-prune --source=pre-restore; then
            log_warn "Pre-restore backup failed"
            PRE_RESTORE_BACKUP_FILE=""
            PRE_RESTORE_REDIS_BACKUP=""
            PRE_RESTORE_APP_BACKUP=""
            PRE_RESTORE_BACKUP_CHECKSUM=""
            if ! confirm_action "Continue restore WITHOUT backup?"; then
                log_info "Restore cancelled — restarting containers..."
                run_compose -f "$COMPOSE_FILE" up -d db
                wait_for_db || true
                run_compose -f "$COMPOSE_FILE" up -d app || true
                DEPLOY_IN_PROGRESS=false
                exit 1
            fi
        fi
    fi

    # --- Validate and restore DB volume ---
    if ! validate_backup_path "$snap_backup"; then
        log_error "DB backup path failed security validation: $snap_backup"
        DEPLOY_IN_PROGRESS=false
        exit 1
    fi
    if ! restore_db_volume "$snap_backup"; then
        log_error "DB volume restore failed — manual intervention needed"
        # DB restore failed; compose still points at pre-restore tag
        _restore_fail_save_state "$pre_restore_app_tag"
        DEPLOY_IN_PROGRESS=false
        exit 1
    fi

    # --- Restore Redis volume (non-fatal) ---
    if [ -n "$snap_redis_backup" ] && [ -f "$snap_redis_backup" ]; then
        if validate_backup_path "$snap_redis_backup"; then
            if restore_redis_volume "$snap_redis_backup"; then
                log_ok "Redis volume restored"
            else
                log_warn "Redis volume restore failed — continuing"
            fi
        else
            log_warn "Redis backup path failed validation — skipping"
        fi
    fi

    # --- Restore App volume (non-fatal) ---
    if [ -n "$snap_app_backup" ] && [ -f "$snap_app_backup" ]; then
        if validate_backup_path "$snap_app_backup"; then
            if restore_app_volume "$snap_app_backup"; then
                log_ok "App volume restored"
            else
                log_warn "App volume restore failed — continuing"
            fi
        else
            log_warn "App backup path failed validation — skipping"
        fi
    fi

    # --- Revert image tags ---
    log_info "Reverting app image tag to: $snap_app_tag"
    if ! set_image_tag "$snap_app_tag"; then
        log_error "Failed to revert app image tag — docker-compose.yml may be corrupted"
        log_error "Manual fix: edit $COMPOSE_FILE and set the app image tag to $snap_app_tag"
        _restore_fail_save_state "$snap_app_tag"
        DEPLOY_IN_PROGRESS=false
        exit 1
    fi

    if [ -n "$snap_db_tag" ] && [ "$snap_db_tag" != "$current_db_tag" ]; then
        log_info "Reverting DB image tag to: $snap_db_tag"
        if ! set_db_image_tag "$snap_db_tag"; then
            log_error "Failed to revert DB image tag — docker-compose.yml in mixed-tag state"
            log_error "App tag updated to $snap_app_tag but DB tag is still $current_db_tag"
            # Restore compose file from backup if available (set_image_tag/set_db_image_tag create .bak)
            if [ -f "${COMPOSE_FILE}.bak" ]; then
                log_warn "Restoring docker-compose.yml from backup to consistent state"
                cp "${COMPOSE_FILE}.bak" "$COMPOSE_FILE"
            fi
            log_error "Manual fix: edit $COMPOSE_FILE and set both tags correctly"
            _restore_fail_save_state "$snap_app_tag"
            DEPLOY_IN_PROGRESS=false
            exit 1
        fi
    fi

    # --- Pull images if not cached (old snapshots may have pruned images) ---
    local restore_app_image="${DOCKER_REPOSITORY}:${snap_app_tag}"
    if ! run_docker image inspect "$restore_app_image" >/dev/null 2>&1; then
        log_info "Pulling app image: $restore_app_image"
        local ra_pull_output
        if ! ra_pull_output=$(run_docker pull "$restore_app_image" 2>&1); then
            log_error "Cannot pull app image $restore_app_image and not in local cache"
            diagnose_pull_failure "$restore_app_image" "$ra_pull_output"
            _restore_fail_save_state "$snap_app_tag"
            DEPLOY_IN_PROGRESS=false
            exit 1
        fi
    fi
    if [ -n "$snap_db_tag" ]; then
        local restore_db_image="${DOCKER_REPOSITORY}:${snap_db_tag}"
        if ! run_docker image inspect "$restore_db_image" >/dev/null 2>&1; then
            log_info "Pulling DB image: $restore_db_image"
            local rd_pull_output
            if ! rd_pull_output=$(run_docker pull "$restore_db_image" 2>&1); then
                log_error "Cannot pull DB image $restore_db_image and not in local cache"
                diagnose_pull_failure "$restore_db_image" "$rd_pull_output"
                _restore_fail_save_state "$snap_app_tag"
                DEPLOY_IN_PROGRESS=false
                exit 1
            fi
        fi
    fi

    # --- Clear migration lockout ---
    clear_migration_lockout

    # --- Start DB ---
    log_info "Starting DB container..."
    if ! run_compose -f "$COMPOSE_FILE" up -d db; then
        log_error "Failed to start DB container — compose error"
        _restore_fail_save_state "$snap_app_tag"
        DEPLOY_IN_PROGRESS=false
        exit 1
    fi
    if ! wait_for_db; then
        log_error "DB failed to start after restore — manual intervention needed"
        _restore_fail_save_state "$snap_app_tag"
        DEPLOY_IN_PROGRESS=false
        exit 1
    fi

    # --- Start app ---
    log_info "Starting app container..."
    if ! run_compose -f "$COMPOSE_FILE" up -d app; then
        log_error "Failed to start app container after restore"
        _restore_fail_save_state "$snap_app_tag"
        DEPLOY_IN_PROGRESS=false
        exit 1
    fi

    sleep 3

    # Wait for health. Restore must succeed strictly — a "container is running but
    # not healthy" outcome hides silent failures (Node crash-looping inside a container
    # that keeps respawning via PM2, app bound to wrong port, etc.). Previous soft-success
    # path ("restored_unhealthy_from_snapshot") was removed: it made automation treat a
    # failed restore as successful and misled operators into moving on.
    if ! wait_for_healthy; then
        # Distinguish "container alive but unhealthy" vs "container stopped" in the
        # error message, but treat BOTH as a failed restore.
        if is_container_running "$APP_CONTAINER"; then
            log_error "App container is running but never became healthy after restore — treating as FAILURE"
            log_error "  → Monitor:  docker logs -f $APP_CONTAINER"
            log_error "  → Inspect:  docker inspect --format '{{json .State.Health}}' $APP_CONTAINER"
        else
            log_error "App container is not running after restore — restore incomplete"
            log_error "  → Logs:     docker logs $APP_CONTAINER"
        fi
        log_error "Run '$0 --rollback' to revert to pre-restore state (snapshot #${target_id} NOT in effect)."
        _restore_fail_save_state "$snap_app_tag"
        DEPLOY_IN_PROGRESS=false
        exit 1
    fi

    log_ok "App is healthy"

    # --- Update state for future rollback ---
    # CORRECTNESS: a later `--rollback` must revert to the state the user was in BEFORE
    # this restore ran. That means:
    #   current_tag       → the snapshot we just restored to (snap_app_tag)
    #   rollback_tag      → the pre-restore app tag ($pre_restore_app_tag)
    #   rollback_db_tag   → the pre-restore DB tag  ($pre_restore_db_tag)
    #   backup            → the PRE-RESTORE backup we took above (PRE_RESTORE_BACKUP_FILE)
    #                       NOT the snapshot's backup (using $snap_backup here was the old bug)
    # If the operator declined the pre-restore backup, these fields are empty and
    # --rollback will refuse to run (handled in do_rollback's pre-check).
    local restore_status="restored_from_snapshot_${target_id}"
    save_state \
        "$snap_app_tag" \
        "$restore_status" \
        "$pre_restore_app_tag" \
        "$PRE_RESTORE_BACKUP_FILE" \
        "$PRE_RESTORE_REDIS_BACKUP" \
        "$PRE_RESTORE_APP_BACKUP" \
        "${PRE_RESTORE_BACKUP_CHECKSUM:-}" \
        "$snap_db_tag" \
        "$pre_restore_db_tag"
    DEPLOY_IN_PROGRESS=false

    echo ""
    echo "=========================================="
    log_ok "RESTORE COMPLETE — Snapshot #${target_id}"
    echo "=========================================="
    echo "  App:  ${DOCKER_REPOSITORY}:${snap_app_tag}"
    echo "  DB:   ${DOCKER_REPOSITORY}:${snap_db_tag}"
    echo "=========================================="
    echo ""
}

# ============================================================
# Prune Snapshots
# ============================================================
do_prune() {
    local keep=${1:-$MAX_SNAPSHOTS}
    local count
    count=$(snapshot_count)

    if [ "$count" -eq 0 ]; then
        echo "No snapshots to prune."
        return
    fi

    echo ""
    echo "Current snapshots: $count"
    echo "Keeping last: $keep"
    echo ""

    if [ "$count" -le "$keep" ]; then
        echo "Nothing to prune (${count} <= ${keep})"
        return
    fi

    local to_remove=$((count - keep))
    if ! confirm_action "Delete $to_remove oldest snapshot(s)?"; then
        log_info "Prune cancelled"
        return
    fi

    prune_snapshots "$keep"
}

# ============================================================
# Delete specific snapshot(s) by ID (comma-separated, or "all")
# Usage: do_delete_snapshot "3" | "3,5,7" | "all"
# ============================================================
do_delete_snapshot() {
    local ids_arg=${1:-}
    local force=${2:-0}

    if [ -z "$ids_arg" ]; then
        echo "Error: --delete requires snapshot ID(s)" >&2
        echo "Usage: $0 --delete <id>[,<id>...]" >&2
        echo "       $0 --delete all" >&2
        echo ""
        echo "List available snapshots first with:  $0 --history" >&2
        return 1
    fi

    local count
    count=$(snapshot_count)
    if [ "$count" -eq 0 ]; then
        echo "No snapshots to delete."
        return
    fi

    # Build the target ID list
    local -a target_ids=()
    if [ "$ids_arg" = "all" ]; then
        local meta_file
        for meta_file in "$BACKUP_DIR"/snapshot_*.meta; do
            [ -f "$meta_file" ] || continue
            local sid
            sid=$(grep -m1 '^id=' "$meta_file" 2>/dev/null | cut -d= -f2-)
            [ -n "$sid" ] && target_ids+=("$sid")
        done
    else
        # Parse comma-separated list, validate each is numeric
        local IFS=','
        # shellcheck disable=SC2206
        local raw_ids=($ids_arg)
        IFS=$' \t\n'
        local id
        for id in "${raw_ids[@]}"; do
            id=$(echo "$id" | tr -d ' ')
            if ! [[ "$id" =~ ^[0-9]+$ ]]; then
                log_error "Invalid snapshot ID: '$id' (must be numeric)"
                return 1
            fi
            target_ids+=("$id")
        done
    fi

    if [ "${#target_ids[@]}" -eq 0 ]; then
        echo "No matching snapshots to delete."
        return
    fi

    # Identify newest snapshot (to protect as rollback target unless --force)
    local newest_id=""
    local meta_file
    for meta_file in "$BACKUP_DIR"/snapshot_*.meta; do
        [ -f "$meta_file" ] || continue
        local sid
        sid=$(grep -m1 '^id=' "$meta_file" 2>/dev/null | cut -d= -f2-)
        if [ -n "$sid" ] && { [ -z "$newest_id" ] || [ "$sid" -gt "$newest_id" ]; }; then
            newest_id=$sid
        fi
    done

    # Show what will be deleted and confirm
    echo ""
    echo "Snapshots to delete:"
    local id
    for id in "${target_ids[@]}"; do
        local mf
        mf=$(printf "%s/snapshot_%03d.meta" "$BACKUP_DIR" "$id")
        if [ ! -f "$mf" ]; then
            echo "  #${id}  (NOT FOUND)"
            continue
        fi
        local tag size enc src
        tag=$(grep -m1 '^app_tag=' "$mf" | cut -d= -f2-)
        size=$(grep -m1 '^size=' "$mf" | cut -d= -f2-)
        enc=$(grep -m1 '^encrypted=' "$mf" | cut -d= -f2-)
        src=$(grep -m1 '^source=' "$mf" | cut -d= -f2-)
        [ -z "$src" ] && src="legacy"
        local enc_tag=""
        [ "$enc" = "1" ] && enc_tag=" [encrypted]"
        if [ "$id" = "$newest_id" ]; then
            echo "  #${id}  [${src}]  ${tag}  ${size}${enc_tag}  ⚠️  NEWEST (rollback target)"
        else
            echo "  #${id}  [${src}]  ${tag}  ${size}${enc_tag}"
        fi
    done
    echo ""

    # Safety: refuse to delete newest unless --force
    local deleting_newest=0
    for id in "${target_ids[@]}"; do
        if [ "$id" = "$newest_id" ]; then
            deleting_newest=1
            break
        fi
    done
    if [ "$deleting_newest" = "1" ] && [ "$force" != "1" ]; then
        log_error "Refusing to delete newest snapshot (#${newest_id}) — this is your rollback target."
        log_error "If you really want to delete it, use: $0 --delete ${ids_arg} --force"
        return 1
    fi

    # Safety: refuse to delete last remaining snapshot ever, even with --force
    local remaining=$((count - ${#target_ids[@]}))
    if [ "$remaining" -le 0 ]; then
        log_error "Refusing to delete ALL snapshots — at least one must remain for rollback capability."
        log_error "Keep at least one by pruning a smaller set."
        return 1
    fi

    if ! confirm_action "Delete ${#target_ids[@]} snapshot(s)?"; then
        log_info "Delete cancelled"
        return
    fi

    # Acquire deploy lock (same as prune does via entry-point)
    local removed=0
    for id in "${target_ids[@]}"; do
        local mf
        mf=$(printf "%s/snapshot_%03d.meta" "$BACKUP_DIR" "$id")
        if [ ! -f "$mf" ]; then
            log_warn "Snapshot #${id} not found, skipping"
            continue
        fi

        # Delete every associated tar file (db, redis, app — encrypted or plain)
        local field_name raw_path resolved_path
        for field_name in backup_file backup_redis backup_app; do
            raw_path=$(grep -m1 "^${field_name}=" "$mf" 2>/dev/null | cut -d= -f2- || true)
            [ -z "$raw_path" ] && continue
            resolved_path=$(resolve_backup_path "$raw_path")
            if [ -n "$resolved_path" ] && validate_backup_path "$resolved_path" && [ -f "$resolved_path" ]; then
                run_maybe_sudo rm -f "$resolved_path"
            fi
        done

        rm -f "$mf"
        removed=$((removed + 1))
        log_info "Deleted snapshot #${id}"
    done

    if [ "$removed" -gt 0 ]; then
        log_ok "Deleted ${removed} snapshot(s)"
    fi
}

# ============================================================
# Ad-hoc Snapshot (--backup)
# ============================================================
# Create a snapshot of current state WITHOUT deploying a new image. Useful for:
#   - Manual checkpoints before risky operations outside the deploy flow
#   - Scheduled daily/weekly backups (cron → cp_upgrade.sh --backup --yes)
#   - Pre-maintenance snapshots
#
# Behavior:
#   - Stops app + DB briefly for consistent volume snapshot
#   - Runs backup_current_state() (same logic as pre-restore and pre-deploy backups)
#   - Creates snapshot_NNN.meta with app_tag / db_tag / checksums
#   - Restarts containers, waits for health
#   - Does NOT touch image tags, docker-compose.yml, or state file
#   - Respects BACKUP_ENCRYPT / BACKUP_KEY_FILE same as deploy-time backups
#
# Flags:
#   --skip-prune  → keep all existing snapshots regardless of MAX_SNAPSHOTS
#                   (default is to auto-prune per MAX_SNAPSHOTS as deploys do)
do_backup() {
    check_interrupted_restore

    local skip_prune=false
    # $1 is "--skip-prune" if passed, otherwise empty
    if [ "${1:-}" = "--skip-prune" ]; then
        skip_prune=true
    fi

    # Preflight: compose file exists + Docker reachable
    require_compose_file
    if ! run_docker info >/dev/null 2>&1; then
        log_error "Cannot reach Docker daemon"
        exit 1
    fi

    local app_tag db_tag
    app_tag=$(get_current_tag)
    db_tag=$(get_db_tag)

    if [ -z "$app_tag" ] || [ -z "$db_tag" ]; then
        log_warn "Could not parse app/db tags from docker-compose.yml — snapshot will still be created but with empty tag fields"
    fi

    echo ""
    echo "=========================================="
    echo "  Ad-hoc backup snapshot"
    echo "=========================================="
    echo "  App tag:    ${app_tag:-<unknown>}"
    echo "  DB tag:     ${db_tag:-<unknown>}"
    echo "  Backup dir: ${BACKUP_DIR}"
    if is_encryption_enabled; then
        echo "  Encryption: ENABLED (${BACKUP_ENC_CIPHER})"
    else
        echo "  Encryption: disabled"
    fi
    if [ "$skip_prune" = true ]; then
        echo "  Auto-prune: SKIPPED (--skip-prune)"
    else
        echo "  Auto-prune: yes (MAX_SNAPSHOTS=${MAX_SNAPSHOTS})"
    fi
    echo ""
    echo "  NOTE: Containers will stop briefly for a consistent volume snapshot,"
    echo "        then restart automatically. Expect ~30s to a few minutes of downtime"
    echo "        depending on volume size."
    echo ""

    if ! confirm_action "Proceed with backup?"; then
        log_info "Backup cancelled"
        return
    fi

    # If encryption is on, fail fast before stopping containers
    if is_encryption_enabled && ! require_encryption_key; then
        log_error "Encryption is enabled but key file is not usable — aborting before stopping containers"
        exit 1
    fi

    local start_ts
    start_ts=$(date +%s)

    # --- Stop app ---
    log_info "Stopping app container..."
    if ! stop_and_remove_app; then
        log_error "App container did not stop cleanly — aborting backup to avoid inconsistent state"
        exit 1
    fi

    # --- Stop DB (generous timeout for clean flush) ---
    log_info "Stopping DB container..."
    if ! stop_db_verified 60; then
        log_error "DB container did not stop cleanly — aborting backup"
        log_info "Attempting to restart app..."
        run_compose -f "$COMPOSE_FILE" up -d app || log_warn "Failed to restart app"
        exit 1
    fi

    # --- Take the backup + create snapshot ---
    # backup_current_state() handles: volume tar(s), create_snapshot() metadata,
    # PRE_RESTORE_* globals (unused here but harmless), optional auto-prune.
    local backup_rc=0
    if [ "$skip_prune" = true ]; then
        backup_current_state --skip-prune --source=manual || backup_rc=$?
    else
        backup_current_state --source=manual || backup_rc=$?
    fi

    if [ "$backup_rc" -ne 0 ]; then
        log_error "Backup failed (rc=$backup_rc) — attempting to restart containers anyway"
    fi

    # --- Restart containers (always, even on backup failure, to minimize downtime) ---
    log_info "Restarting DB container..."
    if ! run_compose -f "$COMPOSE_FILE" up -d db; then
        log_error "Failed to restart DB container after backup"
        log_error "Manual recovery: docker compose -f $COMPOSE_FILE up -d db"
        exit 1
    fi
    if ! wait_for_db; then
        log_error "DB failed health check after backup restart — manual intervention required"
        exit 1
    fi

    log_info "Restarting app container..."
    if ! run_compose -f "$COMPOSE_FILE" up -d app; then
        log_error "Failed to restart app container after backup"
        log_error "Manual recovery: docker compose -f $COMPOSE_FILE up -d app"
        exit 1
    fi

    sleep 3
    if ! wait_for_healthy; then
        log_warn "App health check timed out after backup — investigate with: docker logs $APP_CONTAINER"
        # Don't exit 1 — the backup itself succeeded if we reached here; health is a separate concern
    fi

    if [ "$backup_rc" -ne 0 ]; then
        log_error "Backup FAILED but containers restarted successfully"
        exit 1
    fi

    local end_ts elapsed
    end_ts=$(date +%s)
    elapsed=$((end_ts - start_ts))

    echo ""
    echo "=========================================="
    log_ok "BACKUP COMPLETE (elapsed: ${elapsed}s)"
    echo "=========================================="
    echo "  Snapshot saved: ${BACKUP_DIR}"
    echo "  List with:      $0 --history"
    echo "  Restore with:   $0 --restore <N>"
    echo "=========================================="
    echo ""
}

# ============================================================
# Config Management (--config-show, --config-set)
# ============================================================
# Path resolution priority for the config file we write to:
#   1. $CP_UPGRADE_CONFIG if set
#   2. ${SCRIPT_DIR}/cp_upgrade.conf (default — co-located with the script)
_config_write_path() {
    if [ -n "${CP_UPGRADE_CONFIG:-}" ]; then
        echo "$CP_UPGRADE_CONFIG"
    else
        echo "${SCRIPT_DIR}/cp_upgrade.conf"
    fi
}

# Allow-list of config keys that --config-set will accept.
# Prevents typos from silently creating useless entries and prevents setting
# arbitrary shell variables that the script doesn't use.
_is_allowed_config_key() {
    case "$1" in
        BACKUP_DIR|BACKUP_ENCRYPT|BACKUP_KEY_FILE|BACKUP_ENC_CIPHER|\
        MAX_SNAPSHOTS|MIGRATION_TIMEOUT|HEALTH_TIMEOUT|DB_WAIT_TIMEOUT)
            return 0 ;;
        *)  return 1 ;;
    esac
}

do_config_show() {
    local cfg
    cfg=$(_config_write_path)
    echo ""
    echo "=========================================="
    echo "  cp_upgrade.sh Configuration"
    echo "=========================================="
    if [ -n "${CP_UPGRADE_LOADED_CONFIG:-}" ]; then
        echo "  Active config file: ${CP_UPGRADE_LOADED_CONFIG}"
    else
        echo "  Active config file: <none — using defaults>"
    fi
    echo "  Write target:       ${cfg}"
    echo ""
    echo "  Current effective values:"
    echo "    BACKUP_DIR          = ${BACKUP_DIR}"
    echo "    BACKUP_ENCRYPT      = ${BACKUP_ENCRYPT}"
    echo "    BACKUP_KEY_FILE     = ${BACKUP_KEY_FILE:-<unset>}"
    echo "    BACKUP_ENC_CIPHER   = ${BACKUP_ENC_CIPHER}"
    echo "    MAX_SNAPSHOTS       = ${MAX_SNAPSHOTS}"
    echo "    MIGRATION_TIMEOUT   = ${MIGRATION_TIMEOUT}"
    echo "    HEALTH_TIMEOUT      = ${HEALTH_TIMEOUT}"
    echo "    DB_WAIT_TIMEOUT     = ${DB_WAIT_TIMEOUT}"
    echo ""
    if [ -f "$cfg" ]; then
        echo "  File contents:"
        sed 's/^/    /' "$cfg"
    else
        echo "  Config file does not exist yet."
        echo "  Create with:  $0 --config-set KEY=value"
    fi
    echo "=========================================="
    echo ""
}

# Write or remove a KEY=value line in the config file.
# Usage: do_config_set "KEY=VALUE"   (atomic: write temp, validate, rename)
#        do_config_set "KEY="        (empty value → remove line)
#        do_config_set "KEY"         (no `=` → remove line)
do_config_set() {
    local raw_arg=${1:-}
    if [ -z "$raw_arg" ]; then
        echo "Error: --config-set requires KEY=VALUE" >&2
        echo "Usage: $0 --config-set BACKUP_DIR=/data/cloudpi-backups" >&2
        echo "       $0 --config-set BACKUP_ENCRYPT=1" >&2
        echo "       $0 --config-set BACKUP_KEY_FILE=    # empty value removes the line" >&2
        echo ""
        echo "Allowed keys: BACKUP_DIR BACKUP_ENCRYPT BACKUP_KEY_FILE BACKUP_ENC_CIPHER"
        echo "              MAX_SNAPSHOTS MIGRATION_TIMEOUT HEALTH_TIMEOUT DB_WAIT_TIMEOUT"
        return 1
    fi

    local key value
    case "$raw_arg" in
        *=*)
            key="${raw_arg%%=*}"
            value="${raw_arg#*=}"
            ;;
        *)
            # No `=` → treat as deletion
            key="$raw_arg"
            value=""
            raw_arg="${key}="
            ;;
    esac

    if ! _is_allowed_config_key "$key"; then
        echo "Error: '$key' is not an allowed config key" >&2
        echo "Allowed: BACKUP_DIR BACKUP_ENCRYPT BACKUP_KEY_FILE BACKUP_ENC_CIPHER" >&2
        echo "         MAX_SNAPSHOTS MIGRATION_TIMEOUT HEALTH_TIMEOUT DB_WAIT_TIMEOUT" >&2
        return 1
    fi

    # SECURITY: reject values containing shell metacharacters up-front. The config
    # file is never sourced by the loader, but we still refuse to write anything
    # that *looks* like shell code — prevents an attacker who tricks a privileged
    # user into running `--config-set` with a crafted value from later exploiting
    # a consumer that mis-handles the value (logging, error messages, etc.).
    # Newlines are rejected because they'd break the line-oriented config format.
    if [ -n "$value" ] \
       && printf '%s' "$value" | LC_ALL=C grep -qE '[][$`\\;|&()<>]|[[:cntrl:]]'; then
        echo "Error: value for $key contains disallowed characters" >&2
        echo "       Disallowed: \$ \` \\ ; | & ( ) < > [ ] and control characters (incl. newline)" >&2
        echo "       Use only letters, digits, and these safe symbols: / . _ - : = + @ space" >&2
        return 1
    fi

    local cfg
    cfg=$(_config_write_path)
    local cfg_dir
    cfg_dir=$(dirname "$cfg")

    if ! mkdir -p "$cfg_dir" 2>/dev/null; then
        echo "Error: cannot create config directory: $cfg_dir" >&2
        return 1
    fi

    local tmp="${cfg}.tmp.$$"
    touch "$cfg" 2>/dev/null || true
    # Rewrite file: drop any existing line for this key, then append new value (if non-empty)
    {
        if [ -f "$cfg" ]; then
            grep -vE "^[[:space:]]*${key}=" "$cfg" || true
        fi
        if [ -n "$value" ]; then
            # SECURITY: always double-quote the value. After the validator above,
            # the value can only contain safe printable ASCII (letters, digits,
            # space, / . _ - : = + @), so the only char we need to worry about
            # inside double-quotes is `"` itself — which is already rejected.
            # Always quoting (vs conditionally) removes a foot-gun where a future
            # config key might contain a `#` or space and get written unquoted.
            echo "${key}=\"${value}\""
        fi
    } > "$tmp"

    if ! mv "$tmp" "$cfg"; then
        rm -f "$tmp" 2>/dev/null || true
        echo "Error: could not write $cfg" >&2
        return 1
    fi

    # Restrict permissions if it holds a key path
    chmod 600 "$cfg" 2>/dev/null || true

    if [ -z "$value" ]; then
        log_ok "Removed ${key} from ${cfg}"
    else
        log_ok "Set ${key} in ${cfg}"
        # Safety note when enabling encryption without a key
        if [ "$key" = "BACKUP_ENCRYPT" ] && [ "$value" = "1" ] && [ -z "${BACKUP_KEY_FILE:-}" ]; then
            local key_in_file
            key_in_file=$(grep -m1 '^BACKUP_KEY_FILE=' "$cfg" 2>/dev/null | cut -d= -f2- || true)
            if [ -z "$key_in_file" ]; then
                log_warn "BACKUP_ENCRYPT=1 but BACKUP_KEY_FILE is not set."
                log_warn "Add it with:  $0 --config-set BACKUP_KEY_FILE=/etc/cloudpi/backup.key"
            fi
        fi
    fi
    echo "Applied config file: $cfg"
}

# ============================================================
# First-Time Deployment (--init)
# ============================================================
do_init() {
    check_interrupted_restore

    local new_tag=$1
    local new_db_tag=$2
    DEPLOY_IN_PROGRESS=true

    validate_tag "$new_tag"
    validate_tag "$new_db_tag"

    echo ""
    echo "=========================================="
    echo "  CloudPi First-Time Deployment"
    echo "=========================================="
    echo "  App tag:     ${new_tag}"
    echo "  DB tag:      ${new_db_tag}"
    echo "  Repository:  ${DOCKER_REPOSITORY}"
    echo "=========================================="
    echo ""

    # --- Step 1: Prerequisites ---
    check_prerequisites

    # --- Step 1.5: Pre-flight checks (before any destructive action) ---
    if ! preflight_check "$new_tag" "$new_db_tag"; then
        DEPLOY_IN_PROGRESS=false
        exit 1
    fi

    # --- Step 2: Check for existing containers or data ---
    local has_existing=false
    if is_container_running "$APP_CONTAINER" || is_container_running "$DB_CONTAINER"; then
        log_warn "Containers are already running."
        has_existing=true
    elif run_docker inspect "$APP_CONTAINER" >/dev/null 2>&1 || run_docker inspect "$DB_CONTAINER" >/dev/null 2>&1; then
        log_warn "Stopped containers exist from a previous installation."
        has_existing=true
    elif run_docker volume ls -q --filter "name=mysql_data" 2>/dev/null | grep -q .; then
        log_warn "Existing MySQL data volume detected."
        has_existing=true
    fi

    if [ "$has_existing" = true ]; then
        log_warn "Use './cp_upgrade.sh <tag>' for upgrades, not --init."
        if ! confirm_action "Force first-time init anyway? (will stop existing containers)"; then
            log_info "Init cancelled"
            exit 0
        fi
        stop_and_remove_app || true  # Best-effort during init cleanup
        run_compose -f "$COMPOSE_FILE" stop db 2>/dev/null || true
    fi

    # --- Step 3: Set image tags (app + db) ---
    # Create a single .bak before any tag modification (prevents BUG-004 race)
    rm -f "${COMPOSE_FILE}.bak" 2>/dev/null || true
    cp "$COMPOSE_FILE" "${COMPOSE_FILE}.bak"
    local current_tag
    current_tag=$(get_current_tag)
    if [ -z "$current_tag" ]; then
        log_error "Cannot determine app image tag from $COMPOSE_FILE"
        log_error "Ensure docker-compose.yml has an image line like: image: ${DOCKER_REPOSITORY}:<tag>"
        exit 1
    fi
    if [ "$current_tag" != "$new_tag" ]; then
        log_info "Updating app image tag: ${current_tag} → ${new_tag}"
        if ! set_image_tag "$new_tag"; then
            log_error "Failed to update app image tag in $COMPOSE_FILE"
            DEPLOY_IN_PROGRESS=false
            exit 1
        fi
    fi

    local current_db_tag
    current_db_tag=$(get_db_tag)
    if [ -z "$current_db_tag" ]; then
        log_error "Cannot determine DB image tag from $COMPOSE_FILE"
        exit 1
    fi
    if [ "$current_db_tag" != "$new_db_tag" ]; then
        log_info "Updating DB image tag: ${current_db_tag} → ${new_db_tag}"
        if ! set_db_image_tag "$new_db_tag"; then
            log_error "Failed to update DB image tag — docker-compose.yml in mixed-tag state"
            if [ -f "${COMPOSE_FILE}.bak" ]; then
                log_warn "Restoring docker-compose.yml from backup"
                cp "${COMPOSE_FILE}.bak" "$COMPOSE_FILE"
            fi
            DEPLOY_IN_PROGRESS=false
            exit 1
        fi
    fi

    # --- Step 4: Pull images (with local cache fallback) ---
    local pull_failed=false

    # Pull app image
    local app_image="${DOCKER_REPOSITORY}:${new_tag}"
    log_info "Pulling app image: $app_image"
    local app_pull_output
    if app_pull_output=$(run_docker pull "$app_image" 2>&1); then
        log_ok "App image pulled: $app_image"
    elif run_docker image inspect "$app_image" >/dev/null 2>&1; then
        log_warn "Pull failed but app image found in local cache: $app_image"
        diagnose_pull_failure "$app_image" "$app_pull_output"
        log_warn "Proceeding with cached image — no registry verification"
    else
        log_error "Failed to pull app image and no local cache: $app_image"
        diagnose_pull_failure "$app_image" "$app_pull_output"
        pull_failed=true
    fi

    # Pull DB image
    local db_image="${DOCKER_REPOSITORY}:${new_db_tag}"
    log_info "Pulling DB image: $db_image"
    local db_pull_output
    if db_pull_output=$(run_docker pull "$db_image" 2>&1); then
        log_ok "DB image pulled: $db_image"
    elif run_docker image inspect "$db_image" >/dev/null 2>&1; then
        log_warn "Pull failed but DB image found in local cache: $db_image"
        diagnose_pull_failure "$db_image" "$db_pull_output"
        log_warn "Proceeding with cached image — no registry verification"
    else
        log_error "Failed to pull DB image and no local cache: $db_image"
        diagnose_pull_failure "$db_image" "$db_pull_output"
        pull_failed=true
    fi

    if [ "$pull_failed" = true ]; then
        log_error "Cannot proceed — required image(s) unavailable"
        DEPLOY_IN_PROGRESS=false
        exit 1
    fi

    # --- Step 5: Start DB ---
    log_info "Starting DB container..."
    if ! run_compose -f "$COMPOSE_FILE" up -d db; then
        log_error "Failed to start DB container — check: docker compose -f $COMPOSE_FILE up -d db"
        DEPLOY_IN_PROGRESS=false
        exit 1
    fi
    if ! wait_for_db; then
        log_error "DB failed to start — check docker logs $DB_CONTAINER"
        DEPLOY_IN_PROGRESS=false
        exit 1
    fi

    # --- Step 6: Start app ---
    log_info "Starting app container..."
    if ! run_compose -f "$COMPOSE_FILE" up -d app; then
        log_error "Failed to start app container — check: docker compose -f $COMPOSE_FILE up -d app"
        DEPLOY_IN_PROGRESS=false
        exit 1
    fi

    # Wait for container to start
    local startup_wait=0
    local startup_max=30
    while [ "$startup_wait" -lt "$startup_max" ]; do
        if is_container_running "$APP_CONTAINER"; then
            break
        fi
        local state
        state=$(run_docker inspect -f '{{.State.Status}}' "$APP_CONTAINER" 2>/dev/null || echo "missing")
        if [ "$state" = "exited" ] || [ "$state" = "dead" ]; then
            log_error "Container exited before startup completed (state: $state)"
            log_error "Check: docker logs $APP_CONTAINER"
            DEPLOY_IN_PROGRESS=false
            exit 1
        fi
        sleep 3
        startup_wait=$((startup_wait + 3))
    done

    if ! is_container_running "$APP_CONTAINER"; then
        log_error "Container not running after ${startup_max}s"
        log_error "Check: docker logs $APP_CONTAINER"
        DEPLOY_IN_PROGRESS=false
        exit 1
    fi

    # --- Step 7: Monitor migration ---
    if monitor_migration; then
        log_ok "Migration succeeded"
    else
        log_error "Migration failed on first-time deployment"
        log_error "Check: docker logs $APP_CONTAINER"
        log_error "No rollback available (first-time init)"
        DEPLOY_IN_PROGRESS=false
        exit 1
    fi

    # --- Step 8: Wait for health ---
    if wait_for_healthy; then
        log_ok "App is healthy"
    else
        log_error "App health check failed on first-time deployment"
        log_error "Check: docker logs $APP_CONTAINER"
        DEPLOY_IN_PROGRESS=false
        exit 1
    fi

    # Deployment succeeded — snapshot phase is optional, clear the flag so
    # cleanup_on_exit doesn't print "deployment interrupted" if snapshot fails
    DEPLOY_IN_PROGRESS=false

    # --- Step 9: Create initial snapshot (baseline for future rollbacks) ---
    mkdir -p "$BACKUP_DIR"
    local backup_ts
    backup_ts=$(date +%Y%m%d_%H%M%S)
    local init_backup
    local init_redis_backup
    local init_app_backup
    init_backup=$(maybe_enc_suffix "${BACKUP_DIR}/db_volume_${backup_ts}.tar")
    init_redis_backup=$(maybe_enc_suffix "${BACKUP_DIR}/redis_volume_${backup_ts}.tar")
    init_app_backup=$(maybe_enc_suffix "${BACKUP_DIR}/cloudpi_volume_${backup_ts}.tar")

    log_info "Creating initial snapshot for future rollbacks..."
    local snapshot_created=false

    # Stop app briefly for consistent backup
    if ! stop_and_remove_app; then
        log_warn "App container did not stop cleanly — snapshot may be inconsistent"
    fi

    if ! stop_db_verified 60; then
        log_warn "Could not stop DB for snapshot — skipping initial snapshot"
    else
        if backup_db_volume "$init_backup"; then
            backup_redis_volume "$init_redis_backup" || init_redis_backup=""
            backup_app_volume "$init_app_backup" || init_app_backup=""
            if create_snapshot "$init_backup" "$init_redis_backup" "$init_app_backup" "init"; then
                snapshot_created=true
            else
                log_warn "Snapshot metadata write failed — backup files exist but snapshot not recorded"
            fi
        else
            log_warn "DB backup failed — no initial snapshot"
        fi
    fi

    # Restart everything
    log_info "Starting all services..."
    if ! run_compose -f "$COMPOSE_FILE" up -d db; then
        log_error "Failed to restart DB after snapshot — manual intervention needed"
        DEPLOY_IN_PROGRESS=false
        exit 1
    fi
    if ! wait_for_db; then
        log_error "DB failed to restart after snapshot — manual intervention needed"
        DEPLOY_IN_PROGRESS=false
        exit 1
    fi
    if ! run_compose -f "$COMPOSE_FILE" up -d app; then
        log_error "Failed to restart app after snapshot — manual intervention needed"
        DEPLOY_IN_PROGRESS=false
        exit 1
    fi
    if ! wait_for_healthy; then
        log_error "App failed to restart after snapshot — manual intervention needed"
        DEPLOY_IN_PROGRESS=false
        exit 1
    fi

    # --- Step 10: Save state ---
    save_state "$new_tag" "init_deployed" "" "${init_backup:-}" "${init_redis_backup:-}" "${init_app_backup:-}" "" "$new_db_tag" ""
    DEPLOY_IN_PROGRESS=false

    local snapshot_msg="created (baseline for future rollbacks)"
    if [ "$snapshot_created" != true ]; then
        snapshot_msg="SKIPPED (run a normal deploy to create one)"
    fi

    echo ""
    echo "=========================================="
    log_ok "FIRST-TIME DEPLOYMENT COMPLETE"
    echo "=========================================="
    echo "  Image:   ${DOCKER_REPOSITORY}:${new_tag}"
    echo "  Status:  deployed"
    echo "  Snapshot: ${snapshot_msg}"
    echo ""
    echo "  Future upgrades: ./cp_upgrade.sh <new-tag>"
    echo "=========================================="
    echo ""
}

# ============================================================
# Main
# ============================================================
usage() {
    echo "Usage: $0 <new-tag> | --init <tag> | --status | --history | --restore [N] | --rollback | --prune [N] | --delete <IDs> | --backup"
    echo ""
    echo "Commands:"
    echo "  <new-tag>       Deploy a new image tag (e.g., Cloudpi_v1.0.322)"
    echo "  --init <app-tag> <db-tag>  First-time deployment (skips backup, creates baseline)"
    echo "  --status        Show current deployment state"
    echo "  --history       List all deployment snapshots"
    echo "  --restore [N]   Restore to snapshot N (interactive picker if N omitted)"
    echo "  --rollback      Roll back to the last known good version"
    echo "  --prune [N]     Delete old snapshots, keep last N (default: ${MAX_SNAPSHOTS})"
    echo "  --delete <IDs>  Delete specific snapshot(s) by ID. Comma-separated or 'all'."
    echo "                  Refuses newest snapshot unless --force is also given."
    echo "                  Refuses to delete all snapshots (at least one must remain)."
    echo "  --backup, -b    Create an ad-hoc snapshot without deploying a new image."
    echo "                  Stops containers briefly, backs up DB + Redis + App volumes,"
    echo "                  restarts. Useful for manual checkpoints or cron-scheduled backups."
    echo "                  Add 'skip-prune' arg to keep all existing snapshots."
    echo "  --config-show   Show current effective configuration and which config file is active"
    echo "  --config-set K=V  Persist a setting to cp_upgrade.conf so future runs inherit it"
    echo "                  Allowed keys: BACKUP_DIR BACKUP_ENCRYPT BACKUP_KEY_FILE"
    echo "                  BACKUP_ENC_CIPHER MAX_SNAPSHOTS MIGRATION_TIMEOUT HEALTH_TIMEOUT"
    echo "                  Remove a key:  $0 --config-set KEY=   (empty value)"
    echo ""
    echo "Options:"
    echo "  --yes, -y             Auto-confirm all prompts (for CI/automation)"
    echo "  --force, -f           (with --delete) Allow deleting the newest snapshot"
    echo "  --backup-dir <path>   Override backup directory for this invocation only."
    echo "                        Relative paths are resolved relative to the script dir."
    echo "                        Example: --backup-dir /data/cloudpi-backups"
    echo "                        Example: --backup-dir=/mnt/archive/backups"
    echo ""
    echo "Environment variables:"
    echo "  MIGRATION_TIMEOUT   Max seconds to wait for migration (default: 300)"
    echo "  HEALTH_TIMEOUT      Max seconds to wait for health check (default: 120)"
    echo "  MAX_SNAPSHOTS       Max snapshots to keep (default: 5, 0 = unlimited)"
    echo "  BACKUP_DIR          Backup location (default: \${SCRIPT_DIR}/backups)"
    echo "                      Overridden by --backup-dir if both are set."
    echo "  BACKUP_ENCRYPT      Set to 1 to encrypt backups with AES-256-CBC (default: 0)"
    echo "  BACKUP_KEY_FILE     Path to key file (required when BACKUP_ENCRYPT=1)"
    echo "                      Create: head -c 64 /dev/urandom | base64 > /etc/cloudpi/backup.key"
    echo "                              chmod 600 /etc/cloudpi/backup.key"
    echo "  BACKUP_ENC_CIPHER   OpenSSL cipher name (default: aes-256-cbc)"
    echo ""
    echo "Examples:"
    echo "  ./cp_upgrade.sh --init Cloudpi_v1.0.322 Cloudpi_db_v1.0.322  # First-time install"
    echo "  ./cp_upgrade.sh Cloudpi_v1.0.322        # Deploy new version"
    echo "  ./cp_upgrade.sh --status                 # Check current state"
    echo "  ./cp_upgrade.sh --history                # See deployment history"
    echo "  ./cp_upgrade.sh --restore 2              # Restore to snapshot #2"
    echo "  ./cp_upgrade.sh --restore                # Interactive restore picker"
    echo "  ./cp_upgrade.sh --rollback               # Quick rollback to previous"
    echo "  ./cp_upgrade.sh --prune 3                # Keep only last 3 snapshots"
    echo "  ./cp_upgrade.sh --delete 2               # Delete snapshot #2"
    echo "  ./cp_upgrade.sh --delete 2,4,7           # Delete multiple snapshots"
    echo "  ./cp_upgrade.sh --delete 5 --force       # Delete newest snapshot (dangerous)"
    echo "  ./cp_upgrade.sh --backup                 # Ad-hoc snapshot of current state"
    echo "  ./cp_upgrade.sh --backup --yes           # Scriptable (no prompt; e.g., cron)"
    echo "  ./cp_upgrade.sh --backup --skip-prune    # Backup but keep all existing snapshots"
    echo "  ./cp_upgrade.sh --backup-dir /data/backups --backup      # Backup to different dir (one-time)"
    echo "  ./cp_upgrade.sh --backup-dir /data/backups --history     # Read snapshots from different dir"
    echo "  BACKUP_DIR=/data/backups ./cp_upgrade.sh --backup        # Same via env var"
    echo ""
    echo "  # One-time setup — persist config so you never have to pass flags again:"
    echo "  ./cp_upgrade.sh --config-set BACKUP_DIR=/data/cloudpi-backups"
    echo "  ./cp_upgrade.sh --config-set BACKUP_ENCRYPT=1"
    echo "  ./cp_upgrade.sh --config-set BACKUP_KEY_FILE=/etc/cloudpi/backup.key"
    echo "  ./cp_upgrade.sh --config-show     # verify"
    echo "  ./cp_upgrade.sh --backup          # now uses saved settings automatically"
    echo ""
    echo "  BACKUP_ENCRYPT=1 BACKUP_KEY_FILE=/etc/cloudpi/backup.key ./cp_upgrade.sh v1.0.323"
}

# NOTE: --yes / -y / --force / -f were already stripped by the early normalization
# block near the top of the script (see Fix #4). Arg parsing here can assume $1 is
# the subcommand and any remaining positional args are subcommand-specific.

case "${1:-}" in
    --status|-s)
        do_status
        ;;
    --history|-H)
        do_history
        ;;
    --restore)
        do_restore "${2:-}"
        ;;
    --init)
        if [ -z "${2:-}" ] || [ -z "${3:-}" ]; then
            echo "Error: --init requires both app and db image tags"
            echo "Usage: $0 --init <app-tag> <db-tag>"
            exit 1
        fi
        do_init "$2" "$3"
        ;;
    --rollback|-r)
        do_rollback
        ;;
    --prune)
        do_prune "${2:-$MAX_SNAPSHOTS}"
        ;;
    --delete)
        # --force was already consumed by the early normalizer into AUTO_FORCE.
        # Only the ID list remains in $2.
        do_delete_snapshot "${2:-}" "$AUTO_FORCE"
        ;;
    --backup|-b)
        # Optional: --skip-prune to keep all existing snapshots regardless of MAX_SNAPSHOTS
        do_backup "${2:-}"
        ;;
    --config-show)
        do_config_show
        ;;
    --config-set)
        do_config_set "${2:-}"
        ;;
    --help|-h|"")
        usage
        ;;
    --*)
        echo "Unknown option: $1"
        usage
        exit 1
        ;;
    *)
        do_deploy "$1"
        ;;
esac
