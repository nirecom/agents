# shellcheck shell=bash
# Tests: hooks/workflow-state/completion-approval.js, hooks/workflow-state/state-io.js, bin/workflow/next-step, hooks/workflow-mark.js
# Tags: workflow, approval-gate, outline, detail, scope:common
# (Sourced fragment of tests/fix-1133-1148-approval-gate.sh — not run standalone.)
# ===========================================================================
# G02: Window 1 — review NOT started (#1133). outline.md exists, no review
# round/ledger files, no approval. The negative-evidence heuristic in
# evidence-resolver returns true here, so pre-fix next-step auto-completes
# outline, bypassing CONFIRM_OUTLINE. Post-fix: completion is refused —
# outline stays not-complete and no approval is fabricated.
# fail-before-fix: pre-fix outline → complete.
# ===========================================================================

echo ""
echo "=== G02: window-1 (review not started) — outline must NOT auto-complete ==="

SID="g02-$$"
write_state "$SID" "$(gen_state '{"workflow_init":"complete","clarify_intent":"complete","research":"complete"}')"
# outline.md present (a draft), but NO round-number/concern-ledger and NO approval.
touch "$PLANS_DIR/${SID}-outline.md"

run_next_step --session "$SID" >/dev/null

check_ne "G02a. outline is NOT auto-completed without approval" "complete" "$(read_state_status "$SID" outline)"
check "G02b. no plan_approvals entry fabricated for outline" "no" "$(has_approval "$SID" outline)"
