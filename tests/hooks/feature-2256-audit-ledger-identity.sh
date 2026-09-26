#!/usr/bin/env bash
# tests/hooks/feature-2256-audit-ledger-identity.sh
# Tests: hooks/lib/audit-ledger.js, hooks/lib/audit-triggers.js, hooks/lib/supervisor-state-writer/lock.js, hooks/lib/supervisor-state-writer/audit.js, hooks/lib/supervisor-state-writer/alert.js, hooks/lib/supervisor-state-writer/append.js, hooks/lib/supervisor-state-schema.js, bin/supervisor-write-audit-verdict
# Tags: supervisor, audit-ledger, audit-run-identity, state-lock, compare-and-set, TL2, scope:issue-specific, pwsh-not-required

# TL3 gap (what this test does NOT catch):
# - a real Stop hook arming a run while a real supervisor-audit subagent finalizes it
# - OS-level lock-directory behaviour under an antivirus or indexer holding it open
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

# #2256 S2: ledger and run identity are one schema written under one read-modify-write
# lock. Cases live in tests/hooks/feature-2256-audit-ledger-identity/ and each runs standalone.
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SECTION_DIR="$AGENTS_ROOT/tests/hooks/feature-2256-audit-ledger-identity"
RWT="$AGENTS_ROOT/bin/run-with-timeout.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1${2:+ — $2}"; FAIL=$((FAIL + 1)); }

# shellcheck source=./lib/section-runner.sh
. "$AGENTS_ROOT/tests/lib/section-runner.sh"

if ! command -v node >/dev/null 2>&1; then
    fail "node-missing" "node is required to exercise the hooks/lib modules under test"
    echo ""
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi

run_section "identity-and-cas.sh" 120
run_section "ledger-retention-subchecks.sh" 120
run_section "lock-ownership.sh" 120
run_section "lock-entrypoints.sh" 120

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && { echo "All tests passed."; exit 0; }
exit 1
