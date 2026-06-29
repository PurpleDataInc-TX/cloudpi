#!/usr/bin/env bash
# Run every test_*.sh in this dir. Exit non-zero if any FAILs.
# A test that SKIPs (exit 77, e.g. AppArmor/no-root) does not fail the run.
cd "$(dirname "$0")"
rc=0; ran=0; skipped=0
for t in test_*.sh; do
    [ -f "$t" ] || continue
    echo "=== $t ==="
    bash "$t"; code=$?
    if [ "$code" -eq 77 ]; then skipped=$((skipped+1));
    elif [ "$code" -ne 0 ]; then rc=1; ran=$((ran+1));
    else ran=$((ran+1)); fi
done
echo "----"
echo "ran=$ran skipped=$skipped result=$([ $rc -eq 0 ] && echo PASS || echo FAIL)"
exit $rc
