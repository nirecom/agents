# ===========================================================================
# === A1-A2: outline/detail evidence-based auto-repair ===
# ===========================================================================

echo ""
echo "=== A1: outline=pending + detail=complete + outline.md exists → auto-repair → branching_complete ==="

SID="a1-$$"
write_state "$SID" "$(OUTLINE_PENDING_DETAIL_COMPLETE $SID)"
# Create the outline.md artifact in PLANS_DIR to trigger evidence-based auto-repair.
touch "$PLANS_DIR/${SID}-outline.md"

OUT=$(run_next_step --session "$SID")
ACTION=""; NEXT_SKILL=""
eval "$OUT" 2>/dev/null || true

# After auto-repair: outline=complete, detail=complete → next step is branching_complete.
check "A1. outline.md exists + detail=complete → ACTION=invoke (branching_complete)" \
  "invoke" "${ACTION:-}"
check "A1b. outline.md auto-repair → NEXT_SKILL='' (branching_complete has no skill)" \
  "" "${NEXT_SKILL:-}"
# The state should have been repaired: outline must now be complete.
check "A1c. outline.md auto-repair → state shows outline=complete" \
  "complete" "$(read_state_status "$SID" "outline")"

rm -f "$PLANS_DIR/${SID}-outline.md"

echo ""
echo "=== A2: detail=pending + detail.md exists → auto-repair → branching_complete ==="

SID="a2-$$"
write_state "$SID" "$(DETAIL_PENDING_BRANCHING_COMPLETE $SID)"
# Create the detail.md artifact in PLANS_DIR to trigger evidence-based auto-repair.
touch "$PLANS_DIR/${SID}-detail.md"

OUT=$(run_next_step --session "$SID")
ACTION=""; NEXT_SKILL=""
eval "$OUT" 2>/dev/null || true

# After auto-repair: detail=complete, branching_complete=complete → next step is write_tests.
check "A2. detail.md exists + branching_complete=complete → ACTION=invoke" \
  "invoke" "${ACTION:-}"
check "A2b. detail.md auto-repair → state shows detail=complete" \
  "complete" "$(read_state_status "$SID" "detail")"

rm -f "$PLANS_DIR/${SID}-detail.md"
