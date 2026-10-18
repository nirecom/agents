# shellcheck shell=bash
# #2650 G1-G5: the shared gate predicate planGateState (driver: gate-driver.js).
# Sourced by ../feature-2650-confirm-continuation.sh (needs ccn_run, case_begin, case_end).
# WORKFLOW_STATE_DIR / WORKFLOW_PLANS_DIR are pinned by the parent:
# isolation: inherits-from ../feature-2650-confirm-continuation.sh

echo "=== #2650 planGateState (G1-G5) ==="
case_begin "g1-plan-gate-state-matches-gate-cli" "hooks/lib/confirm-gate/plan-gate.js"
ccn_run gate-driver.js G1
case_end

case_begin "g2-intent-off-is-on-without-probe" "hooks/lib/confirm-gate/plan-gate.js"
ccn_run gate-driver.js G2
case_end

case_begin "g3-probe-failure-is-error-for-every-caller" "bin/workflow/lib/next-step/gate-mode.js"
ccn_run gate-driver.js G3
case_end

case_begin "g4-off-with-trailing-blank-is-on" "hooks/lib/confirm-gate/plan-gate.js"
ccn_run gate-driver.js G4
case_end

case_begin "g5-nonpositive-timeout-is-error-without-probe" "hooks/lib/confirm-gate/plan-gate.js"
ccn_run gate-driver.js G5
case_end
