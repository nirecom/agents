#!/usr/bin/env bash
# tests/hooks/feature-2544-dispatch-outcome.sh
# Tests: hooks/lib/worker-outcome-contract.js, hooks/workflow-state/dispatch-settlement.js, hooks/workflow-run-tests/dispatch-outcome.js, hooks/workflow-run-tests/record-run.js, hooks/workflow-run-tests.js, hooks/workflow-run-tests/failing-list.js, hooks/lib/plans-artifact-registry.js
# Tags: workflow, run-tests, worker-dispatch, outcome-file, hook, security, tl2, scope:issue-specific
# #2544: run_tests is settled from the dispatcher's outcome file, never from stdout.
# TL3 gap: real PostToolUse delivery for a run_in_background Bash call (when the hook
#   fires and what tool_response it carries) is not exercised; every case pipes
#   hand-built hook input. Checked at the WORKFLOW_USER_VERIFIED preflight.
# Dispatcher: helpers in feature-2544-dispatch-outcome/common.sh, one fragment per case group.
set -uo pipefail

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

F2544_TMP_ROOT="$(make_tmp)"
readonly F2544_TMP_ROOT
trap 'rm -rf "$F2544_TMP_ROOT"' EXIT
mkdir -p "$F2544_TMP_ROOT/state" "$F2544_TMP_ROOT/plans" "$F2544_TMP_ROOT/transcripts"
WORKFLOW_STATE_DIR="$(np "$F2544_TMP_ROOT/state")"
WORKFLOW_PLANS_DIR="$(np "$F2544_TMP_ROOT/plans")"
CLAUDE_TRANSCRIPT_BASE_DIR="$(np "$F2544_TMP_ROOT/transcripts")"
export WORKFLOW_STATE_DIR WORKFLOW_PLANS_DIR CLAUDE_TRANSCRIPT_BASE_DIR
unset CLAUDE_CODE_SESSION_ID
harness_assert_isolated
cd "$F2544_TMP_ROOT" || exit 1

F2544_CASE_DIR="$SCRIPT_CHECKOUT_ROOT/tests/hooks/feature-2544-dispatch-outcome"

case_begin "dispatch-outcome-case-groups" "hooks/workflow-run-tests.js"
# shellcheck source=tests/hooks/feature-2544-dispatch-outcome/common.sh
. "$F2544_CASE_DIR/common.sh"
# shellcheck source=tests/hooks/feature-2544-dispatch-outcome/a-contract.sh
. "$F2544_CASE_DIR/a-contract.sh"
# shellcheck source=tests/hooks/feature-2544-dispatch-outcome/d-unsettled.sh
. "$F2544_CASE_DIR/d-unsettled.sh"
# shellcheck source=tests/hooks/feature-2544-dispatch-outcome/b-ingest.sh
. "$F2544_CASE_DIR/b-ingest.sh"
# shellcheck source=tests/hooks/feature-2544-dispatch-outcome/c-trust.sh
. "$F2544_CASE_DIR/c-trust.sh"
# shellcheck source=tests/hooks/feature-2544-dispatch-outcome/e-stdout-demote-only.sh
. "$F2544_CASE_DIR/e-stdout-demote-only.sh"
# shellcheck source=tests/hooks/feature-2544-dispatch-outcome/f-path-notation.sh
. "$F2544_CASE_DIR/f-path-notation.sh"
# shellcheck source=tests/hooks/feature-2544-dispatch-outcome/g-rewind-and-docs-skip.sh
. "$F2544_CASE_DIR/g-rewind-and-docs-skip.sh"
# shellcheck source=tests/hooks/feature-2544-dispatch-outcome/h-replay-noop.sh
. "$F2544_CASE_DIR/h-replay-noop.sh"
# shellcheck source=tests/hooks/feature-2544-dispatch-outcome/i-publication-order.sh
. "$F2544_CASE_DIR/i-publication-order.sh"
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[[ "$FAIL" -eq 0 ]] || exit 1
