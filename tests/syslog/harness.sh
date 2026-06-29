#!/usr/bin/env bash
# ============================================================================
# Integration test harness for the CloudPi syslog mirror (Feature 116).
# Runs a REAL, user-space rsyslog (no root, no systemctl) against the SHIPPED
# host-config/30-cloudpi.conf, with its paths rewritten to temp dirs so the
# test exercises the real config logic.
#
# Source this file from a test:  . ./harness.sh
# Requires: rsyslogd >= 8.25 on PATH.
# ============================================================================
set -u

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DROPIN_DEFAULT="$HARNESS_DIR/../../host-config/30-cloudpi.conf"

HARNESS_SRC=""      # temp source dir (stands in for /var/log/pico)
HARNESS_DEST=""     # temp dest dir   (stands in for /var/log/cloudpi)
_H_WORK=""          # rsyslog workDirectory (per-file state lives here)
_H_CONF=""
_H_PID=""
_H_BGPID=""         # background rsyslogd pid (empty until started)

harness_require_rsyslog() {
    command -v rsyslogd >/dev/null 2>&1 || { echo "SKIP: rsyslogd not on PATH"; exit 77; }
}

# harness_start [dropin_path]
# Rewrites the drop-in's /var/log/pico -> $HARNESS_SRC and /var/log/cloudpi ->
# $HARNESS_DEST, prepends a workDirectory global, and starts rsyslogd in the bg.
harness_start() {
    harness_require_rsyslog
    local dropin="${1:-$DROPIN_DEFAULT}"
    [ -f "$dropin" ] || { echo "FAIL: drop-in not found: $dropin"; exit 1; }

    local base; base="$(mktemp -d "${TMPDIR:-/tmp}/cloudpi-syslog.XXXXXX")"
    HARNESS_SRC="$base/pico";    mkdir -p "$HARNESS_SRC"
    HARNESS_DEST="$base/cloudpi"; mkdir -p "$HARNESS_DEST"
    _H_WORK="$base/work";        mkdir -p "$_H_WORK"
    _H_CONF="$base/rsyslog.conf"
    _H_PID="$base/rsyslog.pid"

    {
        echo "global(workDirectory=\"$_H_WORK\")"
        # Force polling so the test is deterministic on any filesystem (matches
        # the bind-mount fallback we ship). Use sed to swap the module mode line
        # and the two real paths to our temp dirs.
        sed -e 's|mode="inotify"|mode="polling" PollingInterval="1"|' \
            -e "s|/var/log/pico|$HARNESS_SRC|g" \
            -e "s|/var/log/cloudpi|$HARNESS_DEST|g" \
            "$dropin"
    } > "$_H_CONF"

    # Validate. Distinguish a real config error from an environment that won't
    # let an unprivileged rsyslogd read a temp config (AppArmor confinement /
    # no root) — the latter is a SKIP, not a FAIL.
    local nout; nout="$(rsyslogd -N1 -f "$_H_CONF" 2>&1)"
    if [ $? -ne 0 ]; then
        if printf '%s' "$nout" | grep -qiE 'permission denied|-2104|could not open config'; then
            echo "SKIP: rsyslogd cannot read a temp config here (AppArmor/no-root). Run on a host where rsyslog can load /etc/rsyslog.d, or in CI/container as root."
            harness_stop; exit 77
        fi
        echo "FAIL: rsyslogd -N1 rejected config"; printf '%s\n' "$nout"; cat "$_H_CONF"; exit 1
    fi
    rsyslogd -n -f "$_H_CONF" -i "$_H_PID" >"$base/rsyslogd.log" 2>&1 &
    _H_BGPID=$!
    sleep 1   # let imfile discover existing files / settle
}

harness_append() {  # harness_append <basename> <line>
    printf '%s\n' "$2" >> "$HARNESS_SRC/$1"
}

# harness_wait_for <basename> <fixed-string> [timeout_s]  -> 0 if found
harness_wait_for() {
    local f="$HARNESS_DEST/$1" pat="$2" t="${3:-5}" i=0
    while [ "$i" -lt "$((t*2))" ]; do
        [ -f "$f" ] && grep -qF -- "$pat" "$f" && return 0
        sleep 0.5; i=$((i+1))
    done
    return 1
}

harness_count() {  # harness_count <basename> <fixed-string>  -> prints count in DEST
    local f="$HARNESS_DEST/$1"
    [ -f "$f" ] && grep -cF -- "$2" "$f" || echo 0
}

harness_restart() {  # kill + restart rsyslogd, same workDirectory => state resumes
    [ -n "${_H_BGPID:-}" ] && kill "$_H_BGPID" 2>/dev/null
    [ -n "${_H_BGPID:-}" ] && wait "$_H_BGPID" 2>/dev/null
    rsyslogd -n -f "$_H_CONF" -i "$_H_PID" >>"$(dirname "$_H_CONF")/rsyslogd.log" 2>&1 &
    _H_BGPID=$!
    sleep 1
}

harness_stop() {
    [ -n "${_H_BGPID:-}" ] && kill "$_H_BGPID" 2>/dev/null
    [ -n "${_H_BGPID:-}" ] && wait "$_H_BGPID" 2>/dev/null
    [ -n "${HARNESS_SRC:-}" ] && rm -rf "$(dirname "$HARNESS_SRC")"
}

# Convenience assertions ------------------------------------------------------
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; harness_stop; exit 1; }
