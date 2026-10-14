#!/usr/bin/env bash
# tests/hooks/feature-2650-confirm-continuation.sh
# Tests: hooks/lib/confirm-continuation.js, hooks/lib/confirm-gate/plan-gate.js, bin/workflow/lib/next-step/gate-mode.js
# Tags: confirm-checkpoint, confirm-plan, stop-guard, continuation, plan-link, deadline, confirm-gate, TL2, scope:issue-specific
# #2650: the shared predicates of the same-turn CONFIRM continuation. T1-T5 drive
# pickContinuationStage with an injected probe and clock (deadline-driver.js); the unit driver
# covers approvalArtifactPath, linkKey, sameTurnContinuation, markBindsArtifact and the wording;
# plan-gate.sh covers planGateState (G1-G5).
# The Stop-hook end-to-end cases (N1-N20, T6) live in feature-stop-guard-layer2/continuation.sh.
set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

CCN_TMP="$(make_tmp)"
readonly CCN_TMP
trap 'rm -rf "$CCN_TMP"' EXIT
export WORKFLOW_STATE_DIR="$CCN_TMP/workflow-state" WORKFLOW_PLANS_DIR="$CCN_TMP/plans"
mkdir -p "$WORKFLOW_STATE_DIR" "$WORKFLOW_PLANS_DIR" "$CCN_TMP/no-transcripts"
unset CLAUDE_CODE_SESSION_ID PLAN_LANG CONFIRM_INTENT CONFIRM_OUTLINE CONFIRM_DETAIL 2>/dev/null || true
export CLAUDE_TRANSCRIPT_BASE_DIR="$CCN_TMP/no-transcripts" PLAN_SYNC_REMOTE_URL=""
printf 'CONFIRM_INTENT=on\nCONFIRM_OUTLINE=on\nCONFIRM_DETAIL=on\nPLAN_LANG=english\nPLAN_SYNC_REMOTE_URL=\n' > "$AGENTS_MAIN_ROOT/.env"
WORKFLOW_STATE_DIR="$(np "$WORKFLOW_STATE_DIR")"
WORKFLOW_PLANS_DIR="$(np "$WORKFLOW_PLANS_DIR")"
cd "$CCN_TMP" || exit 1

DDIR="$SCRIPT_CHECKOUT_ROOT/tests/hooks/feature-2650-confirm-continuation"

# ccn_run <driver.js> [args...] — one pass/fail per PASS|name / FAIL|name|detail line.
ccn_run() {
  local out line rest
  out="$(run_with_timeout 120 node "$DDIR/$1" "${@:2}" 2>&1 || printf 'FAIL|driver %s|exit=%s\n' "$*" "$?")"
  [[ -z "$out" ]] && { fail "driver $* produced no assertions"; return; }
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    rest="${line#*|}"
    case "$line" in
      PASS\|*) pass "$rest" ;;
      FAIL\|*) fail "${rest%%|*}" "${rest#*|}" ;;
      *) fail "unparsed driver line" "$line" ;;
    esac
  done <<< "$out"
}

case_begin "t1-t5-continuation-deadline" "hooks/lib/confirm-continuation.js"
ccn_run deadline-driver.js
case_end

case_begin "continuation-predicates-and-wording" "hooks/lib/confirm-continuation.js"
ccn_run unit-driver.js
case_end

# shellcheck source=feature-2650-confirm-continuation/plan-gate.sh
. "$DDIR/plan-gate.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
