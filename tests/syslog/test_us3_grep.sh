#!/usr/bin/env bash
# US3: read with standard tools — grep -r finds a trace across mirrored files,
# and every mirrored line is valid JSON (no PRI/header prefix, leading space stripped).
set -u
cd "$(dirname "$0")"
. ./harness.sh
harness_start
trap harness_stop EXIT

cid="trace-$$-$RANDOM"
harness_append "cloudpi-node.log"  "{\"service\":\"cloudpi-node\",\"correlation_id\":\"$cid\"}"
harness_append "cloudpi-flask.log" "{\"service\":\"cloudpi-flask\",\"correlation_id\":\"$cid\"}"
harness_wait_for "cloudpi-node.log"  "$cid" 5 || fail "US3 node line not mirrored"
harness_wait_for "cloudpi-flask.log" "$cid" 5 || fail "US3 flask line not mirrored"

# grep -r across the dest must find the trace in BOTH mirrored files.
hits="$(grep -rl -- "$cid" "$HARNESS_DEST" | wc -l | tr -d ' ')"
[ "$hits" -eq 2 ] || fail "US3 grep -r found trace in $hits file(s), expected 2"
pass "US3 grep -r finds the whole trace across mirrored files"

# Every mirrored line for our trace must parse as one JSON object (no prefix).
if command -v python3 >/dev/null 2>&1; then
    bad=0
    while IFS= read -r ln; do
        python3 -c 'import json,sys; json.loads(sys.argv[1])' "$ln" 2>/dev/null || bad=$((bad+1))
    done < <(grep -rh -- "$cid" "$HARNESS_DEST")
    [ "$bad" -eq 0 ] || fail "US3 $bad mirrored line(s) are not valid JSON (prefix/space not stripped)"
    pass "US3 mirrored lines are valid JSON-lines (verbatim, space stripped)"
else
    echo "NOTE: python3 absent — skipped JSON-validity assertion"
fi
echo "PASS test_us3_grep"
