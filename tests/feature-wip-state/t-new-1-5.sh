
# ===========================================================================
# T-new-1: setup auto-creates session-fingerprint field when missing; rediscovered id wins.
# ===========================================================================
setup_mock
ENV_FILE="$AGENTS_CONFIG_DIR/.env"
: > "$ENV_FILE"
export GH_MOCK_FP_DISCOVERY_COUNTER="$TMP/fp-disc-counter"
echo 0 > "$GH_MOCK_FP_DISCOVERY_COUNTER"
export GH_MOCK_FP_INITIALLY_MISSING=1
export GH_MOCK_FP_REDISCOVERED_ID="PVTF_fp_rediscovered"
export GH_MOCK_NEW_FIELD_ID="PVTF_fp_new"
run_with_timeout 60 bash "$TARGET" setup >/dev/null 2>&1
RC=$?
MUT_COUNT=$(grep -c "createProjectV2Field" "$GH_MOCK_ARGS_LOG" 2>/dev/null | head -1 || echo 0)
FP_DISC_COUNT=$(grep -c 'session-fingerprint' "$GH_MOCK_ARGS_LOG" 2>/dev/null | head -1 || echo 0)
ENV_HAS_REDISCOVERED=0
grep -q "WIP_STATE_FINGERPRINT_FIELD_ID=PVTF_fp_rediscovered" "$ENV_FILE" 2>/dev/null && ENV_HAS_REDISCOVERED=1
ENV_HAS_MUTATION_ID=0
grep -q "WIP_STATE_FINGERPRINT_FIELD_ID=PVTF_fp_new" "$ENV_FILE" 2>/dev/null && ENV_HAS_MUTATION_ID=1
if [ "$RC" -eq 0 ] && [ "$MUT_COUNT" -eq 1 ] && [ "$FP_DISC_COUNT" -ge 2 ] \
   && [ "$ENV_HAS_REDISCOVERED" -eq 1 ] && [ "$ENV_HAS_MUTATION_ID" -eq 0 ]; then
    pass "T-new-1: auto-create + rediscovery — mutation id ignored, rediscovered id wins"
else
    fail "T-new-1: rc=$RC mut=$MUT_COUNT fp_disc=$FP_DISC_COUNT redisc=$ENV_HAS_REDISCOVERED muthit=$ENV_HAS_MUTATION_ID"
fi
teardown_mock

# ===========================================================================
# T-new-2: missing project scope with missing field → exit 1, no mutation.
# ===========================================================================
setup_mock
export GH_MOCK_MISSING_PROJECT_SCOPE=1
export GH_MOCK_FP_DISCOVERY_COUNTER="$TMP/fp-disc-counter"
echo 0 > "$GH_MOCK_FP_DISCOVERY_COUNTER"
export GH_MOCK_FP_INITIALLY_MISSING=1
run_with_timeout 60 bash "$TARGET" setup >/dev/null 2>&1
RC=$?
MUT_COUNT=$(grep -c "createProjectV2Field" "$GH_MOCK_ARGS_LOG" 2>/dev/null | head -1 || echo 0)
if [ "$RC" -eq 1 ] && [ "$MUT_COUNT" -eq 0 ]; then
    pass "T-new-2: missing project scope + missing field → exit 1, no mutation"
else
    fail "T-new-2: rc=$RC mut=$MUT_COUNT"
fi
teardown_mock

# ===========================================================================
# T-new-3: mutation failure and rediscovery empty → exit 1.
# ===========================================================================
setup_mock
export GH_MOCK_FP_DISCOVERY_COUNTER="$TMP/fp-disc-counter"
echo 0 > "$GH_MOCK_FP_DISCOVERY_COUNTER"
export GH_MOCK_FP_INITIALLY_MISSING=1
export GH_MOCK_FAIL="create-field"
export GH_MOCK_FP_REDISCOVERED_ID=""
run_with_timeout 60 bash "$TARGET" setup >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 1 ]; then
    pass "T-new-3: mutation fail + rediscovery empty → exit 1"
else
    fail "T-new-3: rc=$RC"
fi
teardown_mock

# ===========================================================================
# T-new-4: idempotency — field exists, no mutation issued on two consecutive runs.
# ===========================================================================
setup_mock
ENV_FILE="$AGENTS_CONFIG_DIR/.env"
: > "$ENV_FILE"
run_with_timeout 60 bash "$TARGET" setup >/dev/null 2>&1; RC1=$?
MUT1=$(grep -c "createProjectV2Field" "$GH_MOCK_ARGS_LOG" 2>/dev/null | head -1 || echo 0)
: > "$GH_MOCK_ARGS_LOG"
run_with_timeout 60 bash "$TARGET" setup >/dev/null 2>&1; RC2=$?
MUT2=$(grep -c "createProjectV2Field" "$GH_MOCK_ARGS_LOG" 2>/dev/null | head -1 || echo 0)
LINES=$(grep -c "WIP_STATE_FINGERPRINT_FIELD_ID=" "$ENV_FILE" 2>/dev/null | head -1 || echo 0)
if [ "$RC1" -eq 0 ] && [ "$RC2" -eq 0 ] && [ "$MUT1" -eq 0 ] && [ "$MUT2" -eq 0 ] && [ "$LINES" -eq 1 ]; then
    pass "T-new-4: field already exists — no mutation on either run, .env single line"
else
    fail "T-new-4: rc1=$RC1 rc2=$RC2 mut1=$MUT1 mut2=$MUT2 lines=$LINES"
fi
teardown_mock

# ===========================================================================
# T-new-5: scope gate fires unconditionally — even when field already exists.
# ===========================================================================
setup_mock
export GH_MOCK_MISSING_PROJECT_SCOPE=1
run_with_timeout 60 bash "$TARGET" setup >/dev/null 2>&1
RC=$?
MUT_COUNT=$(grep -c "createProjectV2Field" "$GH_MOCK_ARGS_LOG" 2>/dev/null | head -1 || echo 0)
DISCOVERY_COUNT=$(grep -c "api graphql" "$GH_MOCK_ARGS_LOG" 2>/dev/null | head -1 || echo 0)
if [ "$RC" -eq 1 ] && [ "$MUT_COUNT" -eq 0 ] && [ "$DISCOVERY_COUNT" -eq 0 ]; then
    pass "T-new-5: scope gate fires even when field exists — no graphql, no mutation"
else
    fail "T-new-5: rc=$RC mut=$MUT_COUNT discovery=$DISCOVERY_COUNT"
fi
teardown_mock
