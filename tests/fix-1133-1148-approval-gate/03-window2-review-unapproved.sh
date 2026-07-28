# shellcheck shell=bash
# Tests: hooks/lib/workflow-state/completion-approval.js, hooks/lib/workflow-state/state-io.js, bin/workflow/next-step, hooks/workflow-mark.js
# Tags: workflow, approval-gate, outline, detail, scope:common
# (Sourced fragment of tests/fix-1133-1148-approval-gate.sh — not run standalone.)
# ===========================================================================
# G03: Window 2 — review COMPLETE but not yet approved (#1133), detail step.
# The codex round-number/concern-ledger files are deleted on a terminal verdict,
# so once review finishes they are absent again — indistinguishable to the
# negative-evidence heuristic from window 1. Pre-fix next-step auto-completes
# detail; post-fix refuses until an approval is recorded.
# Symmetric to G02 (CPR-5): exercises the `detail` gated member.
# fail-before-fix: pre-fix detail → complete.
# ===========================================================================

echo ""
echo "=== G03: window-2 (review done, unapproved) — detail must NOT auto-complete ==="

SID="g03-$$"
# outline already complete (reads never re-validate persisted state); detail pending.
write_state "$SID" "$(gen_state '{"workflow_init":"complete","clarify_intent":"complete","research":"complete","outline":"complete"}' wf-code '{"plan_approvals":{"outline":{"source":"confirm-sentinel"}}}')"
touch "$PLANS_DIR/${SID}-detail.md"    # draft present; round/ledger absent = "review done"

run_next_step --session "$SID" >/dev/null

check_ne "G03a. detail is NOT auto-completed without approval" "complete" "$(read_state_status "$SID" detail)"
check "G03b. no plan_approvals entry fabricated for detail" "no" "$(has_approval "$SID" detail)"
