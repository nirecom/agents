# T-abandon-26: WIP_STATE_FINGERPRINT_FIELD_ID missing → preflight exit 2, no mutations, lock retained
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATE="OPEN"
mint_abandon_mock
export _ISSUE_CREATE_INTERNAL_OWNER="nirecom"
export _ISSUE_CREATE_INTERNAL_PROJECT_NUM="1"
export _ISSUE_CREATE_INTERNAL_PROJECT_ID="PVT_resolved"
export _ISSUE_CREATE_INTERNAL_STATUS_FIELD_ID="PVTSSF_status"
export _ISSUE_CREATE_INTERNAL_TODO_OPTION_ID="OPT_todo"
export _ISSUE_CREATE_INTERNAL_FINGERPRINT_FIELD_ID=""
unset WIP_STATE_FINGERPRINT_FIELD_ID
LOCKFILE="$PLANS_DIR/wip-lock-42.md"
echo "stale lock" > "$LOCKFILE"
run_with_timeout 60 bash "$TARGET" abandon 42 >/dev/null 2>&1
RC=$?
HAS_ITEM_EDIT=0; grep -q -- "project item-edit" "$GH_MOCK_ARGS_LOG" 2>/dev/null && HAS_ITEM_EDIT=1
LOCK_RETAINED=0; [ -f "$LOCKFILE" ] && LOCK_RETAINED=1
unset _ISSUE_CREATE_INTERNAL_STATUS_FIELD_ID _ISSUE_CREATE_INTERNAL_TODO_OPTION_ID _ISSUE_CREATE_INTERNAL_FINGERPRINT_FIELD_ID
if [ "$RC" -eq 2 ] && [ "$HAS_ITEM_EDIT" -eq 0 ] && [ "$LOCK_RETAINED" -eq 1 ]; then
    pass "T-abandon-26: FINGERPRINT_FIELD_ID missing → preflight exit 2, no mutations, lock retained"
else
    fail "T-abandon-26: rc=$RC item_edit=$HAS_ITEM_EDIT lock_retained=$LOCK_RETAINED"
fi
teardown_mock

# T-abandon-27: --repo=owner/repo (equals form) → valid, propagated to issue-state-check
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATE="OPEN"
export GH_MOCK_OWNER_REPO="nirecom/otherone"
mint_abandon_mock
run_with_timeout 60 bash "$TARGET" abandon 42 --repo=nirecom/otherone >/dev/null 2>&1
RC=$?
STATE_CHECK_HAS_REPO=$(grep -cE -- "issue view 42 .*--repo nirecom/otherone.*--json state" "$GH_MOCK_ARGS_LOG" 2>/dev/null || echo 0)
if [ "$RC" -eq 0 ] && [ "$STATE_CHECK_HAS_REPO" -ge 1 ]; then
    pass "T-abandon-27: --repo=owner/repo (equals form) → valid, propagated"
else
    fail "T-abandon-27: rc=$RC state_check_has_repo=$STATE_CHECK_HAS_REPO"
fi
teardown_mock

# T-abandon-28: --repo= (empty via equals form) → exit 2, no gh calls
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATE="OPEN"
mint_abandon_mock
run_with_timeout 60 bash "$TARGET" abandon 42 --repo= >/dev/null 2>&1
RC=$?
GH_CALLED=0; [ -s "$GH_MOCK_ARGS_LOG" ] && GH_CALLED=1
if [ "$RC" -eq 2 ] && [ "$GH_CALLED" -eq 0 ]; then
    pass "T-abandon-28: --repo= empty → exit 2, no gh calls"
else
    fail "T-abandon-28: rc=$RC gh_called=$GH_CALLED"
fi
teardown_mock

# T-abandon-29: <N> with shell metacharacters ("42;touch-x") → validate_n rejects → exit 2, no gh calls, no injection
setup_mock; export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"; export GH_MOCK_STATE="OPEN"; mint_abandon_mock
INJECT_FILE="$TMP/t29-inject"
run_with_timeout 60 bash "$TARGET" abandon "42;touch $INJECT_FILE" >/dev/null 2>&1; RC=$?
GH_CALLED=0; [ -s "$GH_MOCK_ARGS_LOG" ] && GH_CALLED=1
INJECTED=0; [ -f "$INJECT_FILE" ] && INJECTED=1
if [ "$RC" -eq 2 ] && [ "$GH_CALLED" -eq 0 ] && [ "$INJECTED" -eq 0 ]; then
    pass "T-abandon-29: <N> shell metachar → exit 2, no gh calls, no injection"
else
    fail "T-abandon-29: rc=$RC gh_called=$GH_CALLED injected=$INJECTED"
fi
teardown_mock

# T-abandon-30: clear OPEN guard regression — after abandon dispatch added, clear still exits 0 on OPEN issues (no board mutations)
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
cat > "$TMP/mock-bin/gh" <<'MOCK_EOF'
#!/bin/bash
ARGS="$*"
if [ -n "${GH_MOCK_ARGS_LOG:-}" ]; then printf '%s\n' "$ARGS" >> "$GH_MOCK_ARGS_LOG"; fi
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
  project\ item-edit\ *) echo "MOCK: item-edit should not be called for OPEN clear" >&2; exit 1 ;;
  *) echo "MOCK GH: no match $ARGS" >&2; exit 2 ;;
esac
MOCK_EOF
chmod +x "$TMP/mock-bin/gh"
LOCKFILE="$PLANS_DIR/wip-lock-42.md"
echo "stale lock" > "$LOCKFILE"
run_with_timeout 60 bash "$TARGET" clear 42 >/dev/null 2>&1
RC=$?
HAS_ITEM_EDIT=0; grep -q -- "project item-edit" "$GH_MOCK_ARGS_LOG" 2>/dev/null && HAS_ITEM_EDIT=1
LOCK_DELETED=0; [ ! -f "$LOCKFILE" ] && LOCK_DELETED=1
if [ "$RC" -eq 0 ] && [ "$HAS_ITEM_EDIT" -eq 0 ] && [ "$LOCK_DELETED" -eq 1 ]; then
    pass "T-abandon-30: clear OPEN guard (regression) → exit 0, no board mutations, lock deleted"
else
    fail "T-abandon-30: rc=$RC item_edit=$HAS_ITEM_EDIT lock_deleted=$LOCK_DELETED"
fi
teardown_mock

# T-abandon-31: dispatch allowlist — clear and abandon both reject --session-id (regression after dispatch change)
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
mint_abandon_mock
ALL_PASS_31=1
for _V in clear abandon; do
    run_with_timeout 30 bash "$TARGET" "$_V" 42 --session-id test-sid >/dev/null 2>&1
    _RC=$?
    [ "$_RC" -ne 2 ] && ALL_PASS_31=0
done
if [ "$ALL_PASS_31" -eq 1 ]; then
    pass "T-abandon-31: clear and abandon both reject --session-id → exit 2 (dispatch regression)"
else
    fail "T-abandon-31: a close-type verb did not reject --session-id"
fi
teardown_mock

# T-abandon-32: WORKFLOW_PLANS_DIR with spaces → abandon correctly deletes lock, exit 0
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATE="OPEN"
mint_abandon_mock
SPACE_PLANS="$TMP/plans with spaces"
mkdir -p "$SPACE_PLANS"
export WORKFLOW_PLANS_DIR="$SPACE_PLANS"
cat > "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir" <<WPDEOF
#!/bin/bash
echo "\${WORKFLOW_PLANS_DIR:-$PLANS_DIR}"
WPDEOF
chmod +x "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir"
LOCKFILE_32="$SPACE_PLANS/wip-lock-42.md"
echo "stale lock" > "$LOCKFILE_32"
run_with_timeout 60 bash "$TARGET" abandon 42 >/dev/null 2>&1
RC=$?
LOCK_DELETED_32=0; [ ! -f "$LOCKFILE_32" ] && LOCK_DELETED_32=1
unset WORKFLOW_PLANS_DIR
if [ "$RC" -eq 0 ] && [ "$LOCK_DELETED_32" -eq 1 ]; then
    pass "T-abandon-32: WORKFLOW_PLANS_DIR with spaces → lock deleted, exit 0"
else
    fail "T-abandon-32: rc=$RC lock_deleted=$LOCK_DELETED_32"
fi
teardown_mock

# T-abandon-33: gh auth status missing project scope → warning emitted, command still succeeds (soft check)
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATE="OPEN"
export GH_MOCK_MISSING_PROJECT_SCOPE="1"
mint_abandon_mock
LOCKFILE="$PLANS_DIR/wip-lock-42.md"
echo "stale lock" > "$LOCKFILE"
STDERR_T33="$TMP/abandon-t33-stderr.log"
run_with_timeout 60 bash "$TARGET" abandon 42 >/dev/null 2>"$STDERR_T33"
RC=$?
HAS_ITEM_EDIT=0; grep -q -- "project item-edit" "$GH_MOCK_ARGS_LOG" 2>/dev/null && HAS_ITEM_EDIT=1
WARN_SHOWN=0; grep -q "gh auth lacks 'project' scope" "$STDERR_T33" 2>/dev/null && WARN_SHOWN=1
if [ "$RC" -eq 0 ] && [ "$HAS_ITEM_EDIT" -ge 1 ] && [ "$WARN_SHOWN" -eq 1 ]; then
    pass "T-abandon-33: gh auth status missing project scope → warning only, command succeeds"
else
    fail "T-abandon-33: rc=$RC item_edit=$HAS_ITEM_EDIT warn_shown=$WARN_SHOWN"
fi
teardown_mock

# T-abandon-34: bare --repo flag with no following value → exit 2, no gh calls
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATE="OPEN"
mint_abandon_mock
run_with_timeout 60 bash "$TARGET" abandon 42 --repo >/dev/null 2>&1
RC=$?
GH_CALLED=0; [ -s "$GH_MOCK_ARGS_LOG" ] && GH_CALLED=1
if [ "$RC" -eq 2 ] && [ "$GH_CALLED" -eq 0 ]; then
    pass "T-abandon-34: bare --repo with no value → exit 2, no gh calls"
else
    fail "T-abandon-34: rc=$RC gh_called=$GH_CALLED log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# T-abandon-35: unknown flag (--unknown-flag) → exit 2, no gh calls
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATE="OPEN"
mint_abandon_mock
run_with_timeout 60 bash "$TARGET" abandon 42 --unknown-flag >/dev/null 2>&1
RC=$?
GH_CALLED=0; [ -s "$GH_MOCK_ARGS_LOG" ] && GH_CALLED=1
if [ "$RC" -eq 2 ] && [ "$GH_CALLED" -eq 0 ]; then
    pass "T-abandon-35: unknown flag → exit 2, no gh calls"
else
    fail "T-abandon-35: rc=$RC gh_called=$GH_CALLED log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# T-abandon-36: minimum valid issue number (N=1) → accepted, gh calls made, exit 0
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATE="OPEN"
mint_abandon_mock
run_with_timeout 60 bash "$TARGET" abandon 1 >/dev/null 2>&1
RC=$?
GH_CALLED=0; [ -s "$GH_MOCK_ARGS_LOG" ] && GH_CALLED=1
if [ "$RC" -eq 0 ] && [ "$GH_CALLED" -eq 1 ]; then
    pass "T-abandon-36: minimum valid N=1 → accepted, gh calls made, exit 0"
else
    fail "T-abandon-36: rc=$RC gh_called=$GH_CALLED"
fi
teardown_mock

# T-abandon-37: argument validation matrix (table-driven) — validate_n and --repo boundaries
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATE="OPEN"
mint_abandon_mock
TABLE_PASS_37=1
while IFS='|' read -r TNAME _N _REPO WANT_RC; do
    _ARGS=()
    [ "$_N" != "(none)" ] && _ARGS+=("$_N")
    [ "$_REPO" != "(none)" ] && _ARGS+=("--repo" "$_REPO")
    run_with_timeout 30 bash "$TARGET" abandon "${_ARGS[@]}" >/dev/null 2>&1
    _GOT=$?
    [ "$_GOT" != "$WANT_RC" ] && { TABLE_PASS_37=0; printf '  FAIL subtable %s: N=%s repo=%s want=%s got=%s\n' "$TNAME" "$_N" "$_REPO" "$WANT_RC" "$_GOT" >&2; }
done << 'ARGMATRIX'
missing_N|(none)|(none)|2
N_abc|abc|(none)|2
N_zero|0|(none)|2
N_negative|-1|(none)|2
N_float|1.5|(none)|2
repo_traversal|42|../evil|2
repo_semicolon|42|owner/repo;x|2
N_one|1|(none)|0
N_large|2147483647|(none)|0
ARGMATRIX
if [ "$TABLE_PASS_37" -eq 1 ]; then
    pass "T-abandon-37: argument validation matrix (9 entries) — all entries matched expected exit codes"
else
    fail "T-abandon-37: one or more table entries failed (see stderr above)"
fi
teardown_mock

# T-abandon-38: item-edit argument assertions — status uses STATUS_FIELD_ID+TODO_OPTION_ID; fp uses FINGERPRINT_FIELD_ID+item-id
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATE="OPEN"
mint_abandon_mock
run_with_timeout 60 bash "$TARGET" abandon 42 >/dev/null 2>&1
RC=$?
STATUS_EDIT=$(grep "single-select-option-id" "$GH_MOCK_ARGS_LOG" 2>/dev/null | head -1)
FP_EDIT=$(grep -- "--text" "$GH_MOCK_ARGS_LOG" 2>/dev/null | head -1)
HAS_TODO_OPT=0; echo "$STATUS_EDIT" | grep -q "OPT_todo" && HAS_TODO_OPT=1
HAS_STATUS_FIELD=0; echo "$STATUS_EDIT" | grep -q "PVTSSF_status" && HAS_STATUS_FIELD=1
HAS_FP_FIELD=0; echo "$FP_EDIT" | grep -q "PVTF_fp" && HAS_FP_FIELD=1
HAS_ITEM_ID_STATUS=0; echo "$STATUS_EDIT" | grep -q "PVTI_existing" && HAS_ITEM_ID_STATUS=1
if [ "$RC" -eq 0 ] && [ "$HAS_TODO_OPT" -eq 1 ] && [ "$HAS_STATUS_FIELD" -eq 1 ] && [ "$HAS_FP_FIELD" -eq 1 ] && [ "$HAS_ITEM_ID_STATUS" -eq 1 ]; then
    pass "T-abandon-38: item-edit uses correct field IDs (STATUS_FIELD_ID, TODO_OPTION_ID, FINGERPRINT_FIELD_ID, item-id)"
else
    fail "T-abandon-38: rc=$RC todo_opt=$HAS_TODO_OPT status_field=$HAS_STATUS_FIELD fp_field=$HAS_FP_FIELD item_id=$HAS_ITEM_ID_STATUS"
fi
teardown_mock
