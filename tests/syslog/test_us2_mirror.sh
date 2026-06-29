#!/usr/bin/env bash
# US2: wildcard tail mirrors each *.log verbatim into the dest within ~1s.
# Asserts: line present in mirror, byte-for-byte identical, per-file routing.
set -u
cd "$(dirname "$0")"
. ./harness.sh

harness_start
trap harness_stop EXIT

nonce="us2-$$-$RANDOM"
line="{\"timestamp\":\"2026-06-29T12:00:00.000Z\",\"level\":\"INFO\",\"service\":\"cloudpi-node\",\"event_name\":\"TEST\",\"correlation_id\":\"$nonce\"}"

harness_append "cloudpi-node.log" "$line"
harness_wait_for "cloudpi-node.log" "$nonce" 5 || fail "US2 line not mirrored within 5s"
pass "US2 mirrored within ~1s"

# Verbatim check: the mirrored line must equal the source line exactly.
mirrored="$(grep -F "$nonce" "$HARNESS_DEST/cloudpi-node.log")"
[ "$mirrored" = "$line" ] || fail "US2 not verbatim:
  src=[$line]
  dst=[$mirrored]"
pass "US2 verbatim (byte-for-byte)"

# Per-file routing: a second source file mirrors to its OWN dest name only.
nonce2="us2b-$$-$RANDOM"
harness_append "cloudpi-flask.log" "{\"correlation_id\":\"$nonce2\"}"
harness_wait_for "cloudpi-flask.log" "$nonce2" 5 || fail "US2 second file not mirrored to its own name"
if grep -qF "$nonce2" "$HARNESS_DEST/cloudpi-node.log" 2>/dev/null; then
    fail "US2 cross-file leak: flask line appeared in node mirror"
fi
pass "US2 per-file routing (no cross-file merge)"

echo "PASS test_us2_mirror"
