# shellcheck shell=bash
# Tests: bin/workflow/next-step, hooks/workflow-state/completion-approval.js, hooks/workflow-state/state-io.js
# Tags: workflow, approval-gate, next-step, mark-cli, scope:common
# (Sourced fragment of tests/fix-1133-1148-approval-gate.sh — not run standalone.)
# ===========================================================================
# G12 (C4): the `next-step --mark <step> complete` recovery CLI is fail-closed
# for gated steps. main() calls markStep with no try/catch, so a refused
# completion (no approval) propagates as an uncaught throw → nonzero exit, and
# the step is NOT persisted complete. A blanket --mark must not become a
# back-door around the approval gate.
# fail-before-fix: pre-fix --mark outline complete exits 0 and persists complete.
# ===========================================================================

echo ""
echo "=== G12 (C4): --mark outline complete without approval fails closed ==="

SID="g12-$$"
write_state "$SID" "$(gen_state '{"workflow_init":"complete","clarify_intent":"complete","research":"complete"}')"

run_next_step_rc --session "$SID" --mark outline complete
check_nonzero "G12a. --mark outline complete (no approval) exits nonzero" "$RC"
check_ne "G12b. outline not persisted complete by the refused --mark" "complete" "$(read_state_status "$SID" outline)"

# Control: --mark on a non-gated step still succeeds (exit 0, persisted).
SID="g12c-$$"
write_state "$SID" "$(gen_state '{"workflow_init":"complete","clarify_intent":"complete"}')"
run_next_step_rc --session "$SID" --mark research complete
check "G12c. control: --mark non-gated step exits 0" "0" "$RC"
check "G12c2. control: non-gated step persisted complete" "complete" "$(read_state_status "$SID" research)"
