# shellcheck shell=bash
# Tests: hooks/workflow-state/completion-approval.js, hooks/workflow-state/state-io.js, bin/workflow/next-step, hooks/workflow-mark.js, bin/workflow/lib/next-step/
# Tags: workflow, approval-gate, outline, detail, scope:common
# (Sourced fragment of tests/fix-1133-1148-approval-gate.sh — not run standalone.)
# ===========================================================================
# G05: CONFIRM_OUTLINE=off path (#1133). When the user has opted out of the
# outline confirmation gate, approval is implicitly granted from a sanctioned
# "confirm-off" source and next-step may complete outline. The distinction from
# the pre-fix bug is that a plan_approvals record with a sanctioned source is
# written — completion is never silent/unrecorded.
# fail-before-fix: pre-fix completes outline but records NO plan_approvals
# (source MISSING).
# ===========================================================================

echo ""
echo "=== G05: CONFIRM_OUTLINE=off — completion is approved via a sanctioned source ==="

SID="g05-$$"
write_state "$SID" "$(gen_state '{"workflow_init":"complete","clarify_intent":"complete","research":"complete"}')"
touch "$PLANS_DIR/${SID}-outline.md"

# The waiver is read from the config FILE (isConfirmOffForStageFromFile), never
# from process.env — see G14. CONFIG_DIR_OFF is the scratch config whose
# contents carry CONFIRM_OUTLINE=off.
CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" WORKFLOW_PLANS_DIR="$PLANS_DIR" \
  AGENTS_CONFIG_DIR="$CONFIG_DIR_OFF" \
  run_with_timeout node "$NEXT_STEP" --session "$SID" >/dev/null 2>&1 || true

check "G05a. outline completes under CONFIRM_OUTLINE=off" "complete" "$(read_state_status "$SID" outline)"
check_ne "G05b. completion is backed by a sanctioned approval source (not MISSING)" "MISSING" "$(read_approval_source "$SID" outline)"
check_ne "G05b2. approval source resolved without error" "ERR" "$(read_approval_source "$SID" outline)"
