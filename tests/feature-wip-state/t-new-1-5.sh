
# ===========================================================================
# #1340: the `setup` verb is DEPRECATED. It no longer discovers field/option
# IDs via createProjectV2Field mutations, no longer writes $AGENTS_CONFIG_DIR/.env,
# and always exits 0 after emitting deprecation warnings to stderr. Field IDs are
# resolved on demand by resolve-project.sh. The T-new-1..5 cases below now assert
# the deprecation contract instead of the retired discovery/mutation behavior.
# ===========================================================================

# ===========================================================================
# T-new-1: setup prints deprecation warnings, never mutates, never writes .env,
#          and (when a project resolves) reports the resolver-discovered IDs on
#          stdout. exit 0 unconditionally.
# ===========================================================================
setup_mock
ENV_FILE="$AGENTS_CONFIG_DIR/.env"
: > "$ENV_FILE"
# Ensure no .env WIP_STATE_* migration noise: setup must derive IDs from resolver.
unset WIP_STATE_STATUS_FIELD_ID WIP_STATE_IN_PROGRESS_OPTION_ID \
      WIP_STATE_DONE_OPTION_ID WIP_STATE_TODO_OPTION_ID WIP_STATE_FINGERPRINT_FIELD_ID
OUT=$(run_with_timeout 60 bash "$TARGET" setup 2>"$TMP/setup-err")
RC=$?
MUT_COUNT=$(grep -c "createProjectV2Field" "$GH_MOCK_ARGS_LOG" 2>/dev/null | head -1 || echo 0)
ENV_UNCHANGED=1
[ -s "$ENV_FILE" ] && ENV_UNCHANGED=0
WARN_DEPRECATED=0
grep -qi "deprecated" "$TMP/setup-err" 2>/dev/null && WARN_DEPRECATED=1
# Resolver populates the fingerprint field id from Query C (PVTF_fp) → stdout KV.
KV_HAS_FP=0
printf '%s' "$OUT" | grep -q "WIP_STATE_FINGERPRINT_FIELD_ID=PVTF_fp" && KV_HAS_FP=1
if [ "$RC" -eq 0 ] && [ "$MUT_COUNT" -eq 0 ] && [ "$ENV_UNCHANGED" -eq 1 ] \
   && [ "$WARN_DEPRECATED" -eq 1 ] && [ "$KV_HAS_FP" -eq 1 ]; then
    pass "T-new-1: setup deprecated — warn + exit 0, no mutation, no .env write, resolver IDs on stdout"
else
    fail "T-new-1: rc=$RC mut=$MUT_COUNT env_unchanged=$ENV_UNCHANGED warn=$WARN_DEPRECATED kv_fp=$KV_HAS_FP"
fi
teardown_mock

# ===========================================================================
# T-new-2: setup with missing project scope — soft warn-only scope check does not
#          abort. No mutation, no .env write, exit 0 (deprecated verb never fails
#          on scope). The scope warning is emitted but resolution still proceeds.
# ===========================================================================
setup_mock
export GH_MOCK_MISSING_PROJECT_SCOPE=1
run_with_timeout 60 bash "$TARGET" setup >/dev/null 2>&1
RC=$?
MUT_COUNT=$(grep -c "createProjectV2Field" "$GH_MOCK_ARGS_LOG" 2>/dev/null | head -1 || echo 0)
if [ "$RC" -eq 0 ] && [ "$MUT_COUNT" -eq 0 ]; then
    pass "T-new-2: setup with missing project scope → exit 0, no mutation (soft check)"
else
    fail "T-new-2: rc=$RC mut=$MUT_COUNT"
fi
teardown_mock

# ===========================================================================
# T-new-3: setup with no linked project (resolver miss) → still exit 0, no mutation.
#          The deprecated verb prints the deprecation notice and returns 0 even
#          when nothing resolves (no KV block emitted).
# ===========================================================================
setup_mock
export GH_MOCK_LINKED_COUNT=0
OUT=$(run_with_timeout 60 bash "$TARGET" setup 2>/dev/null)
RC=$?
MUT_COUNT=$(grep -c "createProjectV2Field" "$GH_MOCK_ARGS_LOG" 2>/dev/null | head -1 || echo 0)
KV_EMPTY=1
printf '%s' "$OUT" | grep -q "WIP_STATE_" && KV_EMPTY=0
if [ "$RC" -eq 0 ] && [ "$MUT_COUNT" -eq 0 ] && [ "$KV_EMPTY" -eq 1 ]; then
    pass "T-new-3: setup with no linked project → exit 0, no mutation, no KV block"
else
    fail "T-new-3: rc=$RC mut=$MUT_COUNT kv_empty=$KV_EMPTY"
fi
teardown_mock

# ===========================================================================
# T-new-4: idempotency — setup issues no mutation and no .env write on two
#          consecutive runs; .env stays empty (deprecated verb never persists).
# ===========================================================================
setup_mock
ENV_FILE="$AGENTS_CONFIG_DIR/.env"
: > "$ENV_FILE"
run_with_timeout 60 bash "$TARGET" setup >/dev/null 2>&1; RC1=$?
MUT1=$(grep -c "createProjectV2Field" "$GH_MOCK_ARGS_LOG" 2>/dev/null | head -1 || echo 0)
: > "$GH_MOCK_ARGS_LOG"
run_with_timeout 60 bash "$TARGET" setup >/dev/null 2>&1; RC2=$?
MUT2=$(grep -c "createProjectV2Field" "$GH_MOCK_ARGS_LOG" 2>/dev/null | head -1 || echo 0)
ENV_LINES=$(grep -c "WIP_STATE_FINGERPRINT_FIELD_ID=" "$ENV_FILE" 2>/dev/null | head -1 || echo 0)
if [ "$RC1" -eq 0 ] && [ "$RC2" -eq 0 ] && [ "$MUT1" -eq 0 ] && [ "$MUT2" -eq 0 ] && [ "$ENV_LINES" -eq 0 ]; then
    pass "T-new-4: setup idempotent — no mutation on either run, .env never written"
else
    fail "T-new-4: rc1=$RC1 rc2=$RC2 mut1=$MUT1 mut2=$MUT2 env_lines=$ENV_LINES"
fi
teardown_mock

# ===========================================================================
# T-new-5: setup never issues createProjectV2Field mutations — even when the
#          resolver reports a Status field but the fingerprint field also exists.
#          Discovery is read-only (resolve-project.sh); no writes to the project.
# ===========================================================================
setup_mock
run_with_timeout 60 bash "$TARGET" setup >/dev/null 2>&1
RC=$?
MUT_COUNT=$(grep -c "createProjectV2Field" "$GH_MOCK_ARGS_LOG" 2>/dev/null | head -1 || echo 0)
if [ "$RC" -eq 0 ] && [ "$MUT_COUNT" -eq 0 ]; then
    pass "T-new-5: setup issues zero createProjectV2Field mutations (read-only discovery)"
else
    fail "T-new-5: rc=$RC mut=$MUT_COUNT"
fi
teardown_mock
