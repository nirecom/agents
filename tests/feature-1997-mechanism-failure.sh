#!/usr/bin/env bash
# tests/feature-1997-mechanism-failure.sh
# Tests: hooks/lib/mechanism-failure.js, hooks/lib/protected-basenames.js, hooks/workflow-state/state-io/zombie-cleanup.js, hooks/stop-premature-stop-guard.js
# Tags: mechanism-failure, stall-detection, supervisor-report, stall-reported, idempotency, ordering, security, path-traversal, regression-1997, scope:issue-specific, pwsh-not-required, TL1, TL2

# Issue #1997 — when the workflow MECHANISM itself failed (a step stuck
# in_progress forever, a state file that vanished or went corrupt) nothing
# reported it: the session simply went quiet and the failure left no trace for
# cross-session pattern detection. mechanism-failure.js is the detector plus a
# once-per-finding reporter.

# Three concerns are kept apart (CPR-SC), one fragment each:
#   m-detect.sh    M1-M5   detectStalledSteps — the pure read that classifies
#                          WHAT went wrong, including its no-finding verdict.
#   n-reporter.sh  M6-M12  reportMechanismFailureOnce — the side-effecting half:
#                          where the report LANDS (ledger + supervisor log + the
#                          real C4 consumer), per-finding idempotency, the
#                          never-throw contract, and report-before-record order.
#   o-security.sh  O1-O3   the session id as untrusted path input.

# TL3 gap (what this test does NOT catch):
# - Whether bin/supervisor-report actually lands the finding in the real
#   supervisor state file when invoked by Claude Code's own environment
# - Whether a real overnight session reaches this code path at all (that is the
#   UserPromptSubmit wiring, covered by tests/feature-1979-stall-regression.sh)
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

_FRAG="$AGENTS_DIR/tests/feature-1997-mechanism-failure"
# shellcheck source=/dev/null
. "$_FRAG/helpers.sh"
# shellcheck source=/dev/null
. "$_FRAG/m-detect.sh"
# shellcheck source=/dev/null
. "$_FRAG/n-reporter.sh"
# shellcheck source=/dev/null
. "$_FRAG/o-security.sh"

# A partially-sourced fragment leaves its functions undefined, and `set -u` only
# reports that to stderr while the suite still exits 0 — a suite that silently
# stopped testing. Name the gap loudly instead.
require_defined() {
    local missing=""
    for fn in "$@"; do
        command -v "$fn" >/dev/null 2>&1 || missing="$missing $fn"
    done
    if [ -n "$missing" ]; then
        echo "FAIL: suite bootstrap — fragments did not define:$missing"
        exit 1
    fi
}
require_defined make_tmp node_path seed_in_flight detect assert_detect \
    report_once report_once_pd reported_entries reported_keys sup_state_path run_c4 \
    run_M1 run_M2 run_M3 run_M4 run_M5 run_M6 run_M7 run_M8 run_M9 \
    run_M10 run_M11 run_M12 run_O1 run_O2 run_O2b run_O3

echo "=== #1997: mechanism-failure detection and once-per-finding reporting ==="

run_M1; run_M2; run_M3; run_M4; run_M5
run_M6; run_M7; run_M8; run_M9; run_M10; run_M11; run_M12
run_O1; run_O2; run_O2b; run_O3

echo ""
echo "Passed: $PASS  Failed: $FAIL  Skipped: $SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
