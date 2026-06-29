#!/usr/bin/env bash
# US4: exactly-once across an rsyslog restart (no loss, no duplicate).
set -u
cd "$(dirname "$0")"
. ./harness.sh
harness_start
trap harness_stop EXIT

a="restartA-$$-$RANDOM"
harness_append "cloudpi-node.log" "{\"correlation_id\":\"$a\"}"
harness_wait_for "cloudpi-node.log" "$a" 5 || fail "US4 pre-restart line not mirrored"

harness_restart   # same workDirectory => per-file state resumes

b="restartB-$$-$RANDOM"
harness_append "cloudpi-node.log" "{\"correlation_id\":\"$b\"}"
harness_wait_for "cloudpi-node.log" "$b" 5 || fail "US4 post-restart line not mirrored (state did not resume)"

# No duplication of the pre-restart line.
ca="$(harness_count cloudpi-node.log "$a")"
[ "$ca" -eq 1 ] || fail "US4 pre-restart line duplicated (count=$ca, expected 1)"
pass "US4 restart exactly-once (no loss, no duplicate)"
echo "PASS test_us4_restart"
