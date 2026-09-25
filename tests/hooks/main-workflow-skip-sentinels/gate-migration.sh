# ===========================================================================
# Gate — new feature: skipped status is accepted for write_tests
# ===========================================================================

echo ""
echo "=== WS-SK-GATE-1: write_tests=skipped + all others complete → gate approves ==="

REPO=$(setup_repo)
REPO_N=$(to_node_path "$REPO")
SID="sk-gate1-$$"
OVERRIDE='{"status":"skipped","updated_at":"2026-04-11T10:03:00.000Z","skip_reason":"hook refactor"}'
STATE_JSON=$(build_state_with_override "$SID" "write_tests" "$OVERRIDE")
write_state "$SID" "$STATE_JSON"

echo "source" > "$REPO/app.js"
git -C "$REPO" add app.js

GATE_INPUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"git -C %s commit -m \\"test\\""},"session_id":"%s"}' "$REPO_N" "$SID")
GATE_OUT=$(run_gate "$GATE_INPUT")

if echo "$GATE_OUT" | grep -q '"approve"'; then
    pass "WS-SK-GATE-1. write_tests=skipped → gate approves"
else
    fail "WS-SK-GATE-1. expected approve, got: $GATE_OUT"
fi

echo ""
echo "=== WS-SK-GATE-2: research=skipped + all others complete → gate approves (regression) ==="

REPO=$(setup_repo)
REPO_N=$(to_node_path "$REPO")
SID="sk-gate2-$$"
OVERRIDE='{"status":"skipped","updated_at":"2026-04-11T10:01:00.000Z","skip_reason":"single file change"}'
STATE_JSON=$(build_state_with_override "$SID" "research" "$OVERRIDE")
write_state "$SID" "$STATE_JSON"

echo "source" > "$REPO/app.js"
git -C "$REPO" add app.js

GATE_INPUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"git -C %s commit -m \\"test\\""},"session_id":"%s"}' "$REPO_N" "$SID")
GATE_OUT=$(run_gate "$GATE_INPUT")

if echo "$GATE_OUT" | grep -q '"approve"'; then
    pass "WS-SK-GATE-2. research=skipped → gate approves"
else
    fail "WS-SK-GATE-2. expected approve, got: $GATE_OUT"
fi

echo ""
echo "=== WS-SK-GATE-3: outline=skipped + detail=skipped + all others complete → gate approves (regression) ==="

REPO=$(setup_repo)
REPO_N=$(to_node_path "$REPO")
SID="sk-gate3-$$"
OUTLINE_SKIP='{"status":"skipped","updated_at":"2026-04-11T10:02:00.000Z","skip_reason":"single approach"}'
DETAIL_SKIP='{"status":"skipped","updated_at":"2026-04-11T10:02:30.000Z","skip_reason":"trivial typo"}'
STATE_JSON=$(build_state_with_override "$SID" "outline" "$OUTLINE_SKIP")
write_state "$SID" "$STATE_JSON"
# Now overwrite detail too
TMP_JSON=$(node -e "
  const s = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
  s.steps.detail = JSON.parse(process.argv[2]);
  console.log(JSON.stringify(s, null, 2));
" "$WORKFLOW_DIR/${SID}.json" "$DETAIL_SKIP")
echo "$TMP_JSON" > "$WORKFLOW_DIR/${SID}.json"

echo "source" > "$REPO/app.js"
git -C "$REPO" add app.js

GATE_INPUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"git -C %s commit -m \\"test\\""},"session_id":"%s"}' "$REPO_N" "$SID")
GATE_OUT=$(run_gate "$GATE_INPUT")

if echo "$GATE_OUT" | grep -q '"approve"'; then
    pass "WS-SK-GATE-3. outline+detail both skipped → gate approves"
else
    fail "WS-SK-GATE-3. expected approve, got: $GATE_OUT"
fi

# ===========================================================================
# Migration — old states (pre-upgrade) must still pass the gate
# ===========================================================================

echo ""
echo "=== WS-SK-MIG-1: pre-upgrade write_tests=complete (bare-written) → gate approves ==="

REPO=$(setup_repo)
REPO_N=$(to_node_path "$REPO")
SID="sk-mig1-$$"
# Pre-upgrade state: write_tests was recorded as "complete" by the old bare
# WRITE_TESTS_NOT_NEEDED handler. All other steps complete.
OVERRIDE='{"status":"complete","updated_at":"2026-04-11T10:03:00.000Z"}'
STATE_JSON=$(build_state_with_override "$SID" "write_tests" "$OVERRIDE")
write_state "$SID" "$STATE_JSON"

echo "source" > "$REPO/app.js"
git -C "$REPO" add app.js

GATE_INPUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"git -C %s commit -m \\"test\\""},"session_id":"%s"}' "$REPO_N" "$SID")
GATE_OUT=$(run_gate "$GATE_INPUT")

if echo "$GATE_OUT" | grep -q '"approve"'; then
    pass "WS-SK-MIG-1. legacy write_tests=complete → gate approves"
else
    fail "WS-SK-MIG-1. expected approve, got: $GATE_OUT"
fi

echo ""
echo "=== WS-SK-MIG-2: pre-upgrade docs=complete + skip_reason (old DOCS_NOT_NEEDED) → gate approves ==="

REPO=$(setup_repo)
REPO_N=$(to_node_path "$REPO")
SID="sk-mig2-$$"
OVERRIDE='{"status":"complete","updated_at":"2026-04-11T10:06:00.000Z","skip_reason":"legacy DOCS_NOT_NEEDED reason"}'
STATE_JSON=$(build_state_with_override "$SID" "docs" "$OVERRIDE")
write_state "$SID" "$STATE_JSON"

echo "source" > "$REPO/app.js"
git -C "$REPO" add app.js

GATE_INPUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"git -C %s commit -m \\"test\\""},"session_id":"%s"}' "$REPO_N" "$SID")
GATE_OUT=$(run_gate "$GATE_INPUT")

if echo "$GATE_OUT" | grep -q '"approve"'; then
    pass "WS-SK-MIG-2. legacy docs=complete with skip_reason → gate approves"
else
    fail "WS-SK-MIG-2. expected approve, got: $GATE_OUT"
fi

# ===========================================================================
# Idempotency — latest skip_reason wins on re-run
# ===========================================================================

echo ""
echo "=== WS-SK-ID-1: WRITE_TESTS_NOT_NEEDED run twice → latest skip_reason wins ==="

SID="sk-id1-$$"
write_state "$SID" "$(ALL_COMPLETE_EXCEPT write_tests "$SID")"

MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: reason one>>"' "$SID")
MARK_OUT=$(run_mark "$MARK_JSON")

ID1_REASON1=$(read_state_field "$SID" "write_tests" "skip_reason")
if [ "$ID1_REASON1" = "reason one" ]; then
    pass "WS-SK-ID-1a. first skip_reason='reason one' recorded"
else
    fail "WS-SK-ID-1a. expected skip_reason='reason one', got: $ID1_REASON1"
fi

MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: reason two>>"' "$SID")
MARK_OUT=$(run_mark "$MARK_JSON")

expect_state_step "WS-SK-ID-1b. after second mark write_tests=skipped" \
    "$SID" "write_tests" "skipped"

ID1_REASON2=$(read_state_field "$SID" "write_tests" "skip_reason")
if [ "$ID1_REASON2" = "reason two" ]; then
    pass "WS-SK-ID-1c. skip_reason overwritten with 'reason two'"
else
    fail "WS-SK-ID-1c. expected skip_reason='reason two', got: $ID1_REASON2"
fi

# ===========================================================================
# Group 1: LOOKSLIKE malformed for RESEARCH and PLAN (mirror WS-SK-E6)
# ===========================================================================

echo ""
echo "=== WS-SK-E6a: bare RESEARCH_NOT_NEEDED (no colon, no reason) → LOOKSLIKE rejected ==="

SID="sk-e6a-$$"
write_state "$SID" "$(ALL_COMPLETE_EXCEPT research "$SID")"

MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_RESEARCH_NOT_NEEDED>>"' "$SID")
MARK_OUT=$(run_mark "$MARK_JSON")

E6A_STATUS=$(read_state_status "$SID" "research")
if [ "$E6A_STATUS" = "pending" ]; then
    pass "WS-SK-E6a-1. bare RESEARCH_NOT_NEEDED → research stays pending"
else
    fail "WS-SK-E6a-1. expected research=pending, got: $E6A_STATUS"
fi

if echo "$MARK_OUT" | grep -qiE "malformed|RESEARCH_NOT_NEEDED|reason"; then
    pass "WS-SK-E6a-2. additionalContext hints at malformed sentinel"
else
    fail "WS-SK-E6a-2. expected 'malformed'/'RESEARCH_NOT_NEEDED'/'reason' hint, got: $MARK_OUT"
fi

echo ""
echo "=== WS-SK-E6d: bare DETAIL_NOT_NEEDED (no colon, no reason) → LOOKSLIKE rejected ==="

SID="sk-e6d-$$"
write_state "$SID" "$(ALL_COMPLETE_EXCEPT detail "$SID")"

MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_DETAIL_NOT_NEEDED>>"' "$SID")
MARK_OUT=$(run_mark "$MARK_JSON")

E6D_STATUS=$(read_state_status "$SID" "detail")
if [ "$E6D_STATUS" = "pending" ]; then
    pass "WS-SK-E6d-1. bare DETAIL_NOT_NEEDED → detail stays pending"
else
    fail "WS-SK-E6d-1. expected detail=pending, got: $E6D_STATUS"
fi

if echo "$MARK_OUT" | grep -qiE "malformed|DETAIL_NOT_NEEDED|reason"; then
    pass "WS-SK-E6d-2. additionalContext hints at malformed sentinel"
else
    fail "WS-SK-E6d-2. expected 'malformed'/'DETAIL_NOT_NEEDED'/'reason' hint, got: $MARK_OUT"
fi

echo ""
echo "=== WS-SK-E6e: RESEARCH_NOT_NEEDED: with only space in reason slot → LOOKSLIKE rejected ==="

SID="sk-e6e-$$"
write_state "$SID" "$(ALL_COMPLETE_EXCEPT research "$SID")"

MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: >>"' "$SID")
MARK_OUT=$(run_mark "$MARK_JSON")

E6E_STATUS=$(read_state_status "$SID" "research")
if [ "$E6E_STATUS" = "pending" ]; then
    pass "WS-SK-E6e-1. space-only reason → research stays pending"
else
    fail "WS-SK-E6e-1. expected research=pending, got: $E6E_STATUS"
fi

if echo "$MARK_OUT" | grep -qiE "malformed|too short|reason|reject"; then
    pass "WS-SK-E6e-2. additionalContext hints at rejection"
else
    fail "WS-SK-E6e-2. expected rejection hint, got: $MARK_OUT"
fi
