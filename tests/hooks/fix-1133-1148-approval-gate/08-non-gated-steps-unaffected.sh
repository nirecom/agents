# shellcheck shell=bash
# Tests: hooks/workflow-state/completion-approval.js, hooks/workflow-state/state-io.js, bin/workflow/next-step, bin/workflow/lib/next-step/
# Tags: workflow, approval-gate, regression, scope:common
# (Sourced fragment of tests/hooks/fix-1133-1148-approval-gate.sh — not run standalone.)
# ===========================================================================
# G08: regression net — non-gated steps are unaffected by the approval gate.
# Since #2277 clarify_intent/outline/detail are APPROVAL_GATED_STEPS. Every other
# step must still complete WITHOUT any approval record and gain no plan_approvals
# entry; G08b pins that intent.md evidence alone no longer completes clarify_intent.
# ===========================================================================

echo ""
echo "=== G08: non-gated steps complete freely and gain no approval record ==="

# G08a: markStep on a non-gated step succeeds and records no approval.
SID="g08a-$$"
write_state "$SID" "$(gen_state '{"workflow_init":"complete","clarify_intent":"complete"}')"
OUT=$(node_probe '
  const ws = require(process.argv[1]);
  try { ws.markStep(process.argv[2], "research", "complete"); console.log("NOERROR"); }
  catch (e) { console.log("THREW:" + (e.code || e.name)); }
' "$WFSTATE_N" "$SID")
check "G08a. non-gated research completes (no throw)" "NOERROR" "$OUT"
check "G08a2. research complete" "complete" "$(read_state_status "$SID" research)"
check "G08a3. no plan_approvals fabricated for non-gated step" "no" "$(has_approval "$SID" research)"

# G08b (#2277 S9/S13): intent.md evidence alone leaves clarify_intent pending and fabricates
# no approval; G08c: once the intent is approved the same evidence auto-completes it.
SID="g08b-$$"
write_state "$SID" "$(gen_state '{"workflow_init":"complete"}')"
# #2654: the clarify_intent gate reads intent.md `## Issues`, so an empty file would block first.
printf '## Issues\n- #1133\n' > "$PLANS_DIR/${SID}-intent.md"
run_next_step --session "$SID" >/dev/null
check_ne "G08b. unapproved intent.md evidence does not complete clarify_intent" "complete" "$(read_state_status "$SID" clarify_intent)"
check "G08b2. no plan_approvals for clarify_intent" "no" "$(has_approval "$SID" clarify_intent)"
run_with_timeout node "$PLAN_APPROVAL_FIXTURE" approve "$SID" clarify_intent >/dev/null ||
  echo "FAIL: G08c setup: could not record the clarify_intent approval"
run_next_step --session "$SID" >/dev/null
check "G08c. approved intent.md evidence auto-completes clarify_intent" "complete" "$(read_state_status "$SID" clarify_intent)"
