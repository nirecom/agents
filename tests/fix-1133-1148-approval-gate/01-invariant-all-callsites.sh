# shellcheck shell=bash
# Tests: hooks/workflow-state/completion-approval.js, hooks/workflow-state/state-io.js, bin/workflow/next-step, hooks/workflow-mark.js, bin/workflow/lib/next-step/
# Tags: workflow, approval-gate, outline, detail, scope:common
# (Sourced fragment of tests/fix-1133-1148-approval-gate.sh — not run standalone.)
# ===========================================================================
# G01: completion-approval invariant fires at every write callsite (#1133 C1)
# The approval-gated steps (outline, detail) MUST NOT be persisted `complete`
# without a recorded plan_approvals entry — regardless of which write path is
# used (writeState directly, or markStep read-modify-write).
# fail-before-fix: pre-fix writeState/markStep have no invariant → NOERROR.
# ===========================================================================

echo ""
echo "=== G01: approval invariant at all write callsites (writeState + markStep) ==="

# --- writeState(outline=complete, no approval) → throw no-approval-record ---
SID="g01a-$$"
write_state "$SID" "$(gen_state '{}')"
OUT=$(node_probe '
  const ws = require(process.argv[1]);
  const sid = process.argv[2];
  const s = ws.readState(sid);
  s.steps.outline.status = "complete";
  s.steps.outline.updated_at = "2026-06-20T10:00:00.000Z";
  try { ws.writeState(sid, s); console.log("NOERROR"); }
  catch (e) { console.log("THREW:" + (e.code || e.name)); }
' "$WFSTATE_N" "$SID")
check_contains "G01a. writeState outline=complete w/o approval throws" "THREW" "$OUT"
check_contains "G01a2. throw carries no-approval-record code" "no-approval-record" "$OUT"

# --- writeState(detail=complete, no approval) → throw (CPR-5 symmetric member) ---
SID="g01b-$$"
write_state "$SID" "$(gen_state '{"outline":"complete"}' wf-code '{"plan_approvals":{"outline":{"source":"confirm-sentinel"}}}')"
OUT=$(node_probe '
  const ws = require(process.argv[1]);
  const sid = process.argv[2];
  const s = ws.readState(sid);
  s.steps.detail.status = "complete";
  s.steps.detail.updated_at = "2026-06-20T10:00:00.000Z";
  try { ws.writeState(sid, s); console.log("NOERROR"); }
  catch (e) { console.log("THREW:" + (e.code || e.name)); }
' "$WFSTATE_N" "$SID")
check_contains "G01b. writeState detail=complete w/o approval throws" "THREW" "$OUT"

# --- markStep(outline complete, no approval) → throw ---
SID="g01c-$$"
write_state "$SID" "$(gen_state '{}')"
OUT=$(node_probe '
  const ws = require(process.argv[1]);
  try { ws.markStep(process.argv[2], "outline", "complete"); console.log("NOERROR"); }
  catch (e) { console.log("THREW:" + (e.code || e.name)); }
' "$WFSTATE_N" "$SID")
check_contains "G01c. markStep outline=complete w/o approval throws" "THREW" "$OUT"
check "G01c2. state not mutated to complete after refused markStep" "pending" "$(read_state_status "$SID" outline)"

# --- markStep(detail complete, no approval) → throw ---
SID="g01d-$$"
write_state "$SID" "$(gen_state '{"outline":"complete"}' wf-code '{"plan_approvals":{"outline":{"source":"confirm-sentinel"}}}')"
OUT=$(node_probe '
  const ws = require(process.argv[1]);
  try { ws.markStep(process.argv[2], "detail", "complete"); console.log("NOERROR"); }
  catch (e) { console.log("THREW:" + (e.code || e.name)); }
' "$WFSTATE_N" "$SID")
check_contains "G01d. markStep detail=complete w/o approval throws" "THREW" "$OUT"

# --- control: non-gated step (docs) completes w/o approval → NOERROR (both pre/post) ---
SID="g01e-$$"
write_state "$SID" "$(gen_state '{}')"
OUT=$(node_probe '
  const ws = require(process.argv[1]);
  try { ws.markStep(process.argv[2], "research", "complete"); console.log("NOERROR"); }
  catch (e) { console.log("THREW:" + (e.code || e.name)); }
' "$WFSTATE_N" "$SID")
check "G01e. control: non-gated step completes w/o approval (no throw)" "NOERROR" "$OUT"
