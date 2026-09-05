#!/usr/bin/env bash
# tests/bin-concern-ledger-harness-namespace-guard.sh
# Tests: tests/bin-concern-ledger-reducer/namespace-guard.sh, tests/bin-concern-ledger-reducer.sh
# Tags: concern-ledger, test-harness, namespace-guard, positive-control, TL2, scope:common, pwsh-not-required
set -uo pipefail

# WHY (CPR-WPH): the reducer dispatcher sources a real library into the shell that owns
# its pass/fail counters, then sources nine case files on top of it; either direction
# can shadow the other and the suite would still print "All tests passed". A guard that
# never fires is indistinguishable from no guard, so every check below is a
# positive/negative control PAIR.

# TL3 gap (not caught here): whether the guard stays quiet across a full nine-case run
# of the real dispatcher on a real host — the scenarios drive it through a stand-in
# harness, not through the suite.
# Closest-to-action mitigation: the reducer suite runs in tests/run-all.sh, so a guard
# that false-positives turns that suite red before merge.

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUITE_DIR="$AGENTS_ROOT/tests/bin-concern-ledger-reducer"
GUARD="$SUITE_DIR/namespace-guard.sh"
DISPATCHER="$AGENTS_ROOT/tests/bin-concern-ledger-reducer.sh"
LIB="$AGENTS_ROOT/bin/lib/concern-ledger.sh"
TIMEOUT="$AGENTS_ROOT/bin/run-with-timeout.sh"
CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bin-concern-ledger-harness-namespace-guard"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# Fixture isolation (rules/test/fixture-isolation.md): dual-pinned plans dir,
# no inherited session id, neutral CWD.
TMPDIR_BASE=$(mktemp -d)
trap 'cd / 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT
export CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
unset CLAUDE_SESSION_ID 2>/dev/null || true
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
export AGENTS_CONFIG_DIR="$AGENTS_ROOT"

WORK="$TMPDIR_BASE/work"
mkdir -p "$WORK"
cd "$TMPDIR_BASE" || exit 1

# Implementation presence. Reported as a FAILURE (never SKIP) so the suite exits
# non-zero until /write-code lands the guard.
for _f in "$GUARD" "$LIB"; do
    if [[ ! -f "$_f" ]]; then
        echo "SKIP-BLOCKED: ${_f#"$AGENTS_ROOT/"} not implemented yet"
        fail "implementation missing: ${_f#"$AGENTS_ROOT/"} (the cases below fail for this reason)"
    fi
done

# shellcheck source=./bin-concern-ledger-harness-namespace-guard/scenarios.sh
. "$CASE_DIR/scenarios.sh"
# shellcheck source=./bin-concern-ledger-harness-namespace-guard/owned-names.sh
. "$CASE_DIR/owned-names.sh"
# shellcheck source=./bin-concern-ledger-harness-namespace-guard/cases-direction-a.sh
. "$CASE_DIR/cases-direction-a.sh"
# shellcheck source=./bin-concern-ledger-harness-namespace-guard/cases-direction-b.sh
. "$CASE_DIR/cases-direction-b.sh"
# shellcheck source=./bin-concern-ledger-harness-namespace-guard/cases-guard-self.sh
. "$CASE_DIR/cases-guard-self.sh"
# shellcheck source=./bin-concern-ledger-harness-namespace-guard/cases-exclusions.sh
. "$CASE_DIR/cases-exclusions.sh"
# shellcheck source=./bin-concern-ledger-harness-namespace-guard/cases-real-order.sh
. "$CASE_DIR/cases-real-order.sh"
# shellcheck source=./bin-concern-ledger-harness-namespace-guard/cases-parser.sh
. "$CASE_DIR/cases-parser.sh"
# shellcheck source=./bin-concern-ledger-harness-namespace-guard/cases-wiring.sh
. "$CASE_DIR/cases-wiring.sh"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -eq 0 ]]; then
    echo "All tests passed."
    exit 0
fi
exit 1
