
# ===========================================================================
# Test 14: check <N> returns "same" on matching fingerprint with "In Progress".
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATUS="In Progress"
# Compute expected fingerprint locally (sha256(sid:N)[:8]).
EXPECTED_FP=$(printf '%s:%s' "test-sid-fixture" "42" | sha256sum | cut -c1-8)
export GH_MOCK_FINGERPRINT="$EXPECTED_FP"
OUT=$(run_with_timeout 60 bash "$TARGET" check 42 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "same" ]; then
    pass "T14: check <N> with matching fingerprint + In Progress → 'same'"
else
    fail "T14: rc=$RC out='$OUT' expected_fp=$EXPECTED_FP"
fi
teardown_mock

# ===========================================================================
# Test 15: check <N> returns "other" on fingerprint mismatch with "In Progress".
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATUS="In Progress"
export GH_MOCK_FINGERPRINT="deadbeef"  # not matching test-sid-fixture:42
OUT=$(run_with_timeout 60 bash "$TARGET" check 42 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "other" ]; then
    pass "T15: check <N> with mismatched fingerprint → 'other'"
else
    fail "T15: rc=$RC out='$OUT'"
fi
teardown_mock

# ===========================================================================
# Test 16: check <N> returns "none" when item not found in project.
# ===========================================================================
setup_mock
# GH_MOCK_PROJECT_ITEM_ID unset → resolve_item_id returns empty.
OUT=$(run_with_timeout 60 bash "$TARGET" check 42 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "none" ]; then
    pass "T16: check <N> with item not in project → 'none'"
else
    fail "T16: rc=$RC out='$OUT'"
fi
teardown_mock

# ===========================================================================
# Test 17: check <N> returns "none" when status ≠ "In Progress".
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATUS="Todo"
export GH_MOCK_FINGERPRINT="deadbeef"
OUT=$(run_with_timeout 60 bash "$TARGET" check 42 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "none" ]; then
    pass "T17: check <N> with status=Todo → 'none'"
else
    fail "T17: rc=$RC out='$OUT'"
fi
teardown_mock

# ===========================================================================
# Test 18: check <N> on gh graphql failure → exit 1, stdout empty.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_FAIL="graphql"
OUT=$(run_with_timeout 60 bash "$TARGET" check 42 2>/dev/null)
RC=$?
if [ "$RC" -eq 1 ] && [ -z "$OUT" ]; then
    pass "T18: check <N> graphql fail → exit 1, stdout empty"
else
    fail "T18: rc=$RC out='$OUT'"
fi
teardown_mock

# ===========================================================================
# Test 19: check <N> with missing session-id → exit 2.
# ===========================================================================
setup_mock
echo "" > "$CLAUDE_ENV_FILE"
OUT=$(run_with_timeout 60 bash "$TARGET" check 42 2>/dev/null)
RC=$?
if [ "$RC" -eq 2 ]; then
    pass "T19: check <N> with missing CLAUDE_SESSION_ID → exit 2"
else
    fail "T19: expected exit 2, got rc=$RC"
fi
teardown_mock

# ===========================================================================
# Test 20: check <N> graphql query references $WIP_STATE_STATUS_FIELD_ID and $WIP_STATE_FINGERPRINT_FIELD_ID.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATUS="In Progress"
EXPECTED_FP=$(printf '%s:%s' "test-sid-fixture" "42" | sha256sum | cut -c1-8)
export GH_MOCK_FINGERPRINT="$EXPECTED_FP"
run_with_timeout 60 bash "$TARGET" check 42 >/dev/null 2>&1
# Look for both field IDs anywhere in the args log of the graphql calls.
if grep -q "$WIP_STATE_STATUS_FIELD_ID" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
   && grep -q "$WIP_STATE_FINGERPRINT_FIELD_ID" "$GH_MOCK_ARGS_LOG" 2>/dev/null; then
    pass "T20: check <N> graphql references both WIP_STATE_*_FIELD_ID env vars (ID-based filter)"
else
    fail "T20: expected both field IDs in gh args log; log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null | head -20)"
fi
teardown_mock
