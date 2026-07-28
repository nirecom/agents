# shellcheck shell=bash
# Tests: hooks/lib/workflow-state/completion-approval.js, hooks/lib/workflow-state/state-io.js, bin/workflow/next-step, hooks/workflow-mark.js
# Tags: workflow, approval-gate, outline, detail, scope:common
# (Sourced fragment of tests/fix-1133-1148-approval-gate.sh — not run standalone.)
# ===========================================================================
# G04: Approved happy path (#1133). A CONFIRM_OUTLINE sentinel, processed by
# the confirm-approval-handler in workflow-mark.js, records a plan_approvals
# entry with a sanctioned source. next-step may then complete outline, and the
# approval survives the transition.
# fail-before-fix: pre-fix workflow-mark has no confirm-approval-handler, so no
# plan_approvals is ever recorded (source MISSING).
# ===========================================================================

echo ""
echo "=== G04: approved happy path — CONFIRM_OUTLINE records approval, then completes ==="

SID="g04-$$"
write_state "$SID" "$(gen_state '{"workflow_init":"complete","clarify_intent":"complete","research":"complete"}')"
touch "$PLANS_DIR/${SID}-outline.md"

# G04a: the approval sentinel records a plan_approvals entry from a sanctioned source.
run_mark 'echo "<<WORKFLOW_CONFIRM_OUTLINE: approved by user>>"' "$SID"
check "G04a. CONFIRM_OUTLINE records plan_approvals.outline" "yes" "$(has_approval "$SID" outline)"
check_ne "G04a2. recorded approval carries a source (not MISSING)" "MISSING" "$(read_approval_source "$SID" outline)"

# G04b: with the approval on record, next-step completes outline and the approval survives.
run_next_step --session "$SID" >/dev/null
check "G04b. outline completes once approved" "complete" "$(read_state_status "$SID" outline)"
check_ne "G04b2. approval record survives the completion transition" "MISSING" "$(read_approval_source "$SID" outline)"
