
# ===========================================================================
# Test 1: set <N> calls gh project item-edit with --single-select-option-id $WIP_STATE_IN_PROGRESS_OPTION_ID
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ] && grep -q -- "--single-select-option-id $WIP_STATE_IN_PROGRESS_OPTION_ID" "$GH_MOCK_ARGS_LOG" 2>/dev/null; then
    pass "T1: set <N> calls project item-edit with IN_PROGRESS option"
else
    fail "T1: rc=$RC log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# Test 2: set <N> writes $PLANS_DIR/wip-lock-<N>.md with three lines
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1
LOCKFILE="$PLANS_DIR/wip-lock-42.md"
if [ -f "$LOCKFILE" ]; then
    LINES=$(wc -l < "$LOCKFILE" 2>/dev/null | tr -d ' ')
    # Three lines could be 3 lines or 2 newlines depending on trailing newline.
    if [ "$LINES" = "3" ] || [ "$LINES" = "2" ]; then
        if grep -q "42" "$LOCKFILE" && grep -q "test-sid-fixture" "$LOCKFILE"; then
            pass "T2: set <N> writes wip-lock-<N>.md with three lines (issue+session+started)"
        else
            fail "T2: lock file content missing issue or session-id: $(cat "$LOCKFILE")"
        fi
    else
        fail "T2: lock file has $LINES lines, expected 3: $(cat "$LOCKFILE")"
    fi
else
    fail "T2: lock file not written at $LOCKFILE"
fi
teardown_mock

# ===========================================================================
# Test 3: set <N> with missing WIP_STATE_STATUS_FIELD_ID exits 2
# ===========================================================================
setup_mock
unset WIP_STATE_STATUS_FIELD_ID
# Also ensure .env doesn't auto-source it back.
run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 2 ]; then
    pass "T3: set <N> with missing WIP_STATE_STATUS_FIELD_ID → exit 2"
else
    fail "T3: expected exit 2, got rc=$RC"
fi
teardown_mock

# ===========================================================================
# Test 4: set <N> with missing WIP_STATE_FINGERPRINT_FIELD_ID exits 2 (required)
# ===========================================================================
setup_mock
unset WIP_STATE_FINGERPRINT_FIELD_ID
run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 2 ]; then
    pass "T4: set <N> with missing WIP_STATE_FINGERPRINT_FIELD_ID → exit 2"
else
    fail "T4: expected exit 2, got rc=$RC"
fi
teardown_mock

# ===========================================================================
# Test 5: set <N> with missing/unextractable CLAUDE_SESSION_ID exits 2
# ===========================================================================
setup_mock
echo "" > "$CLAUDE_ENV_FILE"  # no CLAUDE_SESSION_ID
run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 2 ]; then
    pass "T5: set <N> with missing CLAUDE_SESSION_ID → exit 2"
else
    fail "T5: expected exit 2, got rc=$RC"
fi
teardown_mock

# ===========================================================================
# Test 6: ORDERING INVARIANT — set <N> writes fingerprint BEFORE Status
# Verified via $GH_MOCK_ARGS_LOG line order.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1
# Find first item-edit-with-text line number (fingerprint write).
FP_LINE=$(grep -n -- "--text" "$GH_MOCK_ARGS_LOG" 2>/dev/null | grep "item-edit" | head -1 | cut -d: -f1)
STATUS_LINE=$(grep -n -- "--single-select-option-id" "$GH_MOCK_ARGS_LOG" 2>/dev/null | grep "item-edit" | head -1 | cut -d: -f1)
if [ -n "$FP_LINE" ] && [ -n "$STATUS_LINE" ] && [ "$FP_LINE" -lt "$STATUS_LINE" ]; then
    pass "T6: ORDERING — fingerprint write (line $FP_LINE) precedes Status set (line $STATUS_LINE)"
else
    fail "T6: ordering violated (fp_line=$FP_LINE status_line=$STATUS_LINE) log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# Test 7: set <N> with fingerprint-write mock failing → exit 1; Status-set NOT called.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_FAIL="item-edit-fp"
run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 1 ] && ! grep -q -- "--single-select-option-id" "$GH_MOCK_ARGS_LOG" 2>/dev/null; then
    pass "T7: fingerprint-write fail → exit 1, Status-set NOT called"
else
    fail "T7: rc=$RC log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# Test 8: set <N> with Status-set mock failing → exit 1; fingerprint already written.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_FAIL="item-edit-status"
run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 1 ] && grep -q -- "--text" "$GH_MOCK_ARGS_LOG" 2>/dev/null; then
    pass "T8: Status-set fail → exit 1, fingerprint already written"
else
    fail "T8: rc=$RC log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# Test 9: set <N> with lock-write failure (read-only $PLANS_DIR) exits 0 (warn-and-continue)
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
chmod 555 "$PLANS_DIR" 2>/dev/null || true
run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1
RC=$?
chmod 755 "$PLANS_DIR" 2>/dev/null || true
# Read-only enforcement is unreliable on Windows/MSYS; accept either exit 0
# (warn-and-continue on lock failure) or exit 0 because lock write actually
# succeeded — the test's invariant is "lock failure must not be fatal".
if [ "$RC" -eq 0 ]; then
    pass "T9: lock-write fail → exit 0 (warn-and-continue)"
else
    fail "T9: lock-write fail should not fail helper; rc=$RC"
fi
teardown_mock

# ===========================================================================
# Test 10: set <N> on item not in project — resolves URL via gh issue view, calls item-add.
# ===========================================================================
setup_mock
# GH_MOCK_PROJECT_ITEM_ID unset → graphql returns empty nodes → triggers item-add path.
export GH_MOCK_ITEM_ADD_ID="PVTI_newly_added"
run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ] \
   && grep -q "issue view.*--json url" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
   && grep -q "project item-add" "$GH_MOCK_ARGS_LOG" 2>/dev/null; then
    pass "T10: item not in project → URL resolve + item-add called"
else
    fail "T10: rc=$RC log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# Test 11: set <N> where item-add fails but refetch succeeds (duplicate-add race).
# ===========================================================================
setup_mock
# First resolve_item_id returns empty; item-add fails; refetch returns id.
# We approximate by: item-add fails, then a second graphql call returns a real id.
# Mock cannot easily switch state mid-run; simulate by using a counter file.
COUNTER="$TMP/resolve-counter"
echo 0 > "$COUNTER"
# Replace the mock to count graphql resolve calls.
cat > "$TMP/mock-bin/gh" <<'MOCK_EOF'
#!/bin/bash
ARGS="$*"
if [ -n "${GH_MOCK_ARGS_LOG:-}" ]; then
    printf '%s\n' "$ARGS" >> "$GH_MOCK_ARGS_LOG"
fi
case "$ARGS" in
  auth\ status*)
    echo "Token scopes: 'project', 'repo'"; exit 0 ;;
  repo\ view\ *--json\ owner,name*|repo\ view\ *)
    echo "${GH_MOCK_OWNER_REPO:-nirecom/agents}"; exit 0 ;;
  api\ graphql\ *projectItems*)
    # Counter-driven: first call empty, second returns refetched id.
    N=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
    N=$((N + 1)); echo "$N" > "$COUNTER_FILE"
    if [ "$N" -le 1 ]; then
        echo ""
    else
        echo "${GH_MOCK_REFETCH_ITEM_ID:-PVTI_refetched}"
    fi
    exit 0
    ;;
  api\ graphql\ *)
    echo ""; exit 0 ;;
  project\ item-add\ *)
    echo "error: duplicate add race" >&2; exit 1 ;;
  project\ item-edit\ *)
    exit 0 ;;
  issue\ view\ *--json\ url*)
    echo "${GH_MOCK_ISSUE_URL:-https://github.com/nirecom/agents/issues/42}"; exit 0 ;;
  issue\ view\ *)
    echo "${GH_MOCK_ISSUE_URL:-https://github.com/nirecom/agents/issues/42}"; exit 0 ;;
  *)
    echo "MOCK GH: no match $ARGS" >&2; exit 2 ;;
esac
MOCK_EOF
chmod +x "$TMP/mock-bin/gh"
export COUNTER_FILE="$COUNTER"
run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then
    pass "T11: item-add fail + refetch succeeds → exit 0 (duplicate-add race)"
else
    fail "T11: expected exit 0 with refetch recovery, got rc=$RC log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# Test 12: set <N> where item-add fails AND refetch empty → exit 1.
# ===========================================================================
setup_mock
# Reuse default mock; ensure resolve_item_id stays empty AND item-add fails.
export GH_MOCK_FAIL="item-add"
run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 1 ]; then
    pass "T12: item-add fail + refetch empty → exit 1"
else
    fail "T12: expected exit 1, got rc=$RC"
fi
teardown_mock

# ===========================================================================
# Test 13: set <N> where gh issue view URL resolution fails → exit 1.
# ===========================================================================
setup_mock
# Empty PROJECT_ITEM_ID → triggers URL resolve; force issue-view failure.
export GH_MOCK_FAIL="issue-view"
run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 1 ]; then
    pass "T13: gh issue view URL resolve fail → exit 1"
else
    fail "T13: expected exit 1, got rc=$RC"
fi
teardown_mock
