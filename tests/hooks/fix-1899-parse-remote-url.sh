#!/bin/bash
# tests/hooks/fix-1899-parse-remote-url.sh
# Tests: hooks/lib/parse-remote-url.js, hooks/lib/is-private-repo.js
# Tags: parse-remote-url, origin-resolution, table-driven, parser, regex, security, path-traversal, secret-redaction, TL1, scope:issue-specific
# Dispatch + aggregate entrypoint for the split suite (the flat file hit the
# 500-line HARD limit; rules/coding/file-split.md). Split groups = the
# SPLIT_GROUPS array below (SSOT); each also runs standalone. #1899 origin-only
# owner/repo contract and its CPR-ORTH twin live in hooks/lib/parse-remote-url.js
# + bin/github-issues/lib/origin-repo.sh. TL3 seam / live-remote gap: covered by
# tests/bin/fix-1899-origin-repo-resolver.sh + WORKFLOW_USER_VERIFIED preflight.

set -uo pipefail

# Outer timeout so a wedged node cannot stall the suite (rules/test.md).
if command -v timeout >/dev/null 2>&1 && [ -z "${_FIX1899_PRU_INNER:-}" ]; then
    _FIX1899_PRU_INNER=1 timeout 240 bash "$0" "$@"
    exit $?
fi

SPLIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fix-1899-parse-remote-url"

SPLIT_GROUPS=(
    "parse-origin.sh"
    "host-and-repo-id.sh"
    "module-contract.sh"
    "owner-repo-charset.sh"
    "redaction.sh"
    "authority.sh"
    "mutation-probe.sh"
    "detect-forge-type.sh"
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
    echo "═══ $group ═══"
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
echo "═════════════════════════════════════════"
echo "Aggregate Results: $TOTAL_PASS passed, $TOTAL_FAIL failed"
echo "Total: PASS=$TOTAL_PASS FAIL=$TOTAL_FAIL"
[ "$TOTAL_FAIL" -eq 0 ] && exit 0 || exit 1
