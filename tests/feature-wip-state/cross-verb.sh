
# ===========================================================================
# Test 24: setup parses mock graphql, appends env vars; second invocation doesn't duplicate.
# ===========================================================================
setup_mock
ENV_FILE="$AGENTS_CONFIG_DIR/.env"
: > "$ENV_FILE"
run_with_timeout 60 bash "$TARGET" setup >/dev/null 2>&1
RC1=$?
COUNT1=$(grep -c "WIP_STATE_STATUS_FIELD_ID" "$ENV_FILE" 2>/dev/null || echo 0)
run_with_timeout 60 bash "$TARGET" setup >/dev/null 2>&1
RC2=$?
COUNT2=$(grep -c "WIP_STATE_STATUS_FIELD_ID" "$ENV_FILE" 2>/dev/null || echo 0)
if [ "$RC1" -eq 0 ] && [ "$RC2" -eq 0 ] && [ "$COUNT1" -ge 1 ] && [ "$COUNT2" -eq "$COUNT1" ]; then
    pass "T24: setup writes env vars + second invocation does not duplicate (count stable at $COUNT1)"
else
    fail "T24: rc1=$RC1 rc2=$RC2 count1=$COUNT1 count2=$COUNT2"
fi
teardown_mock

# ===========================================================================
# Test 25: fingerprint determinism: same (session-id, N) → same 8-char hex.
# This is verified indirectly through check matching — but we also assert the
# helper accepts a query and a repeated call yields the same fingerprint in
# the args log.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1
FP1=$(grep -- "--text " "$GH_MOCK_ARGS_LOG" 2>/dev/null | head -1 | sed -nE 's/.*--text ([0-9a-f]+).*/\1/p')
: > "$GH_MOCK_ARGS_LOG"
run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1
FP2=$(grep -- "--text " "$GH_MOCK_ARGS_LOG" 2>/dev/null | head -1 | sed -nE 's/.*--text ([0-9a-f]+).*/\1/p')
if [ -n "$FP1" ] && [ "$FP1" = "$FP2" ] && [ "${#FP1}" -eq 8 ]; then
    pass "T25: fingerprint determinism: same (sid,N) → same 8-char hex (fp=$FP1)"
else
    fail "T25: fp1='$FP1' fp2='$FP2' len(fp1)=${#FP1}"
fi
teardown_mock

# ===========================================================================
# Test 26: PLANS_DIR resolution honors WORKFLOW_PLANS_DIR override.
# bin/workflow-plans-dir in our stub prints $PLANS_DIR — override $PLANS_DIR.
# ===========================================================================
setup_mock
ALT_PLANS="$TMP/alternative-plans"
mkdir -p "$ALT_PLANS"
# Rewrite stub to use WORKFLOW_PLANS_DIR override.
cat > "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir" <<EOF
#!/bin/bash
echo "\${WORKFLOW_PLANS_DIR:-$PLANS_DIR}"
EOF
chmod +x "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir"
export WORKFLOW_PLANS_DIR="$ALT_PLANS"
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
# Short-circuit the resolver so it skips GraphQL. T26 tests lock-file path
# routing, not resolver behaviour; avoid a GraphQL call that the standard mock
# does not handle.
export _ISSUE_CREATE_INTERNAL_OWNER="nirecom"
export _ISSUE_CREATE_INTERNAL_PROJECT_NUM="1"
export _ISSUE_CREATE_INTERNAL_PROJECT_ID="PVT_mock"
run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1
if [ -f "$ALT_PLANS/wip-lock-42.md" ]; then
    pass "T26: PLANS_DIR resolution honors WORKFLOW_PLANS_DIR override"
else
    fail "T26: lock not written to override path $ALT_PLANS/wip-lock-42.md"
fi
unset WORKFLOW_PLANS_DIR
teardown_mock

# ===========================================================================
# Test 27: .env auto-source — preflight passes when var lives only in $AGENTS_CONFIG_DIR/.env.
# ===========================================================================
setup_mock
# Move STATUS_FIELD_ID from env into .env.
ORIG_STATUS="$WIP_STATE_STATUS_FIELD_ID"
unset WIP_STATE_STATUS_FIELD_ID
cat > "$AGENTS_CONFIG_DIR/.env" <<EOF
WIP_STATE_STATUS_FIELD_ID=$ORIG_STATUS
EOF
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then
    pass "T27: .env auto-source — preflight passes via $AGENTS_CONFIG_DIR/.env"
else
    fail "T27: expected exit 0 with .env-sourced var, got rc=$RC"
fi
teardown_mock

# ===========================================================================
# Test 28: .env missing → set still exits 2 via preflight (no spurious pre-preflight failure).
# ===========================================================================
setup_mock
# Wipe required env var; ensure no .env exists.
unset WIP_STATE_STATUS_FIELD_ID
rm -f "$AGENTS_CONFIG_DIR/.env" 2>/dev/null || true
run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 2 ]; then
    pass "T28: .env missing → preflight exit 2 (no spurious pre-preflight error)"
else
    fail "T28: expected exit 2, got rc=$RC"
fi
teardown_mock

# ===========================================================================
# Test 29: clear/setup without CLAUDE_ENV_FILE — both exit 0 (no session-id dep).
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
unset CLAUDE_ENV_FILE
run_with_timeout 60 bash "$TARGET" clear 42 >/dev/null 2>&1
RC_CLEAR=$?
run_with_timeout 60 bash "$TARGET" setup >/dev/null 2>&1
RC_SETUP=$?
if [ "$RC_CLEAR" -eq 0 ] && [ "$RC_SETUP" -eq 0 ]; then
    pass "T29: clear & setup without CLAUDE_ENV_FILE → exit 0"
else
    fail "T29: rc_clear=$RC_CLEAR rc_setup=$RC_SETUP"
fi
teardown_mock

# ===========================================================================
# Test 30: check <N> paginated fields — Status on page 1, fingerprint on page 2; aggregates correctly.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATUS="In Progress"
EXPECTED_FP=$(printf '%s:%s' "test-sid-fixture" "42" | sha256sum | cut -c1-8)
export GH_MOCK_FINGERPRINT="$EXPECTED_FP"
export GH_MOCK_PAGINATED_PAGES=1
OUT=$(run_with_timeout 60 bash "$TARGET" check 42 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "same" ]; then
    pass "T30: check <N> aggregates Status (p1) + fingerprint (p2) → 'same'"
else
    fail "T30: rc=$RC out='$OUT' expected 'same'"
fi
teardown_mock

# ===========================================================================
# Test 31: non-numeric <N> → exit 2, no shell injection (set/check/clear).
# ===========================================================================
setup_mock
RC_SET=0; RC_CHECK=0; RC_CLEAR=0
run_with_timeout 10 bash "$TARGET" set   "42; touch /tmp/T31_INJECT" >/dev/null 2>&1; RC_SET=$?
run_with_timeout 10 bash "$TARGET" check "42; touch /tmp/T31_INJECT" >/dev/null 2>&1; RC_CHECK=$?
run_with_timeout 10 bash "$TARGET" clear "42; touch /tmp/T31_INJECT" >/dev/null 2>&1; RC_CLEAR=$?
if [ "$RC_SET" -eq 2 ] && [ "$RC_CHECK" -eq 2 ] && [ "$RC_CLEAR" -eq 2 ] \
        && [ ! -f /tmp/T31_INJECT ]; then
    pass "T31: non-numeric N rejected (exit 2) across set/check/clear; no injection"
else
    fail "T31: rc_set=$RC_SET rc_check=$RC_CHECK rc_clear=$RC_CLEAR inject=$([ -f /tmp/T31_INJECT ] && echo yes || echo no)"
    rm -f /tmp/T31_INJECT 2>/dev/null
fi
teardown_mock
