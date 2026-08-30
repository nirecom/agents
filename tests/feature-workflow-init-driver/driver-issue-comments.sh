#!/bin/bash
# tests/feature-workflow-init-driver/driver-issue-comments.sh
# Tests: bin/workflow/workflow-init-driver, bin/workflow/lib/workflow-init/phases/fetch-issues.js, bin/workflow/lib/workflow-init/phases/write-context.js, bin/workflow/lib/workflow-init/issue-comments.js, bin/workflow/lib/workflow-init/checkpoint.js
# Tags: workflow-init, driver, issue-comments, fetch-issues, write-context, sentinel-strip, prompt-injection, scope:issue-specific

# C1-C19, K1-K7, L1-L6 (#2063) — issue COMMENTS through the driver, plus the
# CHECKPOINT= path/write contract and the labels: injection surface. Dispatch only;
# cases live in driver-issue-comments/ per rules/coding/file-split.md Pattern A.
# Injection seams: ./HARNESS-CONTRACT.md — TL3 gap: ./driver-issue-comments/_lib.sh

set -uo pipefail

SPLIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/driver-issue-comments"

SPLIT_GROUPS=(
    "fetch-render.sh"
    "injection.sh"
    "reopen-cache.sh"
    "reopen-authz.sh"
    "corrupt-shapes.sh"
    "boundaries.sh"
    "checkpoint-path-write.sh"
    "labels-injection.sh"
)

TOTAL_PASS=0
TOTAL_FAIL=0

for group in "${SPLIT_GROUPS[@]}"; do
    script="$SPLIT_DIR/$group"
    if [ ! -f "$script" ]; then
        echo "FAIL: split group missing: $script"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        continue
    fi

    echo ""
    echo "--- driver-issue-comments/$group ---"
    out_file="$(mktemp)"
    bash "$script" 2>&1 | tee "$out_file"
    rc=${PIPESTATUS[0]}

    results_line="$(grep -E '^Results: [0-9]+ passed, [0-9]+ failed' "$out_file" | tail -1)"
    if [ -n "$results_line" ]; then
        g_pass="$(printf '%s' "$results_line" | sed -E 's/^Results: ([0-9]+) passed.*/\1/')"
        g_fail="$(printf '%s' "$results_line" | sed -E 's/.* ([0-9]+) failed.*/\1/')"
        TOTAL_PASS=$((TOTAL_PASS + g_pass))
        TOTAL_FAIL=$((TOTAL_FAIL + g_fail))
    else
        echo "WARN: driver-issue-comments/$group emitted no Results line (exit=$rc); counting as 1 failure"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
    fi
    rm -f "$out_file"
done

# The parent aggregate reads the LAST `Results:` line, so this roll-up prints last.
echo ""
echo "Results: $TOTAL_PASS passed, $TOTAL_FAIL failed"
[ "$TOTAL_FAIL" -eq 0 ] && exit 0 || exit 1
