# ===========================================================================
# Happy path — new NOT_NEEDED sentinels record status=skipped + skip_reason
# ===========================================================================

echo ""
echo "=== WS-SK-H1: WORKFLOW_RESEARCH_NOT_NEEDED: <reason> → research=skipped + reason ==="

SID="sk-h1-$$"
write_state "$SID" "$(ALL_COMPLETE_EXCEPT research "$SID")"

MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: single file change>>"' "$SID")
MARK_OUT=$(run_mark "$MARK_JSON")

expect_state_step "WS-SK-H1a. RESEARCH_NOT_NEEDED → research=skipped" \
    "$SID" "research" "skipped"

H1_REASON=$(read_state_field "$SID" "research" "skip_reason")
if [ "$H1_REASON" = "single file change" ]; then
    pass "WS-SK-H1b. research.skip_reason recorded"
else
    fail "WS-SK-H1b. expected skip_reason='single file change', got: $H1_REASON"
fi

echo ""
echo "=== WS-SK-OUTLINE-HAPPY: WORKFLOW_OUTLINE_NOT_NEEDED → outline=skipped + reason ==="

SID="sk-outline-happy-$$"
write_state "$SID" "$(ALL_COMPLETE_EXCEPT outline "$SID")"

MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: single obvious approach>>"' "$SID")
MARK_OUT=$(run_mark "$MARK_JSON")

expect_state_step "WS-SK-OUTLINE-HAPPY-a. OUTLINE_NOT_NEEDED → outline=skipped" \
    "$SID" "outline" "skipped"

OUTH_REASON=$(read_state_field "$SID" "outline" "skip_reason")
if [ "$OUTH_REASON" = "single obvious approach" ]; then
    pass "WS-SK-OUTLINE-HAPPY-b. outline.skip_reason recorded"
else
    fail "WS-SK-OUTLINE-HAPPY-b. expected skip_reason='single obvious approach', got: $OUTH_REASON"
fi

echo ""
echo "=== WS-SK-OUTLINE-DUD: OUTLINE_NOT_NEEDED with short reason → rejected ==="

SID="sk-outline-dud-$$"
write_state "$SID" "$(ALL_COMPLETE_EXCEPT outline "$SID")"

MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: ab>>"' "$SID")
MARK_OUT=$(run_mark "$MARK_JSON")

DUD_STATUS=$(read_state_status "$SID" "outline")
if [ "$DUD_STATUS" = "pending" ]; then
    pass "WS-SK-OUTLINE-DUD-a. short reason → outline stays pending"
else
    fail "WS-SK-OUTLINE-DUD-a. expected outline=pending, got: $DUD_STATUS"
fi

if echo "$MARK_OUT" | grep -qiE "too short|reason|reject"; then
    pass "WS-SK-OUTLINE-DUD-b. additionalContext hints at rejection"
else
    fail "WS-SK-OUTLINE-DUD-b. expected rejection hint, got: $MARK_OUT"
fi

echo ""
echo "=== WS-SK-OUTLINE-BARE: bare OUTLINE_NOT_NEEDED (no reason) → LOOKSLIKE rejected ==="

SID="sk-outline-bare-$$"
write_state "$SID" "$(ALL_COMPLETE_EXCEPT outline "$SID")"

MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_OUTLINE_NOT_NEEDED>>"' "$SID")
MARK_OUT=$(run_mark "$MARK_JSON")

BARE_STATUS=$(read_state_status "$SID" "outline")
if [ "$BARE_STATUS" = "pending" ]; then
    pass "WS-SK-OUTLINE-BARE-a. bare form → outline stays pending"
else
    fail "WS-SK-OUTLINE-BARE-a. expected outline=pending, got: $BARE_STATUS"
fi

if echo "$MARK_OUT" | grep -qiE "malformed|OUTLINE_NOT_NEEDED|reason"; then
    pass "WS-SK-OUTLINE-BARE-b. additionalContext hints at malformed sentinel"
else
    fail "WS-SK-OUTLINE-BARE-b. expected 'malformed'/'OUTLINE_NOT_NEEDED'/'reason' hint, got: $MARK_OUT"
fi

echo ""
echo "=== WS-SK-OUTLINE-IDEMPOTENT: OUTLINE_NOT_NEEDED twice → second emit is no-op ==="

SID="sk-outline-idem-$$"
write_state "$SID" "$(ALL_COMPLETE_EXCEPT outline "$SID")"

MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: first reason here>>"' "$SID")
run_mark "$MARK_JSON" > /dev/null

IDEM_R1=$(read_state_field "$SID" "outline" "skip_reason")
if [ "$IDEM_R1" = "first reason here" ]; then
    pass "WS-SK-OUTLINE-IDEMPOTENT-a. first skip_reason recorded"
else
    fail "WS-SK-OUTLINE-IDEMPOTENT-a. expected 'first reason here', got: $IDEM_R1"
fi

MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: second reason here>>"' "$SID")
run_mark "$MARK_JSON" > /dev/null

expect_state_step "WS-SK-OUTLINE-IDEMPOTENT-b. after second mark outline=skipped" \
    "$SID" "outline" "skipped"

echo ""
echo "=== WS-SK-DETAIL-HAPPY: WORKFLOW_DETAIL_NOT_NEEDED → detail=skipped + reason ==="

SID="sk-detail-happy-$$"
write_state "$SID" "$(ALL_COMPLETE_EXCEPT detail "$SID")"

MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_DETAIL_NOT_NEEDED: file changes clear from outline>>"' "$SID")
MARK_OUT=$(run_mark "$MARK_JSON")

expect_state_step "WS-SK-DETAIL-HAPPY-a. DETAIL_NOT_NEEDED → detail=skipped" \
    "$SID" "detail" "skipped"

DETH_REASON=$(read_state_field "$SID" "detail" "skip_reason")
if [ "$DETH_REASON" = "file changes clear from outline" ]; then
    pass "WS-SK-DETAIL-HAPPY-b. detail.skip_reason recorded"
else
    fail "WS-SK-DETAIL-HAPPY-b. expected skip_reason='file changes clear from outline', got: $DETH_REASON"
fi

echo ""
echo "=== WS-SK-DETAIL-DUD: DETAIL_NOT_NEEDED with short reason → rejected ==="

SID="sk-detail-dud-$$"
write_state "$SID" "$(ALL_COMPLETE_EXCEPT detail "$SID")"

MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_DETAIL_NOT_NEEDED: ab>>"' "$SID")
MARK_OUT=$(run_mark "$MARK_JSON")

DUD2_STATUS=$(read_state_status "$SID" "detail")
if [ "$DUD2_STATUS" = "pending" ]; then
    pass "WS-SK-DETAIL-DUD-a. short reason → detail stays pending"
else
    fail "WS-SK-DETAIL-DUD-a. expected detail=pending, got: $DUD2_STATUS"
fi

if echo "$MARK_OUT" | grep -qiE "too short|reason|reject"; then
    pass "WS-SK-DETAIL-DUD-b. additionalContext hints at rejection"
else
    fail "WS-SK-DETAIL-DUD-b. expected rejection hint, got: $MARK_OUT"
fi

echo ""
echo "=== WS-SK-DETAIL-BARE: bare DETAIL_NOT_NEEDED (no reason) → LOOKSLIKE rejected ==="

SID="sk-detail-bare-$$"
write_state "$SID" "$(ALL_COMPLETE_EXCEPT detail "$SID")"

MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_DETAIL_NOT_NEEDED>>"' "$SID")
MARK_OUT=$(run_mark "$MARK_JSON")

BARE2_STATUS=$(read_state_status "$SID" "detail")
if [ "$BARE2_STATUS" = "pending" ]; then
    pass "WS-SK-DETAIL-BARE-a. bare form → detail stays pending"
else
    fail "WS-SK-DETAIL-BARE-a. expected detail=pending, got: $BARE2_STATUS"
fi

if echo "$MARK_OUT" | grep -qiE "malformed|DETAIL_NOT_NEEDED|reason"; then
    pass "WS-SK-DETAIL-BARE-b. additionalContext hints at malformed sentinel"
else
    fail "WS-SK-DETAIL-BARE-b. expected 'malformed'/'DETAIL_NOT_NEEDED'/'reason' hint, got: $MARK_OUT"
fi

echo ""
echo "=== WS-SK-DETAIL-IDEMPOTENT: DETAIL_NOT_NEEDED twice → second emit is no-op ==="

SID="sk-detail-idem-$$"
write_state "$SID" "$(ALL_COMPLETE_EXCEPT detail "$SID")"

MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_DETAIL_NOT_NEEDED: first detail reason>>"' "$SID")
run_mark "$MARK_JSON" > /dev/null

IDEM2_R1=$(read_state_field "$SID" "detail" "skip_reason")
if [ "$IDEM2_R1" = "first detail reason" ]; then
    pass "WS-SK-DETAIL-IDEMPOTENT-a. first skip_reason recorded"
else
    fail "WS-SK-DETAIL-IDEMPOTENT-a. expected 'first detail reason', got: $IDEM2_R1"
fi

MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_DETAIL_NOT_NEEDED: second detail reason>>"' "$SID")
run_mark "$MARK_JSON" > /dev/null

expect_state_step "WS-SK-DETAIL-IDEMPOTENT-b. after second mark detail=skipped" \
    "$SID" "detail" "skipped"

echo ""
echo "=== WS-SK-COMBO-BOTH: emit both OUTLINE + DETAIL sentinels → both skipped, research unaffected ==="

SID="sk-combo-both-$$"
# Start with state where outline, detail, research are all pending
cat > "$WORKFLOW_DIR/${SID}.json" <<COMBOB_EOF
{
  "version": 1,
  "session_id": "$SID",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "pending", "updated_at": null},
    "outline":           {"status": "pending", "updated_at": null},
    "detail":            {"status": "pending", "updated_at": null},
    "write_tests":       {"status": "complete", "updated_at": "2026-04-11T10:03:00.000Z"},
    "code":              {"status": "complete", "updated_at": "2026-04-11T10:04:00.000Z"},
    "verify":            {"status": "complete", "updated_at": "2026-04-11T10:05:00.000Z"},
    "docs":              {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"}
  }
}
COMBOB_EOF

MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: only one approach>>"' "$SID")
run_mark "$MARK_JSON" > /dev/null

MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_DETAIL_NOT_NEEDED: file plan obvious>>"' "$SID")
run_mark "$MARK_JSON" > /dev/null

COMBOB_OUTLINE=$(read_state_status "$SID" "outline")
COMBOB_DETAIL=$(read_state_status "$SID" "detail")
COMBOB_RESEARCH=$(read_state_status "$SID" "research")

if [ "$COMBOB_OUTLINE" = "skipped" ]; then
    pass "WS-SK-COMBO-BOTH-a. outline=skipped"
else
    fail "WS-SK-COMBO-BOTH-a. expected outline=skipped, got: $COMBOB_OUTLINE"
fi

if [ "$COMBOB_DETAIL" = "skipped" ]; then
    pass "WS-SK-COMBO-BOTH-b. detail=skipped"
else
    fail "WS-SK-COMBO-BOTH-b. expected detail=skipped, got: $COMBOB_DETAIL"
fi

if [ "$COMBOB_RESEARCH" = "pending" ]; then
    pass "WS-SK-COMBO-BOTH-c. research unaffected (still pending — new sentinels do NOT skip research)"
else
    fail "WS-SK-COMBO-BOTH-c. expected research=pending, got: $COMBOB_RESEARCH"
fi

echo ""
echo "=== WS-SK-MIG-PLAN-SPLIT: legacy steps.plan in state → readState() splits to outline+detail ==="

SID="sk-mig-split-$$"
# Write legacy state with steps.plan (no outline/detail yet)
cat > "$WORKFLOW_DIR/${SID}.json" <<MIG_EOF
{
  "version": 1,
  "session_id": "$SID",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "complete", "updated_at": "2026-04-11T10:01:00.000Z"},
    "plan":              {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "write_tests":       {"status": "complete", "updated_at": "2026-04-11T10:03:00.000Z"},
    "code":              {"status": "complete", "updated_at": "2026-04-11T10:04:00.000Z"},
    "verify":            {"status": "complete", "updated_at": "2026-04-11T10:05:00.000Z"},
    "docs":              {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"}
  }
}
MIG_EOF

# Invoke readState() via node and capture migrated state
MIG_HOOK_DIR="$(cd "$(dirname "$0")/.." && pwd)/hooks"
MIGRATED=$(CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node -e "
  const wsLib = require(process.argv[1] + '/lib/workflow-state.js');
  const state = wsLib.readState(process.argv[2]);
  console.log(JSON.stringify(state.steps));
" "$MIG_HOOK_DIR" "$SID" 2>/dev/null || echo "{}")

if echo "$MIGRATED" | node -e "
  let s = '';
  process.stdin.on('data', d => s += d);
  process.stdin.on('end', () => {
    try {
      const steps = JSON.parse(s);
      const hasOutline = steps.outline && typeof steps.outline.status === 'string';
      const hasDetail = steps.detail && typeof steps.detail.status === 'string';
      const noPlan = !steps.plan;
      process.exit(hasOutline && hasDetail && noPlan ? 0 : 1);
    } catch (e) { process.exit(1); }
  });
" 2>/dev/null; then
    pass "WS-SK-MIG-PLAN-SPLIT. legacy steps.plan migrated to steps.outline + steps.detail (no steps.plan)"
else
    fail "WS-SK-MIG-PLAN-SPLIT. expected outline+detail set, plan absent, got: $MIGRATED"
fi

echo ""
echo "=== WS-SK-LEGACY-PLAN-REJECT: emit WORKFLOW_PLAN_NOT_NEEDED → state unchanged ==="

SID="sk-legacy-plan-$$"
# Build state where outline and detail are both pending
cat > "$WORKFLOW_DIR/${SID}.json" <<LEG_EOF
{
  "version": 1,
  "session_id": "$SID",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "complete", "updated_at": "2026-04-11T10:01:00.000Z"},
    "outline":           {"status": "pending", "updated_at": null},
    "detail":            {"status": "pending", "updated_at": null},
    "write_tests":       {"status": "complete", "updated_at": "2026-04-11T10:03:00.000Z"},
    "code":              {"status": "complete", "updated_at": "2026-04-11T10:04:00.000Z"},
    "verify":            {"status": "complete", "updated_at": "2026-04-11T10:05:00.000Z"},
    "docs":              {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"}
  }
}
LEG_EOF

MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_PLAN_NOT_NEEDED: legacy attempt>>"' "$SID")
MARK_OUT=$(run_mark "$MARK_JSON")

LEG_OUTLINE=$(read_state_status "$SID" "outline")
LEG_DETAIL=$(read_state_status "$SID" "detail")

if [ "$LEG_OUTLINE" = "pending" ] && [ "$LEG_DETAIL" = "pending" ]; then
    pass "WS-SK-LEGACY-PLAN-REJECT. PLAN_NOT_NEEDED removed: outline+detail remain pending"
else
    fail "WS-SK-LEGACY-PLAN-REJECT. expected outline=pending detail=pending, got outline=$LEG_OUTLINE detail=$LEG_DETAIL"
fi

echo ""
echo "=== WS-SK-GATE-OUTLINE: outline step missing → commit blocked ==="

REPO=$(setup_repo)
REPO_N=$(to_node_path "$REPO")
SID="sk-gate-outline-$$"
OVERRIDE='{"status":"pending","updated_at":null}'
STATE_JSON=$(build_state_with_override "$SID" "outline" "$OVERRIDE")
write_state "$SID" "$STATE_JSON"

echo "source" > "$REPO/app.js"
git -C "$REPO" add app.js

GATE_INPUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"git -C %s commit -m \\"test\\""},"session_id":"%s"}' "$REPO_N" "$SID")
GATE_OUT=$(run_gate "$GATE_INPUT")

if echo "$GATE_OUT" | grep -q '"block"' && echo "$GATE_OUT" | grep -qi "outline"; then
    pass "WS-SK-GATE-OUTLINE. outline pending → gate blocks and mentions outline"
else
    fail "WS-SK-GATE-OUTLINE. expected block + outline mention, got: $GATE_OUT"
fi

echo ""
echo "=== WS-SK-GATE-DETAIL: detail step missing → commit blocked ==="

REPO=$(setup_repo)
REPO_N=$(to_node_path "$REPO")
SID="sk-gate-detail-$$"
OVERRIDE='{"status":"pending","updated_at":null}'
STATE_JSON=$(build_state_with_override "$SID" "detail" "$OVERRIDE")
write_state "$SID" "$STATE_JSON"

echo "source" > "$REPO/app.js"
git -C "$REPO" add app.js

GATE_INPUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"git -C %s commit -m \\"test\\""},"session_id":"%s"}' "$REPO_N" "$SID")
GATE_OUT=$(run_gate "$GATE_INPUT")

if echo "$GATE_OUT" | grep -q '"block"' && echo "$GATE_OUT" | grep -qi "detail"; then
    pass "WS-SK-GATE-DETAIL. detail pending → gate blocks and mentions detail"
else
    fail "WS-SK-GATE-DETAIL. expected block + detail mention, got: $GATE_OUT"
fi

echo ""
echo "=== WS-SK-H3: WORKFLOW_WRITE_TESTS_NOT_NEEDED: <reason> → write_tests=skipped + reason ==="

SID="sk-h3-$$"
write_state "$SID" "$(ALL_COMPLETE_EXCEPT write_tests "$SID")"

MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: hook refactor, no test coverage affected>>"' "$SID")
MARK_OUT=$(run_mark "$MARK_JSON")

expect_state_step "WS-SK-H3a. WRITE_TESTS_NOT_NEEDED → write_tests=skipped" \
    "$SID" "write_tests" "skipped"

H3_REASON=$(read_state_field "$SID" "write_tests" "skip_reason")
if [ "$H3_REASON" = "hook refactor, no test coverage affected" ]; then
    pass "WS-SK-H3b. write_tests.skip_reason recorded"
else
    fail "WS-SK-H3b. expected skip_reason='hook refactor, no test coverage affected', got: $H3_REASON"
fi
