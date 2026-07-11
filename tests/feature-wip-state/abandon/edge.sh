# ===========================================================================
# T-abandon-14: Missing <N> argument → validate_n path → exit 2, no gh mutations.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATE="OPEN"
mint_abandon_mock
run_with_timeout 60 bash "$TARGET" abandon >/dev/null 2>&1
RC=$?
HAS_ITEM_EDIT=0
grep -q -- "project item-edit" "$GH_MOCK_ARGS_LOG" 2>/dev/null && HAS_ITEM_EDIT=1
if [ "$RC" -eq 2 ] && [ "$HAS_ITEM_EDIT" -eq 0 ]; then
    pass "T-abandon-14: missing <N> → exit 2, no mutations"
else
    fail "T-abandon-14: rc=$RC item_edit=$HAS_ITEM_EDIT log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-abandon-15: Non-numeric <N> ("abc") → validate_n rejects → exit 2, no mutations.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATE="OPEN"
mint_abandon_mock
run_with_timeout 60 bash "$TARGET" abandon abc >/dev/null 2>&1
RC=$?
HAS_ITEM_EDIT=0
grep -q -- "project item-edit" "$GH_MOCK_ARGS_LOG" 2>/dev/null && HAS_ITEM_EDIT=1
if [ "$RC" -eq 2 ] && [ "$HAS_ITEM_EDIT" -eq 0 ]; then
    pass "T-abandon-15: non-numeric <N> → exit 2, no mutations"
else
    fail "T-abandon-15: rc=$RC item_edit=$HAS_ITEM_EDIT log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-abandon-16: Extra positional argument → arg parser rejects → exit 2, no mutations.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATE="OPEN"
mint_abandon_mock
run_with_timeout 60 bash "$TARGET" abandon 42 99 >/dev/null 2>&1
RC=$?
HAS_ITEM_EDIT=0
grep -q -- "project item-edit" "$GH_MOCK_ARGS_LOG" 2>/dev/null && HAS_ITEM_EDIT=1
if [ "$RC" -eq 2 ] && [ "$HAS_ITEM_EDIT" -eq 0 ]; then
    pass "T-abandon-16: extra positional argument → exit 2, no mutations"
else
    fail "T-abandon-16: rc=$RC item_edit=$HAS_ITEM_EDIT log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-abandon-17: Invalid --repo value with shell metacharacters ("../evil") →
# --repo validation rejects → exit 2, no gh calls. Guards against injection of a
# repo spec that does not match ^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)?$.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATE="OPEN"
mint_abandon_mock
run_with_timeout 60 bash "$TARGET" abandon 42 --repo "../evil" >/dev/null 2>&1
RC=$?
GH_CALLED=0
[ -s "$GH_MOCK_ARGS_LOG" ] && GH_CALLED=1
if [ "$RC" -eq 2 ] && [ "$GH_CALLED" -eq 0 ]; then
    pass "T-abandon-17: invalid --repo (shell metachar) → exit 2, no gh calls"
else
    fail "T-abandon-17: rc=$RC gh_called=$GH_CALLED log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-abandon-18: Issue number 0 (boundary — not a valid GitHub issue number) →
# validate_n rejects → exit 2, no mutations. GitHub issues start at 1.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATE="OPEN"
mint_abandon_mock
run_with_timeout 60 bash "$TARGET" abandon 0 >/dev/null 2>&1
RC=$?
HAS_ITEM_EDIT=0
grep -q -- "project item-edit" "$GH_MOCK_ARGS_LOG" 2>/dev/null && HAS_ITEM_EDIT=1
if [ "$RC" -eq 2 ] && [ "$HAS_ITEM_EDIT" -eq 0 ]; then
    pass "T-abandon-18: issue number 0 → exit 2, no mutations"
else
    fail "T-abandon-18: rc=$RC item_edit=$HAS_ITEM_EDIT log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-abandon-19: Negative issue number (-1) → validate_n rejects → exit 2,
# no mutations. Passed via -- separator to prevent flag-parser confusion.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATE="OPEN"
mint_abandon_mock
run_with_timeout 60 bash "$TARGET" abandon -- -1 >/dev/null 2>&1
RC=$?
HAS_ITEM_EDIT=0
grep -q -- "project item-edit" "$GH_MOCK_ARGS_LOG" 2>/dev/null && HAS_ITEM_EDIT=1
if [ "$RC" -eq 2 ] && [ "$HAS_ITEM_EDIT" -eq 0 ]; then
    pass "T-abandon-19: negative issue number → exit 2, no mutations"
else
    fail "T-abandon-19: rc=$RC item_edit=$HAS_ITEM_EDIT log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-abandon-20: Repeat-run idempotency — second call after first succeeded.
# Lock already deleted + fingerprint already empty (GH_MOCK_FP_NO_CHANGES=1).
# Status=Todo write still proceeds; overall exit should be 0.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATE="OPEN"
export GH_MOCK_FP_NO_CHANGES="1"
mint_abandon_mock
rm -f "$PLANS_DIR/wip-lock-42.md" 2>/dev/null || true
run_with_timeout 60 bash "$TARGET" abandon 42 >/dev/null 2>&1
RC=$?
HAS_TODO=$(grep -c -- "--single-select-option-id $WIP_STATE_TODO_OPTION_ID" "$GH_MOCK_ARGS_LOG" 2>/dev/null || echo 0)
if [ "$RC" -eq 0 ] && [ "$HAS_TODO" -ge 1 ]; then
    pass "T-abandon-20: repeat-run (lock absent + fp already empty) → exit 0, Status=Todo re-written"
else
    fail "T-abandon-20: rc=$RC todo=$HAS_TODO log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-abandon-21: Very large issue number (2147483647) — validate_n must not
# impose an upper-bound cap. The command should reach the gh mock and succeed.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATE="OPEN"
mint_abandon_mock
run_with_timeout 60 bash "$TARGET" abandon 2147483647 >/dev/null 2>&1
RC=$?
HAS_TODO=$(grep -c -- "--single-select-option-id $WIP_STATE_TODO_OPTION_ID" "$GH_MOCK_ARGS_LOG" 2>/dev/null || echo 0)
if [ "$RC" -eq 0 ] && [ "$HAS_TODO" -ge 1 ]; then
    pass "T-abandon-21: very large issue number → proceeds to gh calls, exit 0"
else
    fail "T-abandon-21: rc=$RC todo=$HAS_TODO log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-abandon-22: Lock deletion ordering — lock must exist during BOTH item-edit
# calls (Status=Todo write first, fingerprint clear second) and only be absent
# after the command returns. Uses a side-channel log to capture lock state at
# each gh call. Addresses: C2 (lock exists during writes) and C3 (status
# before fp in call order).
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATE="OPEN"
LOCK_ORDER_LOG="$TMP/lock-order-22.log"
LOCK_FILE_PATH_22="$PLANS_DIR/wip-lock-22.md"
export LOCK_ORDER_LOG LOCK_FILE_PATH_22
echo "stale lock" > "$LOCK_FILE_PATH_22"
cat > "$TMP/mock-bin/gh" <<'MOCK_EOF'
#!/bin/bash
ARGS="$*"
if [ -n "${GH_MOCK_ARGS_LOG:-}" ]; then
    printf '%s\n' "$ARGS" >> "$GH_MOCK_ARGS_LOG"
fi
case "$ARGS" in
  issue\ view\ *--json\ state*) echo "OPEN"; exit 0 ;;
  auth\ status*) echo "Token scopes: 'project', 'repo'"; exit 0 ;;
  repo\ view\ *) echo "nirecom/agents"; exit 0 ;;
  api\ graphql\ *projectsV2*)
    case "$ARGS" in
      *"| length"*) echo "1"; exit 0 ;;
      *) printf '{"id":"PVT_resolved","number":1,"ownerLogin":"nirecom"}\n'; exit 0 ;;
    esac ;;
  api\ graphql\ *) printf 'PVTI_existing\n'; exit 0 ;;
  project\ item-edit\ *--single-select-option-id*)
    LOCK_PRESENT=gone
    [ -f "${LOCK_FILE_PATH_22:-}" ] && LOCK_PRESENT=exists
    printf 'status:%s\n' "$LOCK_PRESENT" >> "${LOCK_ORDER_LOG:-/dev/null}"
    exit 0 ;;
  project\ item-edit\ *--text*)
    LOCK_PRESENT=gone
    [ -f "${LOCK_FILE_PATH_22:-}" ] && LOCK_PRESENT=exists
    printf 'fp:%s\n' "$LOCK_PRESENT" >> "${LOCK_ORDER_LOG:-/dev/null}"
    exit 0 ;;
  *) echo "MOCK GH: no match $ARGS" >&2; exit 2 ;;
esac
MOCK_EOF
chmod +x "$TMP/mock-bin/gh"
run_with_timeout 60 bash "$TARGET" abandon 22 >/dev/null 2>&1
RC=$?
STATUS_LOCK=$(grep '^status:' "$LOCK_ORDER_LOG" 2>/dev/null | head -1 | cut -d: -f2)
FP_LOCK=$(grep '^fp:' "$LOCK_ORDER_LOG" 2>/dev/null | head -1 | cut -d: -f2)
STATUS_FIRST=0
STATUS_LINE=$(grep -n '^status:' "$LOCK_ORDER_LOG" 2>/dev/null | head -1 | cut -d: -f1)
FP_LINE=$(grep -n '^fp:' "$LOCK_ORDER_LOG" 2>/dev/null | head -1 | cut -d: -f1)
[ -n "$STATUS_LINE" ] && [ -n "$FP_LINE" ] && [ "$STATUS_LINE" -lt "$FP_LINE" ] && STATUS_FIRST=1
LOCK_GONE_AFTER=0
[ ! -f "$LOCK_FILE_PATH_22" ] && LOCK_GONE_AFTER=1
rm -f "$LOCK_FILE_PATH_22" 2>/dev/null || true
if [ "$RC" -eq 0 ] && [ "$STATUS_LOCK" = "exists" ] && [ "$FP_LOCK" = "exists" ] && [ "$STATUS_FIRST" -eq 1 ] && [ "$LOCK_GONE_AFTER" -eq 1 ]; then
    pass "T-abandon-22: lock exists during both item-edit calls; status before fp; lock gone after"
else
    fail "T-abandon-22: rc=$RC status_lock=$STATUS_LOCK fp_lock=$FP_LOCK status_first=$STATUS_FIRST lock_gone_after=$LOCK_GONE_AFTER order_log=$(cat "$LOCK_ORDER_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-abandon-23: --repo with semicolon shell metachar ("owner/repo;touch-x") →
# --repo validation rejects → exit 2, no gh calls. Supplements T-abandon-17
# (path traversal) with OS command injection variant.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATE="OPEN"
mint_abandon_mock
run_with_timeout 60 bash "$TARGET" abandon 42 --repo "owner/repo;touch-x" >/dev/null 2>&1
RC=$?
GH_CALLED=0
[ -s "$GH_MOCK_ARGS_LOG" ] && GH_CALLED=1
if [ "$RC" -eq 2 ] && [ "$GH_CALLED" -eq 0 ]; then
    pass "T-abandon-23: --repo with semicolon injection → exit 2, no gh calls"
else
    fail "T-abandon-23: rc=$RC gh_called=$GH_CALLED log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# T-abandon-24: wip-state.sh usage string advertises 'abandon' verb
USAGE_OUT=$(run_with_timeout 60 bash "$TARGET" unknown-verb 2>&1 || true)
if printf '%s' "$USAGE_OUT" | grep -q "abandon"; then
    pass "T-abandon-24: wip-state.sh usage string advertises 'abandon' verb"
else
    fail "T-abandon-24: 'abandon' not found in usage output: $USAGE_OUT"
fi

# T-abandon-25: WIP_STATE_STATUS_FIELD_ID missing → preflight exit 2, no mutations, lock retained
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATE="OPEN"
mint_abandon_mock
export _ISSUE_CREATE_INTERNAL_OWNER="nirecom"
export _ISSUE_CREATE_INTERNAL_PROJECT_NUM="1"
export _ISSUE_CREATE_INTERNAL_PROJECT_ID="PVT_resolved"
export _ISSUE_CREATE_INTERNAL_STATUS_FIELD_ID=""
export _ISSUE_CREATE_INTERNAL_TODO_OPTION_ID="OPT_todo"
export _ISSUE_CREATE_INTERNAL_FINGERPRINT_FIELD_ID="PVTF_fp"
unset WIP_STATE_STATUS_FIELD_ID
LOCKFILE="$PLANS_DIR/wip-lock-42.md"
echo "stale lock" > "$LOCKFILE"
run_with_timeout 60 bash "$TARGET" abandon 42 >/dev/null 2>&1
RC=$?
HAS_ITEM_EDIT=0; grep -q -- "project item-edit" "$GH_MOCK_ARGS_LOG" 2>/dev/null && HAS_ITEM_EDIT=1
LOCK_RETAINED=0; [ -f "$LOCKFILE" ] && LOCK_RETAINED=1
unset _ISSUE_CREATE_INTERNAL_STATUS_FIELD_ID _ISSUE_CREATE_INTERNAL_TODO_OPTION_ID _ISSUE_CREATE_INTERNAL_FINGERPRINT_FIELD_ID
if [ "$RC" -eq 2 ] && [ "$HAS_ITEM_EDIT" -eq 0 ] && [ "$LOCK_RETAINED" -eq 1 ]; then
    pass "T-abandon-25: STATUS_FIELD_ID missing → preflight exit 2, no mutations, lock retained"
else
    fail "T-abandon-25: rc=$RC item_edit=$HAS_ITEM_EDIT lock_retained=$LOCK_RETAINED"
fi
teardown_mock
