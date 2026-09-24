
# ===========================================================================
# Test 21: clear <N> calls item-edit with $WIP_STATE_DONE_OPTION_ID AND --text "" AND deletes lock.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
# Pre-create the lock file.
LOCKFILE="$PLANS_DIR/wip-lock-42.md"
echo "stale lock" > "$LOCKFILE"
run_with_timeout 60 bash "$TARGET" clear 42 >/dev/null 2>&1
RC=$?
HAS_DONE=$(grep -c -- "--single-select-option-id $WIP_STATE_DONE_OPTION_ID" "$GH_MOCK_ARGS_LOG" 2>/dev/null || echo 0)
# After bash expansion, `--text ""` appears as `--text ` (empty arg collapsed).
HAS_EMPTY_TEXT=$(grep -cE -- '--text *$' "$GH_MOCK_ARGS_LOG" 2>/dev/null || echo 0)
LOCK_DELETED=0
[ ! -f "$LOCKFILE" ] && LOCK_DELETED=1
if [ "$RC" -eq 0 ] && [ "$HAS_DONE" -ge 1 ] && [ "$HAS_EMPTY_TEXT" -ge 1 ] && [ "$LOCK_DELETED" -eq 1 ]; then
    pass "T21: clear <N> sets DONE + clears fingerprint + deletes lock"
else
    fail "T21: rc=$RC done=$HAS_DONE empty_text=$HAS_EMPTY_TEXT lock_deleted=$LOCK_DELETED log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# Test 22: clear <N> idempotent on repeat (no lock file exists).
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
run_with_timeout 60 bash "$TARGET" clear 42 >/dev/null 2>&1
RC1=$?
run_with_timeout 60 bash "$TARGET" clear 42 >/dev/null 2>&1
RC2=$?
if [ "$RC1" -eq 0 ] && [ "$RC2" -eq 0 ]; then
    pass "T22: clear <N> idempotent on repeat (both exits 0)"
else
    fail "T22: rc1=$RC1 rc2=$RC2"
fi
teardown_mock

# ===========================================================================
# Test 23: clear <N> with every gh call failing → exit 0 AND attempts lock deletion.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_FAIL="item-edit-status"  # only one fail flag; mock also will fail item-edit-fp via combined? Use --text fail via env override
# To simulate every gh call failing, override mock to always fail item-edit:
cat > "$TMP/mock-bin/gh" <<'MOCK_EOF'
#!/bin/bash
ARGS="$*"
if [ -n "${GH_MOCK_ARGS_LOG:-}" ]; then
    printf '%s\n' "$ARGS" >> "$GH_MOCK_ARGS_LOG"
fi
case "$ARGS" in
  auth\ status*) echo "Token scopes: 'project'"; exit 0 ;;
  repo\ view\ *--json\ owner,name*|repo\ view\ *)
    echo "${GH_MOCK_OWNER_REPO:-nirecom/agents}"; exit 0 ;;
  project\ item-edit\ *) echo "error: gh down" >&2; exit 1 ;;
  api\ graphql\ *)
    echo "PVTI_existing"; exit 0
    ;;
  *) echo "MOCK GH: no match $ARGS" >&2; exit 2 ;;
esac
MOCK_EOF
chmod +x "$TMP/mock-bin/gh"
LOCKFILE="$PLANS_DIR/wip-lock-42.md"
echo "stale" > "$LOCKFILE"
run_with_timeout 60 bash "$TARGET" clear 42 >/dev/null 2>&1
RC=$?
LOCK_DELETED=0
[ ! -f "$LOCKFILE" ] && LOCK_DELETED=1
if [ "$RC" -eq 0 ] && [ "$LOCK_DELETED" -eq 1 ]; then
    pass "T23: clear <N> all gh fail → exit 0, lock still deleted"
else
    fail "T23: rc=$RC lock_deleted=$LOCK_DELETED"
fi
teardown_mock
