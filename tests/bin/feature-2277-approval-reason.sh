#!/usr/bin/env bash
# Tests: hooks/workflow-state/effective-state.js, hooks/workflow-state/current-step.js, bin/workflow/lib/next-step/approval-reason.js, bin/workflow/lib/next-step/verdict.js, bin/workflow/lib/next-step/gate-mode.js, hooks/workflow-mark/reset-handler.js, bin/workflow/lib/next-step/state-ops.js, hooks/workflow-state/record-step-verdict.js, hooks/workflow-state/inheritance/apply.js, bin/workflow/reconcile-state
# Tags: plan-approval, completion-approval, effective-state, next-step, recovery, confirm-intent, TL2, scope:issue-specific
# #2277: an unapproved gated `complete` reads as pending (derived only, nothing rewritten);
# next-step answers `awaiting-plan-approval: <step>` before the inconsistency scan, and every
# APPROVAL_GATED_STEPS consumer treats clarify_intent like outline/detail.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

AR_TMP="$(make_tmp)"
readonly AR_TMP
trap 'rm -rf "$AR_TMP"' EXIT
export WORKFLOW_STATE_DIR="$AR_TMP/workflow-state" WORKFLOW_PLANS_DIR="$AR_TMP/plans"
mkdir -p "$WORKFLOW_STATE_DIR" "$WORKFLOW_PLANS_DIR" "$AR_TMP/no-transcripts" "$AR_TMP/repo"
unset CLAUDE_CODE_SESSION_ID CONFIRM_INTENT CONFIRM_OUTLINE CONFIRM_DETAIL 2>/dev/null || true
export CLAUDE_TRANSCRIPT_BASE_DIR="$AR_TMP/no-transcripts" PLAN_SYNC_REMOTE_URL=""
# Every gate armed: the off waiver is read from this config FILE only.
printf 'CONFIRM_INTENT=on\nCONFIRM_OUTLINE=on\nCONFIRM_DETAIL=on\nPLAN_SYNC_REMOTE_URL=\n' > "$AGENTS_MAIN_ROOT/.env"
git init -q "$AR_TMP/repo" >/dev/null 2>&1
git -C "$AR_TMP/repo" config core.hooksPath /dev/null
export CLAUDE_PROJECT_DIR
CLAUDE_PROJECT_DIR="$(np "$AR_TMP/repo")"
cd "$AR_TMP/repo" || exit 1
WORKFLOW_STATE_DIR="$(np "$WORKFLOW_STATE_DIR")"
WORKFLOW_PLANS_DIR="$(np "$WORKFLOW_PLANS_DIR")"

DRIVER_DIR="$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2277-approval-reason"

# ar_report <driver-output> — one pass/fail per PASS|name / FAIL|name|detail line.
ar_report() {
  local line rest name
  [ -z "$1" ] && { fail "driver produced no assertions"; return; }
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    rest="${line#*|}"; name="${rest%%|*}"
    case "$line" in
      PASS\|*) pass "$name" ;;
      FAIL\|*) fail "$name" "${rest#*|}" ;;
      *) fail "unparsed driver line" "$line" ;;
    esac
  done <<< "$1"
}

# ar_run <driver> <mode>
ar_run() {
  ar_report "$(run_with_timeout 120 node "$DRIVER_DIR/$1" "$2" 2>&1 || printf 'FAIL|driver %s %s|exit=%s\n' "$1" "$2" "$?")"
}

case_begin "unapproved-complete-reads-pending" "hooks/workflow-state/effective-state.js"
ar_run reason-driver.js effective
case_end

case_begin "current-step-is-first-unapproved-stage" "hooks/workflow-state/current-step.js"
ar_run reason-driver.js current
case_end

case_begin "approval-wait-for-helper" "bin/workflow/lib/next-step/approval-reason.js"
ar_run reason-driver.js reason
case_end

case_begin "next-step-awaiting-before-inconsistency-scan" "bin/workflow/lib/next-step/verdict.js"
ar_run reason-driver.js nextstep
case_end

case_begin "gate-mode-targets-unapproved-stage" "bin/workflow/lib/next-step/gate-mode.js"
ar_run reason-driver.js gate
case_end

case_begin "reset-covers-clarify-intent" "hooks/workflow-mark/reset-handler.js"
ar_run ripple-driver.js reset
case_end

case_begin "mark-refuses-unapproved-clarify-intent" "bin/workflow/lib/next-step/state-ops.js"
ar_run ripple-driver.js mark
case_end

case_begin "record-step-verdict-refuses-clarify-intent" "hooks/workflow-state/record-step-verdict.js"
ar_run ripple-driver.js verdict
case_end

case_begin "inheritance-stamps-clarify-intent-audit" "hooks/workflow-state/inheritance/apply.js"
ar_run ripple-driver.js inherit
case_end

case_begin "reconcile-state-needs-intent-approval" "bin/workflow/reconcile-state"
ar_run ripple-driver.js reconcile
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
