# ===========================================================================
# === G1: reconcile-state --dry-run shows outline/detail in EVIDENCE_STEPS ===
# ===========================================================================

echo ""
echo "=== G1: reconcile-state --dry-run shows outline/detail in EVIDENCE_STEPS ==="

SID="g1-$$"
write_state "$SID" "$(OUTLINE_PENDING_DETAIL_COMPLETE $SID)"
# No evidence artifacts → steps should show "pending (no evidence)".

run_reconcile --session "$SID" --dry-run

check_contains "G1. reconcile-state --dry-run output mentions outline" \
  "outline" "${RECONCILE_OUT:-}"
check_contains "G1b. reconcile-state --dry-run output mentions detail" \
  "detail" "${RECONCILE_OUT:-}"

# Post-#1133: reconcile-state must NOT propose completing a gated step from
# artifact presence alone — it passes no sanctioned token, so an unapproved
# outline stays pending and the line names the missing approval instead of a
# pending -> complete transition.
SID="g1b-$$"
write_state "$SID" "$(OUTLINE_PENDING_DETAIL_COMPLETE $SID)"
touch "$PLANS_DIR/${SID}-outline.md"

run_reconcile --session "$SID" --dry-run

check_contains "G1c. dry-run with outline.md but no approval → reports approval missing" \
  "approval missing" "${RECONCILE_OUT:-}"
# Scoped to the outline line only: non-gated steps (write_tests/docs) may
# legitimately show transitions from the ambient repo's own evidence.
check_not_contains "G1d. dry-run does NOT propose outline pending -> complete without approval" \
  "outline: pending -> complete" "${RECONCILE_OUT:-}"

rm -f "$PLANS_DIR/${SID}-outline.md"

# With an approval on record the evidence-driven reconcile transition returns.
SID="g1f-$$"
write_state "$SID" "$(OUTLINE_PENDING_DETAIL_COMPLETE $SID)"
seed_approval "$SID" outline

run_reconcile --session "$SID" --dry-run

check_contains "G1f. dry-run with outline.md + approval → proposes pending -> complete" \
  "outline: pending -> complete" "${RECONCILE_OUT:-}"

rm -f "$PLANS_DIR/${SID}-outline.md"
