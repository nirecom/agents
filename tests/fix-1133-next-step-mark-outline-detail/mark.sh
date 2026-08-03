# Tests: bin/workflow/next-step, bin/workflow/lib/next-step/
# Tags: workflow, next-step, mark, outline, detail, scope:issue-specific
# ===========================================================================
# === M1-M6: --mark CLI flag ===
# ===========================================================================

# Post-#1133: outline/detail are approval-gated. `--mark <gated> complete` is no
# longer an authority of its own — without a recorded plan_approvals entry it
# fails closed (nonzero exit, status unchanged). With an approval on record the
# original behavior (exit 0 + complete) is restored. M1/M6 assert the refusal;
# M1c/M6c assert the approved path so the reversal does not delete the coverage.

echo ""
echo "=== M1: --mark outline complete without approval → nonzero exit + outline stays pending ==="

SID="m1-$$"
write_state "$SID" "$(OUTLINE_PENDING_DETAIL_COMPLETE $SID)"
check "M1-pre. outline is pending before --mark" \
  "pending" "$(read_state_status "$SID" "outline")"
run_next_step_rc --session "$SID" --mark outline complete
check_nonzero "M1. --mark outline complete w/o approval → nonzero exit" "$RC"
check "M1b. --mark outline complete w/o approval → state still outline=pending" \
  "pending" "$(read_state_status "$SID" "outline")"

echo ""
echo "=== M1c: --mark outline complete WITH a recorded approval → exit 0 + outline=complete ==="

SID="m1c-$$"
write_state "$SID" "$(OUTLINE_PENDING_DETAIL_COMPLETE $SID)"
seed_approval "$SID" outline
run_next_step_rc --session "$SID" --mark outline complete
check "M1c. --mark outline complete with approval → exit 0" "0" "$RC"
check "M1d. --mark outline complete with approval → state shows outline=complete" \
  "complete" "$(read_state_status "$SID" "outline")"

echo ""
echo "=== M2: --mark bogus_step complete → nonzero exit + stderr ==="

SID="m2-$$"
write_state "$SID" "$(NORMAL_BRANCHING_COMPLETE_CURRENT $SID)"
run_next_step_rc --session "$SID" --mark bogus_step complete
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
run_next_step_rc --session "$SID" --mark
check_nonzero "M3. --mark (no step argument) → nonzero exit" "$RC"

echo ""
echo "=== M4: --mark outline (missing status token) → nonzero exit + stderr ==="

SID="m4-$$"
write_state "$SID" "$(NORMAL_BRANCHING_COMPLETE_CURRENT $SID)"
run_next_step_rc --session "$SID" --mark outline
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
run_next_step_rc --session "$SID" --mark outline invalid_status
check_nonzero "M5. --mark outline invalid_status → nonzero exit" "$RC"
if [ -n "${STDERR:-}" ]; then
  echo "PASS: M5b. --mark outline invalid_status → stderr error emitted"
  PASS=$((PASS + 1))
else
  echo "FAIL: M5b. --mark outline invalid_status → expected stderr error, got empty"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== M6: --mark detail complete without approval → nonzero exit + detail stays pending (symmetric to M1) ==="

SID="m6-$$"
write_state "$SID" "$(DETAIL_PENDING_BRANCHING_COMPLETE $SID)"
check "M6-pre. detail is pending before --mark" \
  "pending" "$(read_state_status "$SID" "detail")"
run_next_step_rc --session "$SID" --mark detail complete
check_nonzero "M6. --mark detail complete w/o approval → nonzero exit" "$RC"
check "M6b. --mark detail complete w/o approval → state still detail=pending" \
  "pending" "$(read_state_status "$SID" "detail")"

echo ""
echo "=== M6c: --mark detail complete WITH a recorded approval → exit 0 + detail=complete (symmetric to M1c) ==="

SID="m6c-$$"
write_state "$SID" "$(DETAIL_PENDING_BRANCHING_COMPLETE $SID)"
seed_approval "$SID" detail
run_next_step_rc --session "$SID" --mark detail complete
check "M6c. --mark detail complete with approval → exit 0" "0" "$RC"
check "M6d. --mark detail complete with approval → state shows detail=complete" \
  "complete" "$(read_state_status "$SID" "detail")"
