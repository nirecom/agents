#!/usr/bin/env bash
# tests/feature-2256-tr5-user-verified-hold.sh
# Tests: hooks/workflow-gate.js, hooks/lib/audit-ledger.js, bin/supervisor-record-block-override
# Tags: supervisor, tr5, user-verified, hold, freshness, TL2, scope:issue-specific

# #2256 S5-b / S5-c / S5-d — the USER_VERIFIED sentinel's two-stage TR5 gate.
# Stage 1 holds on an unresolved BLOCK keyed by freshness_key; stage 2 decides which
# sub-checks a re-audit may skip. The human override sits between them and is
# invalidated by any movement on either axis.

set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECTION_DIR="$AGENTS_ROOT/tests/feature-2256-tr5-user-verified-hold"
RWT="$AGENTS_ROOT/bin/run-with-timeout.sh"
PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1${2:+ — $2}"; FAIL=$((FAIL + 1)); }

# shellcheck source=./lib/section-runner.sh
. "$AGENTS_ROOT/tests/lib/section-runner.sh"

if ! command -v node >/dev/null 2>&1; then
    fail "node-missing" "node is required — this suite drives the real gate hook"
    echo ""
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi
if ! command -v git >/dev/null 2>&1; then
    fail "git-missing" "git is required — the fixture is a real repository"
    echo ""
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi

run_section "stage1-hold.sh" 300
run_section "override-record.sh" 300
run_section "stage2-freshness.sh" 300
run_section "null-freshness-short-circuit.sh" 300

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -eq 0 ]; then
    echo "All tests passed."
    exit 0
fi
exit 1
