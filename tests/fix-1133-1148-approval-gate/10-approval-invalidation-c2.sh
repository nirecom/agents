# shellcheck shell=bash
# Tests: hooks/workflow-state/completion-approval.js, hooks/workflow-state/state-io.js, bin/workflow/next-step, hooks/workflow-mark/reset-handler.js
# Tags: workflow, approval-gate, invalidation, scope:common
# (Sourced fragment of tests/fix-1133-1148-approval-gate.sh — not run standalone.)
# ===========================================================================
# G10 (C2): approval is invalidated when a gated step transitions away from
# complete. When outline is reset (pending), its plan_approvals entry must be
# dropped so a later re-completion demands fresh approval. Otherwise a stale
# approval would silently re-authorize a changed plan.
# fail-before-fix: pre-fix markStep read-modify-write preserves plan_approvals
# across the reset, so the stale approval survives (has_approval = yes).
# ===========================================================================

echo ""
echo "=== G10 (C2): reset of a gated step invalidates its recorded approval ==="

SID="g10-$$"
write_state "$SID" "$(gen_state '{"workflow_init":"complete","clarify_intent":"complete","research":"complete","outline":"complete"}' wf-code '{"plan_approvals":{"outline":{"source":"confirm-sentinel","approved_at":"2026-06-20T10:00:00.000Z"}}}')"

# Precondition sanity: the fixture starts with an approval on record.
check "G10-pre. fixture has an outline approval to invalidate" "yes" "$(has_approval "$SID" outline)"

run_next_step --session "$SID" --reset outline >/dev/null

check "G10a. outline reset to pending" "pending" "$(read_state_status "$SID" outline)"
check "G10b. stale outline approval invalidated by the reset" "no" "$(has_approval "$SID" outline)"
