# ===========================================================================
# Group 2: Session ID missing (no session_id field, CLAUDE_ENV_FILE unset)
# ===========================================================================

echo ""
echo "=== WS-SK-NO-SID-1: RESEARCH_NOT_NEEDED with no session_id → could not resolve ==="

SID="sk-nosid1-$$"
write_state "$SID" "$(ALL_COMPLETE_EXCEPT research "$SID")"

NO_SID_JSON=$(build_mark_json_no_sid 'echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: single file change>>"')
NO_SID_OUT=$(cd "$EMPTY_TRANSCRIPT_DIR" && echo "$NO_SID_JSON" | CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" CLAUDE_ENV_FILE="" CLAUDE_TRANSCRIPT_BASE_DIR="$EMPTY_TRANSCRIPT_DIR" node "$(to_node_path "$MARK_HOOK")" 2>&1 || true)

if echo "$NO_SID_OUT" | grep -qiE "could not resolve session_id|session_id"; then
    pass "WS-SK-NO-SID-1a. no session_id → 'could not resolve session_id' in output"
else
    fail "WS-SK-NO-SID-1a. expected 'could not resolve session_id', got: $NO_SID_OUT"
fi

# research state was written with a known SID; verify it remains pending (no session to overwrite)
NOSID1_STATUS=$(read_state_status "$SID" "research")
if [ "$NOSID1_STATUS" = "pending" ]; then
    pass "WS-SK-NO-SID-1b. research.status remains pending when session_id missing"
else
    fail "WS-SK-NO-SID-1b. expected research=pending, got: $NOSID1_STATUS"
fi

echo ""
echo "=== WS-SK-NO-SID-2: OUTLINE_NOT_NEEDED with no session_id → could not resolve ==="

SID="sk-nosid2-$$"
write_state "$SID" "$(ALL_COMPLETE_EXCEPT outline "$SID")"

NO_SID_JSON=$(build_mark_json_no_sid 'echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: trivial typo fix>>"')
NO_SID_OUT=$(cd "$EMPTY_TRANSCRIPT_DIR" && echo "$NO_SID_JSON" | CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" CLAUDE_ENV_FILE="" CLAUDE_TRANSCRIPT_BASE_DIR="$EMPTY_TRANSCRIPT_DIR" node "$(to_node_path "$MARK_HOOK")" 2>&1 || true)

if echo "$NO_SID_OUT" | grep -qiE "could not resolve session_id|session_id"; then
    pass "WS-SK-NO-SID-2a. no session_id → 'could not resolve session_id' in output"
else
    fail "WS-SK-NO-SID-2a. expected 'could not resolve session_id', got: $NO_SID_OUT"
fi

NOSID2_STATUS=$(read_state_status "$SID" "outline")
if [ "$NOSID2_STATUS" = "pending" ]; then
    pass "WS-SK-NO-SID-2b. outline.status remains pending when session_id missing"
else
    fail "WS-SK-NO-SID-2b. expected outline=pending, got: $NOSID2_STATUS"
fi

echo ""
echo "=== WS-SK-NO-SID-3: WRITE_TESTS_NOT_NEEDED with no session_id → could not resolve ==="

SID="sk-nosid3-$$"
write_state "$SID" "$(ALL_COMPLETE_EXCEPT write_tests "$SID")"

NO_SID_JSON=$(build_mark_json_no_sid 'echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: hook refactor, no test coverage affected>>"')
NO_SID_OUT=$(cd "$EMPTY_TRANSCRIPT_DIR" && echo "$NO_SID_JSON" | CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" CLAUDE_ENV_FILE="" CLAUDE_TRANSCRIPT_BASE_DIR="$EMPTY_TRANSCRIPT_DIR" node "$(to_node_path "$MARK_HOOK")" 2>&1 || true)

if echo "$NO_SID_OUT" | grep -qiE "could not resolve session_id|session_id"; then
    pass "WS-SK-NO-SID-3a. no session_id → 'could not resolve session_id' in output"
else
    fail "WS-SK-NO-SID-3a. expected 'could not resolve session_id', got: $NO_SID_OUT"
fi

NOSID3_STATUS=$(read_state_status "$SID" "write_tests")
if [ "$NOSID3_STATUS" = "pending" ]; then
    pass "WS-SK-NO-SID-3b. write_tests.status remains pending when session_id missing"
else
    fail "WS-SK-NO-SID-3b. expected write_tests=pending, got: $NOSID3_STATUS"
fi
