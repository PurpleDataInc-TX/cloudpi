#!/usr/bin/env bash
# US4: rotation coordination — rotated *.log.N is NOT re-ingested; fresh *.log
# is rediscovered and its new lines mirrored.
set -u
cd "$(dirname "$0")"
. ./harness.sh
harness_start
trap harness_stop EXIT

old="rotOld-$$-$RANDOM"
harness_append "cloudpi-node.log" "{\"correlation_id\":\"$old\"}"
harness_wait_for "cloudpi-node.log" "$old" 5 || fail "US4 pre-rotation line not mirrored"

# Rotate: cloudpi-node.log -> cloudpi-node.log.1, then a fresh cloudpi-node.log.
mv "$HARNESS_SRC/cloudpi-node.log" "$HARNESS_SRC/cloudpi-node.log.1"
: > "$HARNESS_SRC/cloudpi-node.log"

new="rotNew-$$-$RANDOM"
harness_append "cloudpi-node.log" "{\"correlation_id\":\"$new\"}"
harness_wait_for "cloudpi-node.log" "$new" 6 || fail "US4 fresh post-rotation log not tailed"
pass "US4 fresh *.log rediscovered after rotation"

# The rotated .log.1 (does not match *.log) must NOT be re-ingested -> old stays once.
cold="$(harness_count cloudpi-node.log "$old")"
[ "$cold" -eq 1 ] || fail "US4 rotated history re-ingested (old count=$cold, expected 1)"
pass "US4 rotated *.log.N not re-ingested"
echo "PASS test_us4_rotation"
