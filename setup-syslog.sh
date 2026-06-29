#!/usr/bin/env bash
# ============================================================================
# setup-syslog.sh — install the CloudPi rsyslog file-tail mirror (Feature 116)
#
# Idempotent host-side installer. Assumes rsyslog is ALREADY installed and
# active (>= 8.25); it NEVER installs rsyslog. It:
#   1. asserts rsyslog active + >= 8.25 and /var/log/cloudpi exists
#   2. makes the bind-mount source dir readable by the host `syslog` user
#      (the UID-1000 fix: group ownership + group-read + setgid)
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
PICO_HOST_DIR="${PICO_HOST_DIR:-$BUNDLE_DIR/logs/pico}"   # host side of ./logs/pico:/var/log/pico
SYSLOG_DIR="${SYSLOG_DIR:-/var/log/cloudpi}"
SYSLOG_USER="${SYSLOG_USER:-syslog}"   # rsyslog priv-drop user (reads source)
SYSLOG_GROUP="${SYSLOG_GROUP:-syslog}" # rsyslog priv-drop group (writes dest)

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

# 2. Preconditions + permissions for the priv-dropped rsyslog ----------------
# rsyslog drops privileges to $SYSLOG_USER/$SYSLOG_GROUP ($PrivDropToUser), so it
# READS the source and WRITES the dest as that user — both must be accessible.
[ -d "$SYSLOG_DIR" ] || die "$SYSLOG_DIR does not exist — it is assumed pre-created (this script does not create it)"
getent group  "$SYSLOG_GROUP" >/dev/null || die "host group '$SYSLOG_GROUP' not found (rsyslog priv-drop group)"
getent passwd "$SYSLOG_USER"  >/dev/null || die "host user '$SYSLOG_USER' not found (rsyslog priv-drop user)"

# Source (UID-1000 fix): readable by the syslog group; setgid so new *.log inherit it.
mkdir -p "$PICO_HOST_DIR"
chgrp -R "$SYSLOG_GROUP" "$PICO_HOST_DIR"
chmod -R g+rX "$PICO_HOST_DIR"
chmod g+s "$PICO_HOST_DIR"
note "made $PICO_HOST_DIR group-readable by '$SYSLOG_GROUP' (setgid set)"

# Dest: WRITABLE by the syslog group so the priv-dropped rsyslog can create the
# mirror files. Without this, a root-owned /var/log/cloudpi silently mirrors nothing.
chgrp "$SYSLOG_GROUP" "$SYSLOG_DIR"
chmod g+rwx "$SYSLOG_DIR"
chmod g+s   "$SYSLOG_DIR"
note "made $SYSLOG_DIR group-writable by '$SYSLOG_GROUP' (rsyslog priv-drop target)"

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
note "verify with: sudo $BUNDLE_DIR/verify-syslog.sh"
