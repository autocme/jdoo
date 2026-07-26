#!/usr/bin/env bash
# Run every entrypoint.sh test file and summarise.
cd "$(dirname "$0")"
total=0; failed=0
for f in test_*.sh; do
    printf '\n\033[1;36m=== %s ===\033[0m\n' "$f"
    if bash "$f"; then :; else failed=$(( failed + 1 )); fi
    total=$(( total + 1 ))
done
printf '\n\033[1m%d file(s), %d failing\033[0m\n' "$total" "$failed"
[ "$failed" -eq 0 ]
