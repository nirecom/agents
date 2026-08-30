#!/usr/bin/env bash
# tests/feature-2063-prefill-comments-contract.sh
# Tests: skills/workflow-init/SKILL.md, skills/clarify-intent/SKILL.md, bin/workflow/render-issue-comments
# Tags: workflow-init, prompt-contract, static-grep, issue-comments, tl2, scope:issue-specific

# W1-W13 (#2063) — the WI-12 Path B call contract. Dispatch + aggregate only; cases
# live in feature-2063-prefill-comments-contract/ per rules/coding/file-split.md
# Pattern A. TL3 gap and shared helpers: ./feature-2063-prefill-comments-contract/_lib.sh

set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }

if [ -z "${_PFC_TIMEOUT_WRAPPED:-}" ]; then
    export _PFC_TIMEOUT_WRAPPED=1
    _PFC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    exec "$_PFC_ROOT/bin/run-with-timeout.sh" 240 bash "$0" "$@"
fi

SPLIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-2063-prefill-comments-contract"

SPLIT_GROUPS=(
    "skill-contract.sh"
    "prefill-assembly.sh"
    "hostile-paths.sh"
    "injection-prefill.sh"
    "clarify-intent-contract.sh"
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
    echo "--- feature-2063-prefill-comments-contract/$group ---"
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
        echo "WARN: $group emitted no Results line (exit=$rc); counting as 1 failure"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
    fi
    rm -f "$out_file"
done

echo ""
echo "Results: $TOTAL_PASS passed, $TOTAL_FAIL failed"
[ "$TOTAL_FAIL" -eq 0 ] && exit 0 || exit 1
