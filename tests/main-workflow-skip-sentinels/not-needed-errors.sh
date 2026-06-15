# ===========================================================================
# Error path — reason validation (mirror WS-EV rejection patterns)
# ===========================================================================

echo ""
echo "=== WS-SK-E1: RESEARCH_NOT_NEEDED with short reason 'xx' → rejected ==="

SID="sk-e1-$$"
write_state "$SID" "$(ALL_COMPLETE_EXCEPT research "$SID")"

MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: xx>>"' "$SID")
MARK_OUT=$(run_mark "$MARK_JSON")

E1_STATUS=$(read_state_status "$SID" "research")
if [ "$E1_STATUS" = "pending" ]; then
    pass "WS-SK-E1a. short reason → research stays pending"
else
    fail "WS-SK-E1a. expected research=pending, got: $E1_STATUS"
fi

if echo "$MARK_OUT" | grep -qiE "too short|reason|reject"; then
    pass "WS-SK-E1b. additionalContext hints at rejection"
else
    fail "WS-SK-E1b. expected rejection hint, got: $MARK_OUT"
fi

echo ""
echo "=== WS-SK-E2: OUTLINE_NOT_NEEDED with ASCII dud 'none' → rejected ==="

SID="sk-e2-$$"
write_state "$SID" "$(ALL_COMPLETE_EXCEPT outline "$SID")"

MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: none>>"' "$SID")
MARK_OUT=$(run_mark "$MARK_JSON")

E2_STATUS=$(read_state_status "$SID" "outline")
if [ "$E2_STATUS" = "pending" ]; then
    pass "WS-SK-E2a. ASCII dud → outline stays pending"
else
    fail "WS-SK-E2a. expected outline=pending, got: $E2_STATUS"
fi

if echo "$MARK_OUT" | grep -qiE "placeholder|reject"; then
    pass "WS-SK-E2b. additionalContext hints at rejection"
else
    fail "WS-SK-E2b. expected rejection hint, got: $MARK_OUT"
fi

echo ""
echo "=== WS-SK-E3: WRITE_TESTS_NOT_NEEDED with CJK dud 'スキップする' → rejected ==="

SID="sk-e3-$$"
write_state "$SID" "$(ALL_COMPLETE_EXCEPT write_tests "$SID")"

MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: スキップする>>"' "$SID")
MARK_OUT=$(run_mark "$MARK_JSON")

E3_STATUS=$(read_state_status "$SID" "write_tests")
if [ "$E3_STATUS" = "pending" ]; then
    pass "WS-SK-E3a. CJK dud → write_tests stays pending"
else
    fail "WS-SK-E3a. expected write_tests=pending, got: $E3_STATUS"
fi

if echo "$MARK_OUT" | grep -qiE "placeholder|reject"; then
    pass "WS-SK-E3b. additionalContext hints at rejection"
else
    fail "WS-SK-E3b. expected rejection hint, got: $MARK_OUT"
fi

echo ""
echo "=== WS-SK-E4: RESEARCH_NOT_NEEDED reason containing '>' → rejected ==="

SID="sk-e4-$$"
write_state "$SID" "$(ALL_COMPLETE_EXCEPT research "$SID")"

MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: a>b>>"' "$SID")
MARK_OUT=$(run_mark "$MARK_JSON")

E4_STATUS=$(read_state_status "$SID" "research")
if [ "$E4_STATUS" = "pending" ]; then
    pass "WS-SK-E4a. '>' in reason → research stays pending"
else
    fail "WS-SK-E4a. expected research=pending, got: $E4_STATUS"
fi

if echo "$MARK_OUT" | grep -qiE "malformed|contains no|'>'|>|reject"; then
    pass "WS-SK-E4b. additionalContext contains helpful hint"
else
    fail "WS-SK-E4b. expected rejection hint, got: $MARK_OUT"
fi

echo ""
echo "=== WS-SK-E5: DETAIL_NOT_NEEDED with single repeated char 'aaa' → rejected ==="

SID="sk-e5-$$"
write_state "$SID" "$(ALL_COMPLETE_EXCEPT detail "$SID")"

MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_DETAIL_NOT_NEEDED: aaa>>"' "$SID")
MARK_OUT=$(run_mark "$MARK_JSON")

E5_STATUS=$(read_state_status "$SID" "detail")
if [ "$E5_STATUS" = "pending" ]; then
    pass "WS-SK-E5a. single-repeat reason → detail stays pending"
else
    fail "WS-SK-E5a. expected detail=pending, got: $E5_STATUS"
fi

if echo "$MARK_OUT" | grep -qiE "repeated|reject|real explanation"; then
    pass "WS-SK-E5b. additionalContext hints at rejection (detail variant)"
else
    fail "WS-SK-E5b. expected rejection hint, got: $MARK_OUT"
fi

echo ""
echo "=== WS-SK-E6: legacy bare WRITE_TESTS_NOT_NEEDED (no reason) → LOOKSLIKE rejected ==="

SID="sk-e6-$$"
write_state "$SID" "$(ALL_COMPLETE_EXCEPT write_tests "$SID")"

MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED>>"' "$SID")
MARK_OUT=$(run_mark "$MARK_JSON")

E6_STATUS=$(read_state_status "$SID" "write_tests")
if [ "$E6_STATUS" = "pending" ]; then
    pass "WS-SK-E6a. bare form → write_tests stays pending"
else
    fail "WS-SK-E6a. expected write_tests=pending, got: $E6_STATUS"
fi

if echo "$MARK_OUT" | grep -qiE "LOOKSLIKE|malformed|reason"; then
    pass "WS-SK-E6b. additionalContext hints at malformed sentinel"
else
    fail "WS-SK-E6b. expected 'LOOKSLIKE'/'malformed'/'reason' hint, got: $MARK_OUT"
fi

echo ""
echo "=== WS-SK-E7: DOCS_NOT_NEEDED is deprecated → rejected, docs stays pending ==="

SID="sk-e7-$$"
write_state "$SID" "$(ALL_COMPLETE_EXCEPT docs "$SID")"

MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_DOCS_NOT_NEEDED: any reason that passes validation>>"' "$SID")
MARK_OUT=$(run_mark "$MARK_JSON")

E7_STATUS=$(read_state_status "$SID" "docs")
if [ "$E7_STATUS" = "pending" ]; then
    pass "WS-SK-E7a. DOCS_NOT_NEEDED → docs stays pending (deprecated)"
else
    fail "WS-SK-E7a. expected docs=pending, got: $E7_STATUS"
fi

if echo "$MARK_OUT" | grep -qiE "not accepted|no skip path|deprecat"; then
    pass "WS-SK-E7b. additionalContext contains deprecation message"
else
    fail "WS-SK-E7b. expected 'not accepted'/'no skip path'/'deprecated' hint, got: $MARK_OUT"
fi

# ===========================================================================
# Boundary cases — accept 3-char reason, trim leading whitespace
# ===========================================================================

echo ""
echo "=== WS-SK-B1: RESEARCH_NOT_NEEDED 3-char reason 'abc' → accepted ==="

SID="sk-b1-$$"
write_state "$SID" "$(ALL_COMPLETE_EXCEPT research "$SID")"

MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: abc>>"' "$SID")
MARK_OUT=$(run_mark "$MARK_JSON")

expect_state_step "WS-SK-B1a. 3-char reason → research=skipped" \
    "$SID" "research" "skipped"

B1_REASON=$(read_state_field "$SID" "research" "skip_reason")
if [ "$B1_REASON" = "abc" ]; then
    pass "WS-SK-B1b. skip_reason='abc' recorded verbatim"
else
    fail "WS-SK-B1b. expected skip_reason='abc', got: $B1_REASON"
fi

echo ""
echo "=== WS-SK-B2: OUTLINE_NOT_NEEDED leading whitespace '  abc' → trimmed ==="

SID="sk-b2-$$"
write_state "$SID" "$(ALL_COMPLETE_EXCEPT outline "$SID")"

MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_OUTLINE_NOT_NEEDED:   abc>>"' "$SID")
MARK_OUT=$(run_mark "$MARK_JSON")

expect_state_step "WS-SK-B2a. leading-space reason → outline=skipped" \
    "$SID" "outline" "skipped"

B2_REASON=$(read_state_field "$SID" "outline" "skip_reason")
if [ "$B2_REASON" = "abc" ]; then
    pass "WS-SK-B2b. skip_reason trimmed to 'abc'"
else
    fail "WS-SK-B2b. expected skip_reason='abc' (trimmed), got: $B2_REASON"
fi
