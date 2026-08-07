#!/usr/bin/env bash
# tests/feature-1794-stop-guard-exemptions.sh
# Tests: hooks/stop-premature-stop-guard.js, hooks/supervisor-guard.js, hooks/lib/stop-exemption-policy.js, hooks/lib/session-markers.js, hooks/lib/sentinel-patterns.js, hooks/workflow-state/lifecycle.js, hooks/workflow-state/state-io/zombie-cleanup.js, hooks/workflow-mark/enforce-override-handlers.js, hooks/workflow-mark/enforce-override-handlers/background-work.js, bin/workflow/lib/next-step/verdict.js, settings.json
# Tags: stop-hook, supervisor-guard, exemption, session-marker, scope:issue-specific, pwsh-not-required, TL1, TL2
#
# Issues #1794 / #1665 — the Stop-guard exemption layer:
#   #1794  isWorkflowStarted() + the C4_EXEMPTIONS / buildExemptionDeps /
#          firstExemption restructuring, and the C2 pre-workflow-init gate
#   #1665  the background-work primitive (TTL 4h, fail-CLOSED)
# X/T/Z/B cases are TL2 (real spawned hook, next-step and workflow-mark
# processes against seeded temp state dirs); M cases are TL1 plus a TL2
# cross-check of the declarative EXEMPTION_MATRIX against real behaviour.
# S cases pin the settings.json permission wiring (ask on the START/declare
# sentinels, allow on the END ones) and P cases are the table-driven regex
# matrix for the background-work sentinel patterns — both TL1.
# Security/robustness rows: B9 (hostile session ids never escape the workflow
# dir), B10/B11 (TTL boundary under a frozen clock, and malformed markers fail
# CLOSED), B12 (exact 4h TTL), B13 (malformed/injected START writes no marker
# and no .tmp residue), B15 (marker-write I/O fault injection),
# Z1 (sweep containment + resilience).
#
# L3 gap (what this test does NOT catch):
# - Real Claude Code Stop hook invocation wiring (the settings.json Stop entries
#   actually firing C2 and C4, and in which order)
# - Real PostToolUse wiring for the sentinel commands that write the markers
# - Live stop_hook_active propagation across a real auto-resume round trip
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"
CASE_DIR="$AGENTS_DIR/tests/feature-1794-stop-guard-exemptions"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

# shellcheck source=/dev/null
. "$CASE_DIR/helpers.sh"
# shellcheck source=/dev/null
. "$CASE_DIR/x-lifecycle.sh"
# shellcheck source=/dev/null
. "$CASE_DIR/b-background-work.sh"
# shellcheck source=/dev/null
. "$CASE_DIR/m-policy-matrix.sh"
# shellcheck source=/dev/null
. "$CASE_DIR/s-sentinel-wiring.sh"
# shellcheck source=/dev/null
. "$CASE_DIR/f-fault-injection.sh"

# X1-X7 + T17/T18 — isWorkflowStarted and the C4/C2 restructuring
run_X1
run_X2
run_X3
run_X4
run_X5
run_X6
run_X7
run_T17
run_T18
run_Z1

# B1-B13 — background-work primitive (#1665)
run_B1
run_B2
run_B3
run_B4
run_B5
run_B6
run_B7
run_B8
run_B9
run_B10
run_B11
run_B12
run_B13

# B15 — marker-write I/O fault injection
run_B15

# M1-M3 — EXEMPTION_MATRIX cross-checks
run_M1a
run_M1b
run_M1c
run_M1d
run_M2
run_M3a
run_M3b
run_M3c

# S1-S2 + P1-P2 — settings.json permission wiring and the sentinel pattern table
run_S1
run_S2
run_P1
run_P2

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
