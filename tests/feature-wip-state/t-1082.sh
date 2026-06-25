
# ===========================================================================
# T-1082-1: set <N> with CLAUDE_CODE_SESSION_ID set → uses own-sid, ignores JSONL.
# Concurrent-session fix (#1082): CLAUDE_CODE_SESSION_ID has higher priority than
# the JSONL mtime scan.  A newer foreign JSONL exists but must NOT be selected.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
SAVED_CLAUDE_ENV_FILE="${CLAUDE_ENV_FILE:-}"
unset CLAUDE_ENV_FILE
unset CLAUDE_SESSION_ID
export CLAUDE_CODE_SESSION_ID="own-sid-1082"
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMP/transcripts-1082"
FAKE_CWD="$TMP/fake-cwd-1082"
mkdir -p "$FAKE_CWD"
ENCODED_CWD=$(printf '%s' "$FAKE_CWD" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sed 's/[^a-z0-9]/-/g')
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED_CWD"
# Foreign session JSONL is newer — would have won the old JSONL-only path.
echo "{}" > "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED_CWD/foreign-sid-1082.jsonl"
touch -t 202601010000 "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED_CWD/foreign-sid-1082.jsonl"
# Expected fingerprint uses own-sid-1082, not foreign-sid-1082.
EXPECTED_FP=$(printf '%s:%s' "own-sid-1082" "42" | sha256sum | cut -c1-8)
( cd "$FAKE_CWD" && run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1 )
RC=$?
if [ "$RC" -eq 0 ] && grep -q -- "--text $EXPECTED_FP" "$GH_MOCK_ARGS_LOG" 2>/dev/null; then
    pass "T-1082-1: set <N>: CLAUDE_CODE_SESSION_ID beats newer foreign JSONL (concurrent-session fix)"
else
    fail "T-1082-1: rc=$RC expected_fp=$EXPECTED_FP log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
unset CLAUDE_CODE_SESSION_ID CLAUDE_TRANSCRIPT_BASE_DIR
[ -n "$SAVED_CLAUDE_ENV_FILE" ] && export CLAUDE_ENV_FILE="$SAVED_CLAUDE_ENV_FILE"
teardown_mock

# ===========================================================================
# T-1082-2: check <N> with CLAUDE_CODE_SESSION_ID set → fingerprint computed from own-sid.
# Confirms that check verb also benefits from the concurrent-session fix.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATUS="In Progress"
SAVED_CLAUDE_ENV_FILE="${CLAUDE_ENV_FILE:-}"
unset CLAUDE_ENV_FILE
unset CLAUDE_SESSION_ID
export CLAUDE_CODE_SESSION_ID="own-sid-1082-check"
# The stored fingerprint matches own-sid-1082-check, not any foreign sid.
EXPECTED_FP=$(printf '%s:%s' "own-sid-1082-check" "42" | sha256sum | cut -c1-8)
export GH_MOCK_FINGERPRINT="$EXPECTED_FP"
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMP/transcripts-1082-check"
FAKE_CWD="$TMP/fake-cwd-1082-check"
mkdir -p "$FAKE_CWD"
ENCODED_CWD=$(printf '%s' "$FAKE_CWD" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sed 's/[^a-z0-9]/-/g')
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED_CWD"
echo "{}" > "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED_CWD/foreign-sid-check.jsonl"
touch -t 202601010000 "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED_CWD/foreign-sid-check.jsonl"
OUT=$( cd "$FAKE_CWD" && run_with_timeout 60 bash "$TARGET" check 42 2>/dev/null )
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "same" ]; then
    pass "T-1082-2: check <N>: CLAUDE_CODE_SESSION_ID → fingerprint from own-sid → 'same'"
else
    fail "T-1082-2: rc=$RC out='$OUT' expected='same'"
fi
unset CLAUDE_CODE_SESSION_ID CLAUDE_TRANSCRIPT_BASE_DIR
[ -n "$SAVED_CLAUDE_ENV_FILE" ] && export CLAUDE_ENV_FILE="$SAVED_CLAUDE_ENV_FILE"
teardown_mock
