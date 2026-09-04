#!/usr/bin/env bash
# tests/feature-2169-workflow-not-started-notify-gate.sh
# Tests: hooks/user-prompt-submit-mechanism-check.js, hooks/lib/stop-exemption-policy.js, hooks/postuse-step-in-flight-mark.js, hooks/workflow-state/lifecycle.js, hooks/lib/mechanism-failure.js
# Tags: stall-detection, user-prompt-submit, prompt-notify, pre-workflow-init, wi-10-lookahead, regression-2169, scope:issue-specific, pwsh-not-required, TL1, TL2

# Issue #2169 — dispatching a Skill/Agent/Task in a session that never ran /workflow-init marks `research` in-flight via the WI-10 lookahead heuristic (hooks/postuse-step-in-flight-mark.js). Once the 4h TTL expires without settlement, hooks/user-prompt-submit-mechanism-check.js had no pre-workflow-init exemption (unlike hooks/stop-premature-stop-guard.js, which already has one) — so a mechanism-failure notification got injected into every subsequent prompt forever, and the reportMechanismFailureOnce ledger permanently swallowed the first genuine report once the session later ran /workflow-init for real.

# TL3 gap: real Claude Code UserPromptSubmit hook wiring and a real overnight wall-clock gap are not exercised here — the same gap feature-1979-stall-regression.sh already carries for this hook host. Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"
CASE_DIR="$AGENTS_DIR/tests/feature-2169-workflow-not-started-notify-gate"

unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

AUTOMARK_HOOK="$AGENTS_DIR/hooks/postuse-step-in-flight-mark.js"
UPS_HOOK="$AGENTS_DIR/hooks/user-prompt-submit-mechanism-check.js"
STATEIO_NODE="$_AGENTS_DIR_NODE/hooks/workflow-state/state-io.js"
LIFECYCLE_NODE="$_AGENTS_DIR_NODE/hooks/workflow-state/lifecycle.js"
MECHFAIL_NODE="$_AGENTS_DIR_NODE/hooks/lib/mechanism-failure.js"
TTL_MS=$((4 * 60 * 60 * 1000))

# shellcheck source=/dev/null
. "$CASE_DIR/helpers.sh"
# shellcheck source=/dev/null
. "$CASE_DIR/p-basic.sh"
# shellcheck source=/dev/null
. "$CASE_DIR/p-wiring.sh"
# shellcheck source=/dev/null
. "$CASE_DIR/p-breadth.sh"

# Sourced-fragment sanity gate — see tests/feature-1794-stop-guard-exemptions.sh
# for the rationale (a fragment that dies half-way through leaves some
# functions defined and the rest missing, which `set -u` alone won't catch).
require_defined() {
    local missing="" fn
    for fn in "$@"; do
        declare -f "$fn" >/dev/null 2>&1 || missing="$missing $fn"
    done
    if [ -n "$missing" ]; then
        echo "FATAL: partial source — these functions are not defined:$missing" >&2
        echo "       (check the '. \$CASE_DIR/...' lines above and each fragment's syntax)" >&2
        echo ""
        echo "Results: 0 passed, 1 failed, 0 skipped"
        exit 1
    fi
}
require_defined \
    pass fail skip \
    make_tmp node_path dispatch_skill backdate_research backdate_step \
    mark_step_in_progress seed_workflow_off seed_state_corrupt strip_timestamp \
    complete_workflow_init run_ups research_status stalled_kinds_for \
    seed_malicious_step mark_step_with_origin \
    run_P1 run_P1b run_P2 run_P3 run_P4 run_P5 run_P6 run_P8 run_P9 \
    run_P10 run_P11 run_P12 run_P13 run_P14

# P1-P3 — core pre-workflow-init suppression contract
run_P1
run_P1b
run_P2
run_P3

# P4-P5/P11-P12 — cross-module wiring, fail-open/fail-safe, and same-step
# origin-ordering, against the real hook subprocess
run_P4
run_P5
run_P11
run_P12

# P6/P8/P9/P10 — breadth of finding kinds, gate precision vs C4, multi-step,
# and the isKnownStep() attack-scenario proof
run_P6
run_P8
run_P9
run_P10

# P13/P14 — mechanism-failure.js's own downstream-sink sanitization (known
# gap, xfail-pinned) and isKnownStep()'s direct per-branch verdicts
run_P13
run_P14

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
