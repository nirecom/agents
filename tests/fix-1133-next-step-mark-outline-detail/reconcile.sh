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

# Verify that when outline.md exists, reconcile-state would mark it complete.
SID="g1b-$$"
write_state "$SID" "$(OUTLINE_PENDING_DETAIL_COMPLETE $SID)"
touch "$PLANS_DIR/${SID}-outline.md"

run_reconcile --session "$SID" --dry-run

check_contains "G1c. reconcile-state --dry-run with outline.md → would update outline" \
  "outline" "${RECONCILE_OUT:-}"
if echo "${RECONCILE_OUT:-}" | grep -qiE "would update|pending.*complete"; then
  echo "PASS: G1d. reconcile-state --dry-run with outline.md → shows pending->complete transition"
  PASS=$((PASS + 1))
else
  echo "FAIL: G1d. reconcile-state --dry-run with outline.md → expected pending->complete, got: ${RECONCILE_OUT:-}"
  FAIL=$((FAIL + 1))
fi

rm -f "$PLANS_DIR/${SID}-outline.md"
