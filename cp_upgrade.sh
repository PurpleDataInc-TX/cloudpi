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
#   ./cp_upgrade.sh --init <app-tag> <db-tag>  # First-time deployment (no existing data)
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
LOCKOUT_FILE_PATH="/app/backups/.migration_lockout"

APP_CONTAINER="cloudpi-app"
DB_CONTAINER="cloudpi-db"
DOCKER_REPOSITORY="cloudpi1/cloudpi"
BACKUP_DIR="${SCRIPT_DIR}/backups"
DEPLOY_IN_PROGRESS=false

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

acquire_deploy_lock() {
    # Only called for mutating operations (deploy, rollback, restore, prune, init)
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        echo "Error: Another cp_upgrade.sh is already running (lock: $LOCK_FILE)" >&2
        echo "If this is stale, remove the lock: rm -f $LOCK_FILE" >&2
        exit 1
    fi
}

# Skip lock for read-only commands (--status, --history, --help)
case "${1:-}" in
    --status|-s|--history|-H|--help|-h|"")
        # No lock needed for read-only operations
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

if docker info >/dev/null 2>&1; then
    run_docker() { docker "$@"; }
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
        sudo docker "$@"
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
# Read-only commands (--status, --history, --help) don't need volume access.
case "${1:-}" in
    --status|-s|--history|-H|--help|-h|"")
        # No FS sudo detection needed for read-only operations
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

# Detect compose command: v2 plugin ("docker compose") vs v1 standalone ("docker-compose")
if run_docker compose version >/dev/null 2>&1; then
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
resolve_compose_project
# Export so all run_compose calls use the correct project regardless of cwd
if [ -n "$COMPOSE_PROJECT" ]; then
    export COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT"
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
    local tmp="${STATE_FILE}.tmp"
    if ! {
        echo "current_tag=${current_tag}"
        echo "rollback_tag=${rollback_tag}"
        echo "status=${status}"
        echo "backup=${backup}"
        echo "backup_redis=${backup_redis}"
        echo "backup_app=${backup_app}"
        echo "backup_checksum=${backup_checksum}"
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
    local journal_file="${BACKUP_DIR}/.restore_journal"
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
    cp "$COMPOSE_FILE" "${COMPOSE_FILE}.bak"
    # Scope replacement to the 'app:' service block only (prevents cross-service collision)
    sed -i "/^  app:/,/^  [a-z]/ s|image: ${DOCKER_REPOSITORY}:${current_tag}|image: ${DOCKER_REPOSITORY}:${new_tag}|" "$COMPOSE_FILE"
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
    cp "$COMPOSE_FILE" "${COMPOSE_FILE}.bak"
    # Scope replacement to the 'db:' service block only (prevents cross-service collision)
    sed -i "/^  db:/,/^  [a-z]/ s|image: ${DOCKER_REPOSITORY}:${current_db_tag}|image: ${DOCKER_REPOSITORY}:${new_tag}|" "$COMPOSE_FILE"
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
    # Security: ensure backup_file is under BACKUP_DIR and matches expected pattern.
    # Prevents path traversal via tampered .meta files.
    local filepath=$1
    if [ -z "$filepath" ]; then
        return 1
    fi
    # Resolve to absolute path (without requiring file to exist)
    local resolved
    resolved=$(cd "$(dirname "$filepath")" 2>/dev/null && pwd)/$(basename "$filepath") 2>/dev/null || resolved=""
    if [ -z "$resolved" ]; then
        return 1
    fi
    # Must be under BACKUP_DIR
    local abs_backup_dir
    abs_backup_dir=$(cd "$BACKUP_DIR" 2>/dev/null && pwd) || abs_backup_dir="$BACKUP_DIR"
    case "$resolved" in
        "${abs_backup_dir}"/*)
            # Must match expected tar filename pattern
            local base
            base=$(basename "$resolved")
            if [[ "$base" =~ ^(db|redis|cloudpi)_volume_[0-9]{8}_[0-9]{6}\.tar$ ]]; then
                return 0
            fi
            ;;
    esac
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
        # Need ~3x volume size: DB backup + Redis backup + App backup (rough estimate)
        local needed_kb=$((vol_size_kb * 3))
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

    # tar the volume directory (preserves permissions, ownership, symlinks)
    local tar_rc=0
    run_maybe_sudo tar -cf "$backup_file" -C "$vol_path" . || tar_rc=$?
    if [ "$tar_rc" -ne 0 ]; then
        log_error "tar command failed (exit $tar_rc) — ${label} backup incomplete"
        run_maybe_sudo rm -f "$backup_file" 2>/dev/null || true
        return 1
    fi

    # Restrict backup file permissions (contains sensitive DB data)
    run_maybe_sudo chmod 600 "$backup_file" 2>/dev/null || true

    if [ ! -s "$backup_file" ]; then
        log_error "${label} backup file is empty"
        return 1
    fi

    # Validate tar archive integrity (ensures it's not truncated/corrupted)
    if ! run_maybe_sudo tar -tf "$backup_file" >/dev/null 2>&1; then
        log_error "${label} backup archive is corrupt (tar -tf failed)"
        run_maybe_sudo rm -f "$backup_file" 2>/dev/null || true
        return 1
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

    # Validate tar archive paths — reject entries with absolute paths or ../
    local bad_paths
    bad_paths=$(run_maybe_sudo tar -tf "$backup_file" 2>/dev/null | grep -E '(^/|\.\.)' || true)
    if [ -n "$bad_paths" ]; then
        log_error "Tar archive contains unsafe paths (absolute or ../) — refusing to extract"
        log_error "Offending entries: $(echo "$bad_paths" | head -5)"
        return 1
    fi

    # Safety: extract to temp, then atomic swap preserving original until copy verified.
    # Original data is kept as .restore_bak until the new data is fully in place.
    # A journal file tracks restore state for crash recovery.
    local temp_restore="${vol_path}.restore_tmp"
    local original_bak="${vol_path}.restore_bak"
    local journal_file="${BACKUP_DIR}/.restore_journal"

    # Write journal BEFORE any destructive action (for crash recovery)
    run_maybe_sudo mkdir -p "$BACKUP_DIR" 2>/dev/null || true
    if ! printf '%s\n' "label=${label}|vol_path=${vol_path}|backup_file=${backup_file}|state=extracting|ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        | run_maybe_sudo tee "$journal_file" > /dev/null; then
        log_warn "Could not write restore journal — crash recovery will not be available"
    fi

    run_maybe_sudo rm -rf "$temp_restore" "$original_bak"
    run_maybe_sudo mkdir -p "$temp_restore"
    if ! run_maybe_sudo tar -xf "$backup_file" -C "$temp_restore"; then
        log_error "Tar extraction failed — original ${label} data is intact"
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
    # Usage: backup_current_state [--skip-prune]
    #   --skip-prune: don't auto-prune snapshots (protects target snapshot during restore)
    # Returns 0 on success, 1 on failure.
    local skip_prune=false
    if [ "${1:-}" = "--skip-prune" ]; then
        skip_prune=true
    fi

    local backup_ts
    backup_ts=$(date +%Y%m%d_%H%M%S)
    mkdir -p "$BACKUP_DIR"

    local pre_db="${BACKUP_DIR}/db_volume_${backup_ts}.tar"
    local pre_redis="${BACKUP_DIR}/redis_volume_${backup_ts}.tar"
    local pre_app="${BACKUP_DIR}/cloudpi_volume_${backup_ts}.tar"

    log_info "Backing up current state before rollback/restore..."

    if ! backup_db_volume "$pre_db"; then
        log_error "Current state DB backup failed"
        return 1
    fi

    # Redis and App are non-fatal
    if ! backup_redis_volume "$pre_redis"; then
        log_warn "Current state Redis backup failed — continuing"
        pre_redis=""
    fi
    if ! backup_app_volume "$pre_app"; then
        log_warn "Current state App backup failed — continuing"
        pre_app=""
    fi

    # Temporarily disable auto-prune if requested (to protect target snapshot)
    local saved_max_snapshots="$MAX_SNAPSHOTS"
    if [ "$skip_prune" = true ]; then
        MAX_SNAPSHOTS=0
    fi

    if ! create_snapshot "$pre_db" "$pre_redis" "$pre_app"; then
        log_warn "Snapshot metadata write failed — backup files exist but snapshot not recorded"
        MAX_SNAPSHOTS="$saved_max_snapshots"
        return 1
    fi

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
    local backup_file=$1
    local redis_backup_file=${2:-}
    local app_backup_file=${3:-}
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
    if command -v sha256sum >/dev/null 2>&1; then
        local hash_output
        hash_output=$(run_maybe_sudo sha256sum "$backup_file" 2>/dev/null)
        local hash_value
        hash_value=$(echo "$hash_output" | cut -d' ' -f1)
        # Validate hash is exactly 64 hex characters
        if [[ "$hash_value" =~ ^[0-9a-f]{64}$ ]]; then
            snap_checksum="sha256:${hash_value}"
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
    } > "$tmp_meta"

    if ! mv "$tmp_meta" "$meta_file"; then
        log_warn "Failed to write snapshot metadata — snapshot not recorded"
        rm -f "$tmp_meta"
        return 1
    fi

    log_ok "Snapshot #${snap_id} created (${snap_app_tag} / ${snap_db_tag}, ${snap_size})"

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

    printf "  %-4s %-20s %-24s %-24s %s\n" "#" "Date" "App Tag" "DB Tag" "Size"
    for meta_file in "${meta_files[@]}"; do
        local s_id s_ts s_app s_db s_size s_date
        s_id=$(grep -m1 '^id=' "$meta_file" | cut -d= -f2- || true)
        s_ts=$(grep -m1 '^timestamp=' "$meta_file" | cut -d= -f2- || true)
        s_app=$(grep -m1 '^app_tag=' "$meta_file" | cut -d= -f2- || true)
        s_db=$(grep -m1 '^db_tag=' "$meta_file" | cut -d= -f2- || true)
        s_size=$(grep -m1 '^size=' "$meta_file" | cut -d= -f2- || true)
        # Format timestamp: 2026-02-17T14:30:22Z → 2026-02-17 14:30
        s_date=$(echo "$s_ts" | sed 's/T/ /;s/:..Z$//')
        printf "  %-4s %-20s %-24s %-24s %s\n" "$s_id" "$s_date" "$s_app" "$s_db" "$s_size"
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

    # Final fallback: if container is running but healthcheck never reported, treat as OK
    # (single-container deployment — if it's running, it's probably fine)
    if is_container_running "$APP_CONTAINER"; then
        local final_health
        final_health=$(run_docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' "$APP_CONTAINER" 2>/dev/null || echo "missing")
        case "$final_health" in
            missing|""|"<no value>"|"null")
                log_warn "No Docker healthcheck configured — container is running, treating as healthy"
                return 0
                ;;
        esac
    fi

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
    log_info "Pre-pulling new image (containers still running)..."
    if run_docker pull "${DOCKER_REPOSITORY}:${new_tag}" >/dev/null 2>&1; then
        log_ok "Image pre-pulled (cached for deploy)"
    elif run_docker image inspect "${DOCKER_REPOSITORY}:${new_tag}" >/dev/null 2>&1; then
        log_warn "Pull failed but image exists in local cache — proceeding with cached image"
    else
        log_error "Failed to pull image ${DOCKER_REPOSITORY}:${new_tag} and no local cache"
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
    CURRENT_BACKUP="${BACKUP_DIR}/db_volume_${backup_ts}.tar"
    CURRENT_REDIS_BACKUP="${BACKUP_DIR}/redis_volume_${backup_ts}.tar"
    CURRENT_APP_BACKUP="${BACKUP_DIR}/cloudpi_volume_${backup_ts}.tar"

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

    save_state "$current_tag" "rollback_target" "$current_tag" "$CURRENT_BACKUP" "$CURRENT_REDIS_BACKUP" "$CURRENT_APP_BACKUP" "$CURRENT_BACKUP_CHECKSUM"
    # Create deployment snapshot (for multi-level rollback via --history/--restore)
    if ! create_snapshot "$CURRENT_BACKUP" "$CURRENT_REDIS_BACKUP" "$CURRENT_APP_BACKUP"; then
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
    save_state "$new_tag" "deployed" "$current_tag" "$CURRENT_BACKUP" "$CURRENT_REDIS_BACKUP" "$CURRENT_APP_BACKUP" "$CURRENT_BACKUP_CHECKSUM"
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

    # Stop app
    if ! stop_and_remove_app; then
        log_error "App container did not stop — cannot safely rollback"
        return 1
    fi

    # Resolve backup paths from state file or current deploy run variables
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

    # Validate backup paths before using them (prevents path traversal from corrupted state)
    if [ -n "$backup_path" ] && ! validate_backup_path "$backup_path"; then
        log_warn "DB backup path failed validation: $backup_path — skipping DB restore"
        backup_path=""
    fi
    if [ -n "$redis_backup_path" ] && ! validate_backup_path "$redis_backup_path"; then
        log_warn "Redis backup path failed validation — skipping Redis restore"
        redis_backup_path=""
    fi
    if [ -n "$app_backup_path" ] && ! validate_backup_path "$app_backup_path"; then
        log_warn "App backup path failed validation — skipping App restore"
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
                    save_state "$rollback_tag" "rollback_failed" "" "$backup_path" "$redis_backup_path" "$app_backup_path" "$stored_checksum"
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
            save_state "$rollback_tag" "rollback_failed" "" "$backup_path" "$redis_backup_path" "$app_backup_path" "$stored_checksum"
            return 1
        fi

        # Restore DB volume (critical — abort rollback if this fails)
        if [ -n "$backup_path" ] && [ -f "$backup_path" ]; then
            if restore_db_volume "$backup_path"; then
                log_ok "Database volume restored"
            else
                log_error "Database volume restore failed — aborting rollback to prevent data corruption"
                log_error "Original data may still be intact. Manual intervention required."
                save_state "$rollback_tag" "rollback_failed" "" "$backup_path" "$redis_backup_path" "$app_backup_path"
                return 1
            fi
        else
            log_error "No DB backup found — cannot rollback without database restore"
            log_error "App would start against migrated data with old code — aborting"
            save_state "$rollback_tag" "rollback_failed" "" "$backup_path" "$redis_backup_path" "$app_backup_path"
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
            save_state "$rollback_tag" "rollback_failed" "" "$backup_path" "$redis_backup_path" "$app_backup_path"
            return 1
        fi
        if ! wait_for_db; then
            log_error "DB failed to start after restore — manual intervention needed"
            save_state "$rollback_tag" "rollback_failed" "" "$backup_path" "$redis_backup_path" "$app_backup_path"
            return 1
        fi
    else
        log_error "No volume backups found — cannot rollback without DB restore"
        log_error "Rolling back the app without restoring the database would run old code against migrated data"
        save_state "$rollback_tag" "rollback_failed" "" "$backup_path" "$redis_backup_path" "$app_backup_path"
        return 1
    fi

    # Clear lockout after container is stopped
    clear_migration_lockout

    # Revert tag
    log_info "Reverting image tag to: $rollback_tag"
    if ! set_image_tag "$rollback_tag"; then
        log_error "Failed to revert image tag in docker-compose.yml — file may be corrupted"
        log_error "Manual fix: edit $COMPOSE_FILE and set the app image tag to $rollback_tag"
        save_state "$rollback_tag" "rollback_failed" "" "$backup_path" "$redis_backup_path" "$app_backup_path"
        return 1
    fi

    # Verify rollback image exists (pre-check before starting)
    if ! run_docker image inspect "${DOCKER_REPOSITORY}:${rollback_tag}" >/dev/null 2>&1; then
        log_warn "Rollback image not in local cache — pulling from registry..."
        if ! run_docker pull "${DOCKER_REPOSITORY}:${rollback_tag}" >/dev/null 2>&1; then
            log_error "Cannot pull rollback image ${DOCKER_REPOSITORY}:${rollback_tag} — registry unreachable and image not cached"
            log_error "Manual fix: docker pull ${DOCKER_REPOSITORY}:${rollback_tag}, then re-run $0 --rollback"
            save_state "$rollback_tag" "rollback_failed" "" "$backup_path" "$redis_backup_path" "$app_backup_path"
            return 1
        fi
    fi

    # Start with old image
    log_info "Starting app with previous image..."
    if ! run_compose -f "$COMPOSE_FILE" up -d app; then
        log_error "Failed to start app container with rollback image"
        save_state "$rollback_tag" "rollback_failed" "" "$backup_path" "$redis_backup_path" "$app_backup_path"
        return 1
    fi

    sleep 3

    # Wait for health (reuse existing function that handles missing healthcheck)
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

    # Check if container is at least running (health check might just be slow)
    if is_container_running "$APP_CONTAINER"; then
        save_state "$rollback_tag" "rolled_back" "" "$backup_path" "$redis_backup_path" "$app_backup_path"
        clear_deploy_phase
        log_warn "Rollback container is running but health check hasn't passed yet"
        log_warn "Monitor with: docker logs -f $APP_CONTAINER"
        return 0
    fi

    log_error "Rollback did not produce a healthy container — manual intervention needed"
    save_state "$rollback_tag" "rollback_failed" "" "$backup_path" "$redis_backup_path" "$app_backup_path"
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
        elif ! backup_current_state; then
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

    # --- Offer to backup current state before restoring ---
    if confirm_action "Take a backup of the current state before restoring?"; then
        if ! backup_current_state --skip-prune; then
            log_warn "Pre-restore backup failed"
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
        save_state "$current_tag" "restore_failed" "$current_tag" "$snap_backup"
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
        save_state "$snap_app_tag" "restore_failed" "$current_tag" "$snap_backup"
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
            save_state "$snap_app_tag" "restore_failed" "$current_tag" "$snap_backup"
            DEPLOY_IN_PROGRESS=false
            exit 1
        fi
    fi

    # --- Clear migration lockout ---
    clear_migration_lockout

    # --- Start DB ---
    log_info "Starting DB container..."
    if ! run_compose -f "$COMPOSE_FILE" up -d db; then
        log_error "Failed to start DB container — compose error"
        save_state "$snap_app_tag" "restore_failed" "$current_tag" "$snap_backup"
        DEPLOY_IN_PROGRESS=false
        exit 1
    fi
    if ! wait_for_db; then
        log_error "DB failed to start after restore — manual intervention needed"
        save_state "$snap_app_tag" "restore_failed" "$current_tag" "$snap_backup"
        DEPLOY_IN_PROGRESS=false
        exit 1
    fi

    # --- Start app ---
    log_info "Starting app container..."
    if ! run_compose -f "$COMPOSE_FILE" up -d app; then
        log_error "Failed to start app container after restore"
        save_state "$snap_app_tag" "restore_failed" "$current_tag" "$snap_backup"
        DEPLOY_IN_PROGRESS=false
        exit 1
    fi

    sleep 3

    # Wait for health (using existing function)
    local restore_status="restored_from_snapshot_${target_id}"
    if wait_for_healthy; then
        log_ok "App is healthy"
    elif is_container_running "$APP_CONTAINER"; then
        restore_status="restored_unhealthy_from_snapshot_${target_id}"
        log_warn "App health check timed out but container is running"
        log_warn "Monitor with: docker logs -f $APP_CONTAINER"
    else
        log_error "App container is not running after restore — restore incomplete"
        save_state "$snap_app_tag" "restore_failed" "$current_tag" "$snap_backup"
        DEPLOY_IN_PROGRESS=false
        exit 1
    fi

    # --- Update state ---
    save_state "$snap_app_tag" "$restore_status" "$current_tag" "$snap_backup" "$snap_redis_backup" "$snap_app_backup"
    DEPLOY_IN_PROGRESS=false

    echo ""
    echo "=========================================="
    if [ "$restore_status" = "restored_from_snapshot_${target_id}" ]; then
        log_ok "RESTORE COMPLETE — Snapshot #${target_id}"
    else
        log_warn "RESTORE COMPLETE (UNHEALTHY) — Snapshot #${target_id}"
    fi
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

    # --- Step 4: Pull images ---
    log_info "Pulling images..."
    local pull_output
    pull_output=$(run_compose -f "$COMPOSE_FILE" pull 2>&1) || {
        log_error "Failed to pull images:"
        log_error "  App: ${DOCKER_REPOSITORY}:${new_tag}"
        log_error "  DB:  ${DOCKER_REPOSITORY}:${new_db_tag}"
        if echo "$pull_output" | grep -qiE 'unauthorized|denied|authentication|403|401'; then
            log_error "Authentication error — run: docker login ${DOCKER_REPOSITORY%%/*}"
        elif echo "$pull_output" | grep -qiE 'not found|manifest unknown|404'; then
            log_error "Image tag not found — verify tags exist in the registry"
        elif echo "$pull_output" | grep -qiE 'timeout|connection refused|no such host|network'; then
            log_error "Network error — check connectivity to Docker registry"
        fi
        DEPLOY_IN_PROGRESS=false
        exit 1
    }

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

    # --- Step 9: Create initial snapshot (baseline for future rollbacks) ---
    mkdir -p "$BACKUP_DIR"
    local backup_ts
    backup_ts=$(date +%Y%m%d_%H%M%S)
    local init_backup="${BACKUP_DIR}/db_volume_${backup_ts}.tar"
    local init_redis_backup="${BACKUP_DIR}/redis_volume_${backup_ts}.tar"
    local init_app_backup="${BACKUP_DIR}/cloudpi_volume_${backup_ts}.tar"

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
            if create_snapshot "$init_backup" "$init_redis_backup" "$init_app_backup"; then
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
    save_state "$new_tag" "init_deployed" "" "${init_backup:-}" "${init_redis_backup:-}" "${init_app_backup:-}"
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
    echo "Usage: $0 <new-tag> | --init <tag> | --status | --history | --restore [N] | --rollback | --prune [N]"
    echo ""
    echo "Commands:"
    echo "  <new-tag>       Deploy a new image tag (e.g., Cloudpi_v1.0.322)"
    echo "  --init <app-tag> <db-tag>  First-time deployment (skips backup, creates baseline)"
    echo "  --status        Show current deployment state"
    echo "  --history       List all deployment snapshots"
    echo "  --restore [N]   Restore to snapshot N (interactive picker if N omitted)"
    echo "  --rollback      Roll back to the last known good version"
    echo "  --prune [N]     Delete old snapshots, keep last N (default: ${MAX_SNAPSHOTS})"
    echo ""
    echo "Environment variables:"
    echo "  MIGRATION_TIMEOUT   Max seconds to wait for migration (default: 300)"
    echo "  HEALTH_TIMEOUT      Max seconds to wait for health check (default: 120)"
    echo "  MAX_SNAPSHOTS       Max snapshots to keep (default: 5, 0 = unlimited)"
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
}

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
