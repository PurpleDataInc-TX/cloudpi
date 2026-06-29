#!/usr/bin/env bash
# ============================================================================
# setup-syslog.sh — install the CloudPi rsyslog file-tail mirror (Feature 116)
#
# Idempotent host-side installer. Assumes rsyslog is ALREADY installed and
# active (>= 8.25); it NEVER installs rsyslog. It:
#   1. asserts rsyslog active + >= 8.25
#   2. creates /var/log/pico (owner app UID, group syslog) and /var/log/cloudpi
#      (group syslog, writable) — both under /var/log so AppArmor permits rsyslog
#      to read the source and write the mirror
#   3. copies host-config/30-cloudpi.conf -> /etc/rsyslog.d/
#   4. validates with `rsyslogd -N1` and restarts rsyslog (only if valid)
#
# Run as root on the host:  sudo ./setup-syslog.sh
# Reverse: sudo rm /etc/rsyslog.d/30-cloudpi.conf && sudo systemctl restart rsyslog
# ============================================================================
set -euo pipefail

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DROPIN_SRC="$BUNDLE_DIR/host-config/30-cloudpi.conf"
DROPIN_DST="/etc/rsyslog.d/30-cloudpi.conf"
# Host path of the app's log dir. MUST be under /var/log (rsyslog's AppArmor
# profile only permits reads under /var/log/**), and MUST match the compose
# bind mount (/var/log/pico:/var/log/pico) and the drop-in's File= path.
PICO_HOST_DIR="${PICO_HOST_DIR:-/var/log/pico}"
SYSLOG_DIR="${SYSLOG_DIR:-/var/log/cloudpi}"
APP_UID="${APP_UID:-1000}"             # container app user — WRITES the source logs
SYSLOG_USER="${SYSLOG_USER:-syslog}"   # rsyslog priv-drop user (reads source)
SYSLOG_GROUP="${SYSLOG_GROUP:-syslog}" # rsyslog priv-drop group (reads source, writes dest)

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "[setup-syslog] $*"; }

[ "$(id -u)" -eq 0 ] || die "must run as root (sudo ./setup-syslog.sh)"
[ -f "$DROPIN_SRC" ] || die "drop-in not found: $DROPIN_SRC"

# 1. Assert rsyslog active + version >= 8.25 (NEVER install) ------------------
command -v rsyslogd >/dev/null 2>&1 || die "rsyslogd not found — rsyslog must be pre-installed (this script does not install it)"
systemctl is-active --quiet rsyslog || die "rsyslog is not active — start it first (this script does not install/enable rsyslog)"

ver="$(rsyslogd -v 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)"
[ -n "$ver" ] || die "could not determine rsyslog version"
major="${ver%%.*}"; minor="${ver#*.}"
if [ "$major" -lt 8 ] || { [ "$major" -eq 8 ] && [ "$minor" -lt 25 ]; }; then
    die "rsyslog $ver is < 8.25 (no wildcard imfile). Edit $DROPIN_SRC: comment the wildcard input() and uncomment the per-file fallback block, then re-run."
fi
note "rsyslog $ver active (>= 8.25 OK)"

# 2. Create dirs + permissions ------------------------------------------------
# /var/log/pico has TWO stakeholders: the container app (UID $APP_UID) WRITES it,
# and the priv-dropped rsyslog ($SYSLOG_USER/$SYSLOG_GROUP, per $PrivDropToUser)
# READS it. The mirror dest must be WRITABLE by rsyslog. Both MUST be under
# /var/log — rsyslog's AppArmor profile denies reads outside /var/log/**.
getent group  "$SYSLOG_GROUP" >/dev/null || die "host group '$SYSLOG_GROUP' not found (rsyslog priv-drop group)"
getent passwd "$SYSLOG_USER"  >/dev/null || die "host user '$SYSLOG_USER' not found (rsyslog priv-drop user)"
case "$PICO_HOST_DIR" in
    /var/log/*) : ;;
    *) echo "[setup-syslog] WARNING: $PICO_HOST_DIR is outside /var/log — rsyslog's AppArmor profile will DENY reads there; the mirror will be empty. Use an absolute /var/log path." >&2 ;;
esac

# Source: owned by the app UID (container can write), group syslog (rsyslog can
# read), setgid so new *.log inherit the syslog group; no access for others.
mkdir -p "$PICO_HOST_DIR"
chown -R "$APP_UID:$SYSLOG_GROUP" "$PICO_HOST_DIR"
chmod -R u+rwX,g+rX,o-rwx "$PICO_HOST_DIR"
chmod g+s "$PICO_HOST_DIR"
note "set $PICO_HOST_DIR owner=$APP_UID group=$SYSLOG_GROUP (app writes, rsyslog reads)"

# DURABLE READABILITY (the fix for "only some *.log mirror"): setgid above only
# makes new files inherit the syslog GROUP — it does NOT set their read bit. A
# service whose logger lazily creates its file AFTER this script runs (first log
# line) with a restrictive umask is born g-r, so the priv-dropped rsyslog can't
# tail it and that one file silently never mirrors. A DEFAULT ACL makes the
# kernel ignore the writer's umask for the syslog group, so EVERY current and
# future *.log is readable by rsyslog. Falls back to chmod-only (with a warning)
# if the `acl` package / setfacl is unavailable.
if command -v setfacl >/dev/null 2>&1; then
    setfacl -R    -m g:"$SYSLOG_GROUP":rX "$PICO_HOST_DIR"   # existing dir + files
    setfacl    -d -m g:"$SYSLOG_GROUP":rX "$PICO_HOST_DIR"   # default: inherited by NEW files
    note "applied default ACL: '$SYSLOG_GROUP' reads existing + future *.log (umask-proof)"
else
    note "WARNING: setfacl not found (install the 'acl' package). Existing *.log are"
    note "         readable, but a service that creates a NEW log after this run with a"
    note "         restrictive umask may not mirror. Re-run after such files appear, or"
    note "         install 'acl' for a permanent fix."
fi

# Dest: created if missing; group-writable by syslog so the priv-dropped rsyslog
# can create the mirror files. A root-owned dir would silently mirror nothing.
mkdir -p "$SYSLOG_DIR"
chgrp "$SYSLOG_GROUP" "$SYSLOG_DIR"
chmod g+rwx "$SYSLOG_DIR"
chmod g+s   "$SYSLOG_DIR"
note "ensured $SYSLOG_DIR exists, group-writable by '$SYSLOG_GROUP' (rsyslog priv-drop target)"

# 3. Install the drop-in ------------------------------------------------------
install -m 0644 "$DROPIN_SRC" "$DROPIN_DST"
note "installed $DROPIN_DST"

# 4. Validate, then restart (abort WITHOUT restart on invalid config) ---------
if ! rsyslogd -N1 -f /etc/rsyslog.conf >/tmp/rsyslog-validate.$$ 2>&1; then
    cat /tmp/rsyslog-validate.$$ >&2; rm -f /tmp/rsyslog-validate.$$
    rm -f "$DROPIN_DST"
    die "rsyslogd -N1 validation failed — drop-in removed, rsyslog NOT restarted"
fi
rm -f /tmp/rsyslog-validate.$$
systemctl restart rsyslog
note "validated and restarted rsyslog — mirror active: $PICO_HOST_DIR/*.log -> $SYSLOG_DIR/"

# 5. Readability assertion — prove the priv-dropped rsyslog can actually READ
#    every source *.log. This catches the silent-subset bug at install time: if
#    a writer forces mode 0600 (defeats even the ACL mask), warn loudly and name
#    the offenders instead of letting them never mirror. `sudo -u syslog test -r`
#    checks access AS the exact identity rsyslog drops to.
shopt -s nullglob
unreadable=()
for f in "$PICO_HOST_DIR"/*.log; do
    sudo -u "$SYSLOG_USER" test -r "$f" 2>/dev/null || unreadable+=("$f")
done
if [ "${#unreadable[@]}" -gt 0 ]; then
    note "WARNING: '$SYSLOG_USER' CANNOT read these files — they will NOT mirror:" >&2
    printf '  - %s\n' "${unreadable[@]}" >&2
    note "  their writer likely forces mode 0600 (defeats the ACL mask); fix that"
    note "  service's log file mode/umask to be group-readable, then re-run." >&2
else
    note "readability OK — all $PICO_HOST_DIR/*.log are readable by '$SYSLOG_USER'"
fi

note "verify with: sudo $BUNDLE_DIR/verify-syslog.sh"
