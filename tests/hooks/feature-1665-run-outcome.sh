#!/usr/bin/env bash
# tests/feature-1665-run-outcome.sh
# Tests: hooks/workflow-run-tests/outcome.js, hooks/workflow-run-tests.js, hooks/workflow-run-tests/exec-model.js, hooks/enforce-worktree/worker-dispatch-write.js, hooks/workflow-state/state-io/events.js, hooks/workflow-state/record-step-verdict.js
# Tags: workflow, run-tests, run-outcome, classifier, parser, hook, worker-dispatch, tombstone, TL1, TL2, scope:issue-specific
#
# WHY (CPR-WPH): #1665 commit 2. `run_tests` today collapses to complete/pending,
# so the ONE fact the write_code resume cascade needs — "what did the run itself
# report?" — is never recorded. This suite pins the new outcome axis:
#   hooks/workflow-run-tests/outcome.js
#     RUN_OUTCOME_VALUES / isContractTrusted / parseWorkerVerdict / resolveRunOutcome
# and the two decisions that make it work in the primary path:
#   C1  contract-priority, exit-code-subordinate. tests/run-all.sh:65-66 emits a
#       VALID contract with FAIL>0 and THEN exits 1, so an outcome rule that reads
#       the exit code first silences the feature on the one route that matters.
#   R2  lifting the trust conditions above the non-zero fast path introduces real
#       file I/O (verifyEmitterIdentity). A local try/catch must keep the status-axis
#       pending demotion even when that I/O throws.
#
# EXPECTED RED: hooks/workflow-run-tests/outcome.js does not exist yet, and no
# markStep call writes `run_outcome`. Every case that depends on those FAILs by
# design. Cases resting only on primitives that landed in 2aebfc8a (#1902) —
# DISPATCHER_SCRIPTS, payloadHeader/LOG_TAIL_MARKER_RE, stdoutAttributed,
# workerVerdictVetoes — are GREEN today and are non-regression pins.
#
# Dispatcher: shared helpers live in feature-1665-run-outcome/common.sh; case
# groups live in the sibling a-…j- files (rules/coding/file-split.md pattern A).
#
# TL3 gap (what this test does NOT catch):
# - Whether Claude Code's PostToolUse event actually delivers this stdin shape on a
#   real Bash tool call (settings.json registration, tool_response.stdout capture).
#   Every case here pipes a hand-built payload into the hook process directly.
# - Whether a real `bash tests/run-all.sh` on the host produces byte-for-byte the
#   stdout assumed by b-direct-run-failure.sh; the stdout is synthesised because the
#   hook's DECISION, not the suite's rendering, is under test.
# - Whether a real filesystem permission failure (rather than the module-cache
#   injection i-identity-throw.sh uses) is the shape verifyEmitterIdentity throws on.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

set -u

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

echo ""
echo "=== Results ==="
echo "Total: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "All tests passed!"
