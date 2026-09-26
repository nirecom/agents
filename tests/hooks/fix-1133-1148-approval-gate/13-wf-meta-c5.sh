# shellcheck shell=bash
# Tests: hooks/workflow-state/completion-approval.js, bin/workflow/next-step, hooks/workflow-state/effective-state.js, bin/workflow/lib/next-step/
# Tags: workflow, approval-gate, wf-meta, scope:common
# (Sourced fragment of tests/fix-1133-1148-approval-gate.sh — not run standalone.)
# ===========================================================================
# G13 (C5): the approval gate holds for wf-meta workflows too. In a wf-meta
# session `detail` is auto-skipped, but `outline` is still an active gated step.
# next-step must NOT auto-complete outline from evidence alone in a wf-meta
# session any more than in wf-code — the gate is workflow-type-agnostic.
# fail-before-fix: pre-fix outline → complete under wf-meta as well.
# ===========================================================================

echo ""
echo "=== G13 (C5): wf-meta — outline gate still enforced ==="

SID="g13-$$"
write_state "$SID" "$(gen_state '{"workflow_init":"complete","clarify_intent":"complete","research":"complete"}' wf-meta)"
touch "$PLANS_DIR/${SID}-outline.md"

run_next_step --session "$SID" >/dev/null

check_ne "G13a. wf-meta outline is NOT auto-completed without approval" "complete" "$(read_state_status "$SID" outline)"
check "G13b. wf-meta: no plan_approvals fabricated for outline" "no" "$(has_approval "$SID" outline)"
