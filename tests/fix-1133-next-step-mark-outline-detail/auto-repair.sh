# ===========================================================================
# === A1-A2: outline/detail evidence-based auto-repair ===
# ===========================================================================
# Post-#1133: evidence alone is NOT authority for the approval-gated steps.
# A plan file on disk cannot distinguish "review not started" from "review done
# but unapproved", so next-step must refuse to auto-complete outline/detail and
# report the inconsistency (ACTION=abort) instead. Auto-repair still fires once
# a plan_approvals record exists — asserted by the A1d / A2c approved variants.

echo ""
echo "=== A1: outline=pending + detail=complete + outline.md, NO approval → abort, outline stays pending ==="

SID="a1-$$"
write_state "$SID" "$(OUTLINE_PENDING_DETAIL_COMPLETE $SID)"
# outline.md artifact present, but no approval on record.
touch "$PLANS_DIR/${SID}-outline.md"

OUT=$(run_next_step --session "$SID")
ACTION=""; NEXT_SKILL=""
eval "$OUT" 2>/dev/null || true

check "A1. outline.md exists but unapproved → ACTION=abort (no auto-complete)" \
  "abort" "${ACTION:-}"
check "A1b. unapproved gated step → NEXT_SKILL='' (no skill dispatched)" \
  "" "${NEXT_SKILL:-}"
check "A1c. unapproved outline.md → state still shows outline=pending" \
  "pending" "$(read_state_status "$SID" "outline")"

rm -f "$PLANS_DIR/${SID}-outline.md"

echo ""
echo "=== A1d: same fixture WITH a recorded approval → auto-repair → branching_complete ==="

SID="a1d-$$"
write_state "$SID" "$(OUTLINE_PENDING_DETAIL_COMPLETE $SID)"
seed_approval "$SID" outline

OUT=$(run_next_step --session "$SID")
ACTION=""; NEXT_SKILL=""
eval "$OUT" 2>/dev/null || true

# After approved auto-repair: outline=complete, detail=complete → next is branching_complete.
check "A1d. approved outline.md → ACTION=invoke (branching_complete)" \
  "invoke" "${ACTION:-}"
check "A1e. approved auto-repair → NEXT_SKILL='' (branching_complete has no skill)" \
  "" "${NEXT_SKILL:-}"
check "A1f. approved auto-repair → state shows outline=complete" \
  "complete" "$(read_state_status "$SID" "outline")"

rm -f "$PLANS_DIR/${SID}-outline.md"

echo ""
echo "=== A2: detail=pending + detail.md, NO approval → abort, detail stays pending (symmetric to A1) ==="

SID="a2-$$"
write_state "$SID" "$(DETAIL_PENDING_BRANCHING_COMPLETE $SID)"
touch "$PLANS_DIR/${SID}-detail.md"

OUT=$(run_next_step --session "$SID")
ACTION=""; NEXT_SKILL=""
eval "$OUT" 2>/dev/null || true

check "A2. detail.md exists but unapproved → ACTION=abort (no auto-complete)" \
  "abort" "${ACTION:-}"
check "A2b. unapproved detail.md → state still shows detail=pending" \
  "pending" "$(read_state_status "$SID" "detail")"

rm -f "$PLANS_DIR/${SID}-detail.md"

echo ""
echo "=== A2c: same fixture WITH a recorded approval → auto-repair fires ==="

SID="a2c-$$"
write_state "$SID" "$(DETAIL_PENDING_BRANCHING_COMPLETE $SID)"
seed_approval "$SID" detail

OUT=$(run_next_step --session "$SID")
ACTION=""; NEXT_SKILL=""
eval "$OUT" 2>/dev/null || true

check "A2c. approved detail.md + branching_complete=complete → ACTION=invoke" \
  "invoke" "${ACTION:-}"
check "A2d. approved auto-repair → state shows detail=complete" \
  "complete" "$(read_state_status "$SID" "detail")"

rm -f "$PLANS_DIR/${SID}-detail.md"
