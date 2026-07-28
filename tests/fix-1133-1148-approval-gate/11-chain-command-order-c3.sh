# shellcheck shell=bash
# Tests: hooks/workflow-mark.js, hooks/workflow-mark/confirm-approval-handler.js, hooks/lib/workflow-state/completion-approval.js
# Tags: workflow, approval-gate, workflow-mark, scope:common
# (Sourced fragment of tests/fix-1133-1148-approval-gate.sh — not run standalone.)
# ===========================================================================
# G11 (C3): chained-command sentinel processing. workflow-mark.js splits a Bash
# command on `&&` and dispatches every recognized sentinel (all-or-nothing).
# When CONFIRM_OUTLINE and CONFIRM_DETAIL are emitted in one chained command,
# BOTH approvals must be recorded — the confirm-approval-handler must not stop
# after the first sentinel.
# fail-before-fix: pre-fix workflow-mark has no confirm-approval-handler, so no
# plan_approvals entries are written for either step.
# ===========================================================================

echo ""
echo "=== G11 (C3): chained CONFIRM_OUTLINE && CONFIRM_DETAIL records both approvals ==="

SID="g11-$$"
write_state "$SID" "$(gen_state '{"workflow_init":"complete","clarify_intent":"complete","research":"complete"}')"
touch "$PLANS_DIR/${SID}-outline.md" "$PLANS_DIR/${SID}-detail.md"

run_mark 'echo "<<WORKFLOW_CONFIRM_OUTLINE: ok>>" && echo "<<WORKFLOW_CONFIRM_DETAIL: ok>>"' "$SID"

check "G11a. chained command records outline approval" "yes" "$(has_approval "$SID" outline)"
check "G11b. chained command records detail approval (not dropped after first)" "yes" "$(has_approval "$SID" detail)"
