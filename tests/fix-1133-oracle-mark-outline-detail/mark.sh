# ===========================================================================
# === M1-M6: --mark CLI flag ===
# ===========================================================================

echo ""
echo "=== M1: --mark outline complete → exit 0 + state outline=complete ==="

SID="m1-$$"
write_state "$SID" "$(OUTLINE_PENDING_DETAIL_COMPLETE $SID)"
check "M1-pre. outline is pending before --mark" \
  "pending" "$(read_state_status "$SID" "outline")"
run_oracle_rc --session "$SID" --mark outline complete
check "M1. --mark outline complete → exit 0" "0" "$RC"
check "M1b. --mark outline complete → state shows outline=complete" \
  "complete" "$(read_state_status "$SID" "outline")"

echo ""
echo "=== M2: --mark bogus_step complete → nonzero exit + stderr ==="

SID="m2-$$"
write_state "$SID" "$(NORMAL_BRANCHING_COMPLETE_CURRENT $SID)"
run_oracle_rc --session "$SID" --mark bogus_step complete
check_nonzero "M2. --mark bogus_step complete → nonzero exit" "$RC"
if [ -n "${STDERR:-}" ]; then
  echo "PASS: M2b. --mark bogus_step → stderr error message emitted"
  PASS=$((PASS + 1))
else
  echo "FAIL: M2b. --mark bogus_step → expected stderr error, got empty"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== M3: --mark (no args) → nonzero exit ==="

SID="m3-$$"
write_state "$SID" "$(NORMAL_BRANCHING_COMPLETE_CURRENT $SID)"
run_oracle_rc --session "$SID" --mark
check_nonzero "M3. --mark (no step argument) → nonzero exit" "$RC"

echo ""
echo "=== M4: --mark outline (missing status token) → nonzero exit + stderr ==="

SID="m4-$$"
write_state "$SID" "$(NORMAL_BRANCHING_COMPLETE_CURRENT $SID)"
run_oracle_rc --session "$SID" --mark outline
check_nonzero "M4. --mark outline (no status) → nonzero exit" "$RC"
if [ -n "${STDERR:-}" ]; then
  echo "PASS: M4b. --mark outline (no status) → stderr error emitted"
  PASS=$((PASS + 1))
else
  echo "FAIL: M4b. --mark outline (no status) → expected stderr error, got empty"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== M5: --mark outline invalid_status → nonzero exit + stderr ==="

SID="m5-$$"
write_state "$SID" "$(NORMAL_BRANCHING_COMPLETE_CURRENT $SID)"
run_oracle_rc --session "$SID" --mark outline invalid_status
check_nonzero "M5. --mark outline invalid_status → nonzero exit" "$RC"
if [ -n "${STDERR:-}" ]; then
  echo "PASS: M5b. --mark outline invalid_status → stderr error emitted"
  PASS=$((PASS + 1))
else
  echo "FAIL: M5b. --mark outline invalid_status → expected stderr error, got empty"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== M6: --mark detail complete → exit 0 + state detail=complete (symmetric to M1) ==="

SID="m6-$$"
write_state "$SID" "$(DETAIL_PENDING_BRANCHING_COMPLETE $SID)"
check "M6-pre. detail is pending before --mark" \
  "pending" "$(read_state_status "$SID" "detail")"
run_oracle_rc --session "$SID" --mark detail complete
check "M6. --mark detail complete → exit 0" "0" "$RC"
check "M6b. --mark detail complete → state shows detail=complete" \
  "complete" "$(read_state_status "$SID" "detail")"
