#!/usr/bin/env bash
# ============================================================================
# verify-syslog.sh — verify the CloudPi rsyslog file-tail mirror (Feature 116)
#
# VERIFY-ONLY: changes no configuration, installs nothing. Confirms:
#   1. rsyslog active + >= 8.25
#   2. every /var/log/pico/*.log is readable by the host `syslog` user
#   3. a freshly appended JSON line is mirrored VERBATIM into
#      /var/log/cloudpi/<same-name> within ~1s
# Prints `PASS <check>` / `FAIL <check> <reason>` and a final PASS/FAIL.
# Exit 0 only if every check passes.
#
# Run as root on the host:  sudo ./verify-syslog.sh
# ============================================================================
set -uo pipefail

PICO_DIR="${PICO_DIR:-/var/log/pico}"
SYSLOG_DIR="${SYSLOG_DIR:-/var/log/cloudpi}"
SYSLOG_USER="${SYSLOG_USER:-syslog}"
RC=0

ok()   { echo "PASS $*"; }
bad()  { echo "FAIL $*"; RC=1; }

# 1. rsyslog active + version --------------------------------------------------
if command -v rsyslogd >/dev/null 2>&1 && systemctl is-active --quiet rsyslog; then
    ver="$(rsyslogd -v 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)"
    major="${ver%%.*}"; minor="${ver#*.}"
    if [ "${major:-0}" -gt 8 ] || { [ "${major:-0}" -eq 8 ] && [ "${minor:-0}" -ge 25 ]; }; then
        ok "rsyslog active ($ver >= 8.25)"
    else
        bad "version rsyslog $ver < 8.25 (use per-file fallback)"
    fi
else
    bad "active rsyslog not running"
fi

# 2. readability by the syslog user -------------------------------------------
# Needs root to test-as-syslog without a password prompt; skip with a note otherwise.
shopt -s nullglob
logs=("$PICO_DIR"/*.log)
if [ "${#logs[@]}" -eq 0 ]; then
    bad "readability no *.log found in $PICO_DIR (is the bind mount up?)"
elif [ "$(id -u)" -ne 0 ]; then
    echo "NOTE readability skipped — run as root (sudo) to verify '$SYSLOG_USER' can read the files"
else
    unreadable=0
    for f in "${logs[@]}"; do
        sudo -u "$SYSLOG_USER" test -r "$f" 2>/dev/null || { unreadable=$((unreadable+1)); echo "    not readable by $SYSLOG_USER: $f"; }
    done
    [ "$unreadable" -eq 0 ] && ok "readability all *.log readable by '$SYSLOG_USER'" \
                            || bad "readability $unreadable file(s) not readable by '$SYSLOG_USER' (run setup-syslog.sh)"
fi

# 3. end-to-end append -> verbatim mirror -------------------------------------
# Use a DEDICATED probe file (matches *.log, gets mirrored) so we never inject
# synthetic lines into a real service log / its mirror.
target="$PICO_DIR/cloudpi-verify.log"
if [ -d "$PICO_DIR" ] && touch "$target" 2>/dev/null; then
    base="cloudpi-verify.log"
    nonce="verify-$$-${RANDOM}"
    line="{\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\",\"level\":\"INFO\",\"service\":\"verify\",\"event_name\":\"SYSLOG_VERIFY\",\"correlation_id\":\"$nonce\"}"
    printf '%s\n' "$line" >> "$target"
    dest="$SYSLOG_DIR/$base"
    found=""; i=0
    while [ "$i" -lt 10 ]; do
        if [ -f "$dest" ] && grep -qF "$nonce" "$dest"; then found=1; break; fi
        sleep 0.5; i=$((i+1))
    done
    if [ -n "$found" ]; then
        mirrored="$(grep -F "$nonce" "$dest" | tail -1)"
        [ "$mirrored" = "$line" ] && ok "mirror verbatim within ~$((i/2))s ($base)" \
                                  || bad "mirror not verbatim: src=[$line] dst=[$mirrored]"
    else
        bad "mirror line not found in $dest within 5s"
    fi
else
    bad "mirror could not write probe file $target (is the bind mount up and writable?)"
fi

echo "----"
[ "$RC" -eq 0 ] && echo "PASS" || echo "FAIL"
exit "$RC"
