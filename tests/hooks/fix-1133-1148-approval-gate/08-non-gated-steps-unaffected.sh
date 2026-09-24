# shellcheck shell=bash
# Tests: hooks/workflow-state/completion-approval.js, hooks/workflow-state/state-io.js, bin/workflow/next-step, bin/workflow/lib/next-step/
# Tags: workflow, approval-gate, regression, scope:common
# (Sourced fragment of tests/fix-1133-1148-approval-gate.sh — not run standalone.)
# ===========================================================================
# G08: regression net — non-gated steps are unaffected by the approval gate.
# Only outline/detail are in APPROVAL_GATED_STEPS. Every other step must still
# complete via markStep / evidence auto-complete WITHOUT any approval record,
# and must NOT gain a plan_approvals entry. Passes both pre- and post-fix by
# design (control that guards against over-broad gating).
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

# G08b: clarify_intent evidence auto-complete (intent.md) still works, no approval.
SID="g08b-$$"
write_state "$SID" "$(gen_state '{"workflow_init":"complete"}')"
touch "$PLANS_DIR/${SID}-intent.md"
run_next_step --session "$SID" >/dev/null
check "G08b. clarify_intent auto-completes via intent.md evidence" "complete" "$(read_state_status "$SID" clarify_intent)"
check "G08b2. no plan_approvals for clarify_intent" "no" "$(has_approval "$SID" clarify_intent)"
