#!/usr/bin/env bash
# tests/hooks/feature-1665-run-outcome.sh
# Tests: hooks/workflow-run-tests/outcome.js, hooks/workflow-run-tests.js, hooks/workflow-run-tests/exec-model.js, hooks/enforce-worktree/worker-dispatch-write.js, hooks/workflow-state/state-io/events.js, hooks/workflow-state/record-step-verdict.js
# Tags: workflow, run-tests, run-outcome, classifier, parser, hook, worker-dispatch, tombstone, unrunnable, legacy-shape, exit-77, escape-hatch, TL1, TL2, scope:issue-specific
# WHY: pins the run_outcome axis (#1665) and its contract/exit-code rules; per-group WHY lives
# in the sibling feature-1665-run-outcome/a-…n- files, shared helpers in common.sh (file-split A).
# TL3 gap: real PostToolUse stdin shape and real run-all stdout are synthesised here; checked at
# WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration.

set -u
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# isolation (#2512): pin state and plans dirs once for this file
_ISOLATION_TMP_ROOT="$(mktemp -d)"; readonly _ISOLATION_TMP_ROOT
mkdir -p "$_ISOLATION_TMP_ROOT/workflow-state" "$_ISOLATION_TMP_ROOT/plans"
export WORKFLOW_STATE_DIR="$_ISOLATION_TMP_ROOT/workflow-state" WORKFLOW_PLANS_DIR="$_ISOLATION_TMP_ROOT/plans"
trap 'rm -rf "$_ISOLATION_TMP_ROOT"' EXIT

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-1665-run-outcome"

# shellcheck source=./feature-1665-run-outcome/common.sh
. "$SCRIPT_DIR/common.sh"

# shellcheck source=./feature-1665-run-outcome/a-outcome-table.sh
. "$SCRIPT_DIR/a-outcome-table.sh"
# shellcheck source=./feature-1665-run-outcome/b-direct-run-failure.sh
. "$SCRIPT_DIR/b-direct-run-failure.sh"
# shellcheck source=./feature-1665-run-outcome/c-crash-no-contract.sh
. "$SCRIPT_DIR/c-crash-no-contract.sh"
# shellcheck source=./feature-1665-run-outcome/d-worker-route.sh
. "$SCRIPT_DIR/d-worker-route.sh"
# shellcheck source=./feature-1665-run-outcome/e-write-tests-guard.sh
. "$SCRIPT_DIR/e-write-tests-guard.sh"
# shellcheck source=./feature-1665-run-outcome/f-log-tail-scope.sh
. "$SCRIPT_DIR/f-log-tail-scope.sh"
# shellcheck source=./feature-1665-run-outcome/g-outcome-tombstone.sh
. "$SCRIPT_DIR/g-outcome-tombstone.sh"
# shellcheck source=./feature-1665-run-outcome/h-dispatcher-basename-parity.sh
. "$SCRIPT_DIR/h-dispatcher-basename-parity.sh"
# shellcheck source=./feature-1665-run-outcome/i-identity-throw.sh
. "$SCRIPT_DIR/i-identity-throw.sh"
# shellcheck source=./feature-1665-run-outcome/j-worker-verdict-ssot.sh
. "$SCRIPT_DIR/j-worker-verdict-ssot.sh"
# shellcheck source=./feature-1665-run-outcome/k-unrunnable-contract.sh
. "$SCRIPT_DIR/k-unrunnable-contract.sh"
# shellcheck source=./feature-1665-run-outcome/l-legacy-and-exit77.sh
. "$SCRIPT_DIR/l-legacy-and-exit77.sh"
# shellcheck source=./feature-1665-run-outcome/m-unrunnable-accept-annotations.sh
. "$SCRIPT_DIR/m-unrunnable-accept-annotations.sh"
# shellcheck source=./feature-1665-run-outcome/n-accept-annotation-keys.sh
. "$SCRIPT_DIR/n-accept-annotation-keys.sh"

run_a_outcome_table_cases
run_b_direct_run_failure_cases
run_c_crash_no_contract_cases
run_d_worker_route_cases
run_e_write_tests_guard_cases
run_f_log_tail_scope_cases
run_g_outcome_tombstone_cases
run_h_dispatcher_basename_parity_cases
run_i_identity_throw_cases
run_j_worker_verdict_ssot_cases
run_k_unrunnable_contract_cases
run_l_legacy_and_exit77_cases
run_m_unrunnable_accept_annotations_cases
run_n_accept_annotation_keys_cases

echo ""
echo "=== Results ==="
echo "Total: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "All tests passed!"
