#!/bin/bash
# Tests: hooks/scan-outbound.js
# Tags: hook, scan, github, security, scope:issue-specific, pwsh-not-required
# Part B — scan-outbound.js integration (sandboxed hook + gh stub).
# Sourced-and-run standalone: builds its own PASS/FAIL via helpers.sh.
# Dispatch-only: logic lives in part-b/sandbox.sh (build_sandbox + hook
# invocation helpers) and part-b/cases-1.sh, part-b/cases-2.sh (test cases).

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./helpers.sh
. "$HERE/helpers.sh"

echo "=== Part B: scan-outbound.js target-visibility integration ==="

if [ ! -f "$HOOK_SRC" ]; then
    skip "Part B — hooks/scan-outbound.js not present"
    echo "Part B: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
    exit 0
fi

# shellcheck source=./part-b/sandbox.sh
. "$HERE/part-b/sandbox.sh"
# shellcheck source=./part-b/cases-1.sh
. "$HERE/part-b/cases-1.sh"
# shellcheck source=./part-b/cases-2.sh
. "$HERE/part-b/cases-2.sh"

echo ""
echo "Part B: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
