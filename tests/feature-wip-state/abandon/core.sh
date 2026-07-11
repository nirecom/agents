# ===========================================================================
# T-abandon-1: OPEN issue happy path — Status=Todo write + fingerprint clear
# + lock deleted, rc=0.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATE="OPEN"
mint_abandon_mock
LOCKFILE="$PLANS_DIR/wip-lock-42.md"
echo "stale lock" > "$LOCKFILE"
run_with_timeout 60 bash "$TARGET" abandon 42 >/dev/null 2>&1
RC=$?
HAS_TODO=$(grep -c -- "--single-select-option-id $WIP_STATE_TODO_OPTION_ID" "$GH_MOCK_ARGS_LOG" 2>/dev/null || echo 0)
HAS_EMPTY_TEXT=$(grep -cE -- '--text *$' "$GH_MOCK_ARGS_LOG" 2>/dev/null || echo 0)
LOCK_DELETED=0
[ ! -f "$LOCKFILE" ] && LOCK_DELETED=1
if [ "$RC" -eq 0 ] && [ "$HAS_TODO" -ge 1 ] && [ "$HAS_EMPTY_TEXT" -ge 1 ] && [ "$LOCK_DELETED" -eq 1 ]; then
    pass "T-abandon-1: OPEN → Status=Todo + fingerprint cleared + lock deleted, rc=0"
else
    fail "T-abandon-1: rc=$RC todo=$HAS_TODO empty_text=$HAS_EMPTY_TEXT lock_deleted=$LOCK_DELETED log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-abandon-2: CLOSED issue — warn + exit 1, no mutations, lock retained.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATE="CLOSED"
mint_abandon_mock
LOCKFILE="$PLANS_DIR/wip-lock-42.md"
echo "stale lock" > "$LOCKFILE"
STDERR_FILE_2="$TMP/abandon-t2-stderr.log"
run_with_timeout 60 bash "$TARGET" abandon 42 >/dev/null 2>"$STDERR_FILE_2"
RC=$?
HAS_ITEM_EDIT=0
grep -q -- "project item-edit" "$GH_MOCK_ARGS_LOG" 2>/dev/null && HAS_ITEM_EDIT=1
LOCK_RETAINED=0
[ -f "$LOCKFILE" ] && LOCK_RETAINED=1
WARN_NONEMPTY=0; [ -s "$STDERR_FILE_2" ] && WARN_NONEMPTY=1
if [ "$RC" -eq 1 ] && [ "$HAS_ITEM_EDIT" -eq 0 ] && [ "$LOCK_RETAINED" -eq 1 ] && [ "$WARN_NONEMPTY" -eq 1 ]; then
    pass "T-abandon-2: CLOSED → exit 1, no mutations, lock retained"
else
    fail "T-abandon-2: rc=$RC item_edit=$HAS_ITEM_EDIT lock_retained=$LOCK_RETAINED warn_nonempty=$WARN_NONEMPTY log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-abandon-3: issue-state-check returns error (gh call fails) — exit 1,
# no mutations, lock retained. abandon must NOT proceed when state is unknown.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATE_CHECK_FAIL="1"
mint_abandon_mock
LOCKFILE="$PLANS_DIR/wip-lock-42.md"
echo "stale lock" > "$LOCKFILE"
STDERR_FILE_3="$TMP/abandon-t3-stderr.log"
run_with_timeout 60 bash "$TARGET" abandon 42 >/dev/null 2>"$STDERR_FILE_3"
RC=$?
HAS_ITEM_EDIT=0
grep -q -- "project item-edit" "$GH_MOCK_ARGS_LOG" 2>/dev/null && HAS_ITEM_EDIT=1
LOCK_RETAINED=0
[ -f "$LOCKFILE" ] && LOCK_RETAINED=1
WARN_NONEMPTY=0; [ -s "$STDERR_FILE_3" ] && WARN_NONEMPTY=1
if [ "$RC" -eq 1 ] && [ "$HAS_ITEM_EDIT" -eq 0 ] && [ "$LOCK_RETAINED" -eq 1 ] && [ "$WARN_NONEMPTY" -eq 1 ]; then
    pass "T-abandon-3: state-check error → exit 1, no mutations, lock retained"
else
    fail "T-abandon-3: rc=$RC item_edit=$HAS_ITEM_EDIT lock_retained=$LOCK_RETAINED warn_nonempty=$WARN_NONEMPTY log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-abandon-4: Status=Todo item-edit fails — HARD exit 1, lock RETAINED.
# C1 regression guard: a failed Status write must not delete the lock.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATE="OPEN"
export GH_MOCK_FAIL="item-edit-status"
mint_abandon_mock
LOCKFILE="$PLANS_DIR/wip-lock-42.md"
echo "stale lock" > "$LOCKFILE"
run_with_timeout 60 bash "$TARGET" abandon 42 >/dev/null 2>&1
RC=$?
LOCK_RETAINED=0
[ -f "$LOCKFILE" ] && LOCK_RETAINED=1
HAS_FP_EDIT=0
grep -q -- "--text" "$GH_MOCK_ARGS_LOG" 2>/dev/null && HAS_FP_EDIT=1
if [ "$RC" -eq 1 ] && [ "$LOCK_RETAINED" -eq 1 ] && [ "$HAS_FP_EDIT" -eq 0 ]; then
    pass "T-abandon-4: Status=Todo write fails → HARD exit 1, lock retained (C1 guard), fp item-edit skipped"
else
    fail "T-abandon-4: rc=$RC lock_retained=$LOCK_RETAINED has_fp_edit=$HAS_FP_EDIT log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-abandon-5: Fingerprint clear returns "no changes to make" — treated as
# success, exit 0, lock deleted. (Field already empty is the canonical no-op.)
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATE="OPEN"
export GH_MOCK_FP_NO_CHANGES="1"
mint_abandon_mock
LOCKFILE="$PLANS_DIR/wip-lock-42.md"
echo "stale lock" > "$LOCKFILE"
STDERR_FILE="$TMP/abandon-stderr.log"
run_with_timeout 60 bash "$TARGET" abandon 42 >/dev/null 2>"$STDERR_FILE"
RC=$?
LOCK_DELETED=0
[ ! -f "$LOCKFILE" ] && LOCK_DELETED=1
WARN_FP=0
grep -q "fingerprint clear failed" "$STDERR_FILE" 2>/dev/null && WARN_FP=1
if [ "$RC" -eq 0 ] && [ "$LOCK_DELETED" -eq 1 ] && [ "$WARN_FP" -eq 0 ]; then
    pass "T-abandon-5: fingerprint 'no changes to make' → success, exit 0, lock deleted"
else
    fail "T-abandon-5: rc=$RC lock_deleted=$LOCK_DELETED warn_fp=$WARN_FP stderr=$(cat "$STDERR_FILE" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-abandon-6: Item not in project (empty item_id) — delete lock + exit 0
# (idempotent; nothing to mutate on the board).
# ===========================================================================
setup_mock
export GH_MOCK_STATE="OPEN"
export GH_MOCK_PROJECT_ITEM_ID=""   # resolve_item_id returns empty
mint_abandon_mock
LOCKFILE="$PLANS_DIR/wip-lock-42.md"
echo "stale lock" > "$LOCKFILE"
run_with_timeout 60 bash "$TARGET" abandon 42 >/dev/null 2>&1
RC=$?
LOCK_DELETED=0
[ ! -f "$LOCKFILE" ] && LOCK_DELETED=1
HAS_ITEM_EDIT=0
grep -q -- "project item-edit" "$GH_MOCK_ARGS_LOG" 2>/dev/null && HAS_ITEM_EDIT=1
if [ "$RC" -eq 0 ] && [ "$LOCK_DELETED" -eq 1 ] && [ "$HAS_ITEM_EDIT" -eq 0 ]; then
    pass "T-abandon-6: item not in project → lock deleted, exit 0, no item-edit"
else
    fail "T-abandon-6: rc=$RC lock_deleted=$LOCK_DELETED item_edit=$HAS_ITEM_EDIT log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-abandon-7: Lock file absent — mutations still run, rc=0 (delete is a no-op).
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATE="OPEN"
mint_abandon_mock
# Ensure no lock file exists.
rm -f "$PLANS_DIR/wip-lock-42.md" 2>/dev/null || true
run_with_timeout 60 bash "$TARGET" abandon 42 >/dev/null 2>&1
RC=$?
HAS_TODO=$(grep -c -- "--single-select-option-id $WIP_STATE_TODO_OPTION_ID" "$GH_MOCK_ARGS_LOG" 2>/dev/null || echo 0)
if [ "$RC" -eq 0 ] && [ "$HAS_TODO" -ge 1 ]; then
    pass "T-abandon-7: lock absent → mutations still run, rc=0"
else
    fail "T-abandon-7: rc=$RC todo=$HAS_TODO log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-abandon-8: --session-id blocked → exit 2, no gh calls, session-id not echoed in stderr
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATE="OPEN"
mint_abandon_mock
STDERR_T8="$TMP/abandon-t8-stderr.log"
run_with_timeout 60 bash "$TARGET" abandon 42 --session-id foo-sid >/dev/null 2>"$STDERR_T8"
RC=$?
GH_CALLED_T8=0; [ -s "$GH_MOCK_ARGS_LOG" ] && GH_CALLED_T8=1
SESSION_LEAKED_T8=0; grep -q "foo-sid" "$STDERR_T8" 2>/dev/null && SESSION_LEAKED_T8=1
: > "$GH_MOCK_ARGS_LOG"
STDERR_T8_EQ="$TMP/abandon-t8-eq-stderr.log"
run_with_timeout 60 bash "$TARGET" abandon 42 --session-id=bar-sid >/dev/null 2>"$STDERR_T8_EQ"
RC_EQ=$?
GH_CALLED_T8_EQ=0; [ -s "$GH_MOCK_ARGS_LOG" ] && GH_CALLED_T8_EQ=1
SESSION_LEAKED_T8_EQ=0; grep -q "bar-sid" "$STDERR_T8_EQ" 2>/dev/null && SESSION_LEAKED_T8_EQ=1
if [ "$RC" -eq 2 ] && [ "$RC_EQ" -eq 2 ] && [ "$GH_CALLED_T8" -eq 0 ] && [ "$GH_CALLED_T8_EQ" -eq 0 ] && [ "$SESSION_LEAKED_T8" -eq 0 ] && [ "$SESSION_LEAKED_T8_EQ" -eq 0 ]; then
    pass "T-abandon-8: --session-id blocked → exit 2, no gh calls, session-id not echoed"
else
    fail "T-abandon-8: rc=$RC rc_eq=$RC_EQ gh_called=$GH_CALLED_T8 gh_called_eq=$GH_CALLED_T8_EQ leaked=$SESSION_LEAKED_T8 leaked_eq=$SESSION_LEAKED_T8_EQ"
fi
teardown_mock

# ===========================================================================
# T-abandon-9: TODO option ID used for Status, NOT the DONE option ID.
# Guards against copy-paste from cmd-clear.sh leaving WIP_STATE_DONE_OPTION_ID.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATE="OPEN"
mint_abandon_mock
run_with_timeout 60 bash "$TARGET" abandon 42 >/dev/null 2>&1
RC=$?
HAS_TODO=$(grep -c -- "--single-select-option-id $WIP_STATE_TODO_OPTION_ID" "$GH_MOCK_ARGS_LOG" 2>/dev/null)
HAS_DONE=$(grep -c -- "--single-select-option-id $WIP_STATE_DONE_OPTION_ID" "$GH_MOCK_ARGS_LOG" 2>/dev/null)
if [ "$RC" -eq 0 ] && [ "$HAS_TODO" -ge 1 ] && [ "$HAS_DONE" -eq 0 ]; then
    pass "T-abandon-9: Status uses TODO option id, not DONE option id"
else
    fail "T-abandon-9: rc=$RC todo=$HAS_TODO done=$HAS_DONE log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-abandon-10: Cross-repo --repo propagated to issue-state-check.sh.
# The state-check subprocess must receive --repo so the OPEN/CLOSED lookup
# targets the correct repository.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATE="OPEN"
export GH_MOCK_OWNER_REPO="nirecom/otherrepo"
mint_abandon_mock
run_with_timeout 60 bash "$TARGET" abandon 42 --repo nirecom/otherrepo >/dev/null 2>&1
RC=$?
# issue-state-check.sh calls `gh issue view <N> --repo nirecom/otherrepo --json state`.
STATE_CHECK_HAS_REPO=$(grep -cE -- "issue view 42 .*--repo nirecom/otherrepo.*--json state" "$GH_MOCK_ARGS_LOG" 2>/dev/null || echo 0)
if [ "$RC" -eq 0 ] && [ "$STATE_CHECK_HAS_REPO" -ge 1 ]; then
    pass "T-abandon-10: --repo propagated to issue-state-check.sh (issue view --repo)"
else
    fail "T-abandon-10: rc=$RC state_check_has_repo=$STATE_CHECK_HAS_REPO log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-abandon-11: Fingerprint clear fails with a non-"no changes" error — HARD
# exit 1, lock RETAINED. Distinguishes real fingerprint-write failure from the
# benign "no changes to make" no-op (T-abandon-5).
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATE="OPEN"
export GH_MOCK_FAIL="item-edit-fp"   # --text write returns a real error
mint_abandon_mock
LOCKFILE="$PLANS_DIR/wip-lock-42.md"
echo "stale lock" > "$LOCKFILE"
run_with_timeout 60 bash "$TARGET" abandon 42 >/dev/null 2>&1
RC=$?
LOCK_RETAINED=0
[ -f "$LOCKFILE" ] && LOCK_RETAINED=1
# Status=Todo write should have succeeded before the fingerprint failure.
HAS_TODO=$(grep -c -- "--single-select-option-id $WIP_STATE_TODO_OPTION_ID" "$GH_MOCK_ARGS_LOG" 2>/dev/null || echo 0)
if [ "$RC" -eq 1 ] && [ "$LOCK_RETAINED" -eq 1 ] && [ "$HAS_TODO" -ge 1 ]; then
    pass "T-abandon-11: fingerprint clear real error → HARD exit 1, lock retained"
else
    fail "T-abandon-11: rc=$RC lock_retained=$LOCK_RETAINED todo=$HAS_TODO log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-abandon-12: WIP_STATE_TODO_OPTION_ID missing/empty and unresolvable →
# preflight fails → exit 2, no item-edit mutations, lock RETAINED.
# The internal short-circuit resolver (empty _ISSUE_CREATE_INTERNAL_TODO_OPTION_ID)
# returns success without filling the TODO option id, so preflight is the
# deterministic failure point. abandon needs TODO for the Status=Todo write.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATE="OPEN"
mint_abandon_mock
# Force the field-id resolver through the internal short-circuit with an EMPTY
# TODO option id, so ensure_wip_field_ids cannot repopulate WIP_STATE_TODO_OPTION_ID.
export _ISSUE_CREATE_INTERNAL_OWNER="nirecom"
export _ISSUE_CREATE_INTERNAL_PROJECT_NUM="1"
export _ISSUE_CREATE_INTERNAL_PROJECT_ID="PVT_resolved"
export _ISSUE_CREATE_INTERNAL_STATUS_FIELD_ID="PVTSSF_status"
export _ISSUE_CREATE_INTERNAL_TODO_OPTION_ID=""     # missing → preflight must fail
export _ISSUE_CREATE_INTERNAL_FINGERPRINT_FIELD_ID="PVTF_fp"
unset WIP_STATE_TODO_OPTION_ID
LOCKFILE="$PLANS_DIR/wip-lock-42.md"
echo "stale lock" > "$LOCKFILE"
run_with_timeout 60 bash "$TARGET" abandon 42 >/dev/null 2>&1
RC=$?
HAS_ITEM_EDIT=0
grep -q -- "project item-edit" "$GH_MOCK_ARGS_LOG" 2>/dev/null && HAS_ITEM_EDIT=1
LOCK_RETAINED=0
[ -f "$LOCKFILE" ] && LOCK_RETAINED=1
if [ "$RC" -eq 2 ] && [ "$HAS_ITEM_EDIT" -eq 0 ] && [ "$LOCK_RETAINED" -eq 1 ]; then
    pass "T-abandon-12: WIP_STATE_TODO_OPTION_ID missing → preflight exit 2, no mutations, lock retained"
else
    fail "T-abandon-12: rc=$RC item_edit=$HAS_ITEM_EDIT lock_retained=$LOCK_RETAINED log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-abandon-13: ensure_resolved failure (no linked Projects v2) → exit 1,
# no item-edit mutations, lock RETAINED. abandon must not mutate the board or
# drop the lock when the project cannot be resolved.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATE="OPEN"
export GH_MOCK_LINKED_COUNT="0"   # resolve_project_for_repo returns rc=1
mint_abandon_mock
LOCKFILE="$PLANS_DIR/wip-lock-42.md"
echo "stale lock" > "$LOCKFILE"
run_with_timeout 60 bash "$TARGET" abandon 42 >/dev/null 2>&1
RC=$?
HAS_ITEM_EDIT=0
grep -q -- "project item-edit" "$GH_MOCK_ARGS_LOG" 2>/dev/null && HAS_ITEM_EDIT=1
LOCK_RETAINED=0
[ -f "$LOCKFILE" ] && LOCK_RETAINED=1
if [ "$RC" -eq 1 ] && [ "$HAS_ITEM_EDIT" -eq 0 ] && [ "$LOCK_RETAINED" -eq 1 ]; then
    pass "T-abandon-13: ensure_resolved failure → exit 1, no mutations, lock retained"
else
    fail "T-abandon-13: rc=$RC item_edit=$HAS_ITEM_EDIT lock_retained=$LOCK_RETAINED log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock
