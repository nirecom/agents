# ---------------------------------------------------------------------------
# === workflow-gate.js: Normal cases (approve) ===
# ---------------------------------------------------------------------------

echo "=== workflow-gate: Normal cases (approve) ==="

# Test 1: All 7 steps complete → approve
REPO=$(setup_repo)
write_state "test-session" "$(ALL_COMPLETE_JSON test-session)"
expect_approve_gate "1. All 7 steps complete → approve" "$REPO" "$COMMIT_JSON"

# Test 2: research skipped, rest complete → approve
REPO=$(setup_repo)
write_state "test-session" '{
  "version": 1,
  "session_id": "test-session",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "skipped",  "updated_at": "2026-04-11T10:01:00.000Z"},
    "outline":           {"status": "complete",  "updated_at": "2026-04-11T10:02:00.000Z"},
    "detail":            {"status": "complete",  "updated_at": "2026-04-11T10:02:30.000Z"},
    "write_tests":       {"status": "complete",  "updated_at": "2026-04-11T10:03:00.000Z"},
    "review_tests":      {"status": "skipped",   "updated_at": "2026-04-11T10:03:30.000Z"},
    "review_security":   {"status": "complete",  "updated_at": "2026-04-11T10:04:30.000Z"},
    "run_tests":         {"status": "complete",  "updated_at": "2026-04-11T10:05:00.000Z"},
    "docs":              {"status": "complete",  "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "complete",  "updated_at": "2026-04-11T10:07:00.000Z"},
    "cleanup":           {"status": "complete",  "updated_at": "2026-04-11T10:08:00.000Z"}
  }
}'
expect_approve_gate "2. research skipped, rest complete → approve" "$REPO" "$COMMIT_JSON"

# Test 3: outline+detail skipped, rest complete → approve
REPO=$(setup_repo)
write_state "test-session" '{
  "version": 1,
  "session_id": "test-session",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "complete",  "updated_at": "2026-04-11T10:01:00.000Z"},
    "outline":           {"status": "skipped",   "updated_at": "2026-04-11T10:02:00.000Z"},
    "detail":            {"status": "skipped",   "updated_at": "2026-04-11T10:02:30.000Z"},
    "write_tests":       {"status": "complete",  "updated_at": "2026-04-11T10:03:00.000Z"},
    "review_tests":      {"status": "skipped",   "updated_at": "2026-04-11T10:03:30.000Z"},
    "review_security":   {"status": "complete",  "updated_at": "2026-04-11T10:04:30.000Z"},
    "run_tests":         {"status": "complete",  "updated_at": "2026-04-11T10:05:00.000Z"},
    "docs":              {"status": "complete",  "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "complete",  "updated_at": "2026-04-11T10:07:00.000Z"},
    "cleanup":           {"status": "complete",  "updated_at": "2026-04-11T10:08:00.000Z"}
  }
}'
expect_approve_gate "3. outline+detail skipped, rest complete → approve" "$REPO" "$COMMIT_JSON"

# Test 4: git -C /path commit form → correctly intercepted (block when state file missing)
# Uses a unique session ID so no pre-existing state file exists (session-scoped storage).
GIT_C_REPO=$(setup_repo)
GIT_C_SID="test-4-no-state-$$"
GIT_C_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $GIT_C_REPO commit -m msg\"},\"session_id\":\"$GIT_C_SID\"}"
expect_block_gate "4. git -C /path commit → intercepted (block when state missing)" "$GIT_C_REPO" "$GIT_C_JSON"

# ---------------------------------------------------------------------------
# === workflow-gate.js: Error/block cases ===
# ---------------------------------------------------------------------------

echo ""
echo "=== workflow-gate: Error/block cases ==="

# Test 5: detail pending (a gated step) → block, message contains "detail"
# NOTE: `research` is a NON_GATE_STEP (not enforced at commit time), so a pending
# `research` no longer blocks. This case uses `detail` — a genuinely gated step —
# to exercise the "pending gated step → block" path.
REPO=$(setup_repo)
write_state "test-session" '{
  "version": 1,
  "session_id": "test-session",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "complete", "updated_at": "2026-04-11T10:01:00.000Z"},
    "outline":           {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "detail":            {"status": "pending",  "updated_at": null},
    "write_tests":       {"status": "complete", "updated_at": "2026-04-11T10:03:00.000Z"},
    "review_tests":      {"status": "skipped", "updated_at": "2026-04-11T10:03:30.000Z"},
    "review_security":   {"status": "complete", "updated_at": "2026-04-11T10:04:30.000Z"},
    "run_tests":         {"status": "complete", "updated_at": "2026-04-11T10:05:00.000Z"},
    "docs":              {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"},
    "cleanup":           {"status": "complete", "updated_at": "2026-04-11T10:08:00.000Z"}
  }
}'
expect_block_gate_contains "5. detail pending (gated step) → block with 'detail' in message" "$REPO" "$COMMIT_JSON" "detail"

# Test 6: Multiple steps pending (detail, write_tests) → block, message contains both
REPO=$(setup_repo)
write_state "test-session" '{
  "version": 1,
  "session_id": "test-session",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "complete", "updated_at": "2026-04-11T10:01:00.000Z"},
    "outline":           {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "detail":            {"status": "pending",  "updated_at": null},
    "write_tests":       {"status": "pending",  "updated_at": null},
    "review_tests":      {"status": "pending",  "updated_at": null},
    "review_security":   {"status": "complete", "updated_at": "2026-04-11T10:04:30.000Z"},
    "run_tests":         {"status": "complete", "updated_at": "2026-04-11T10:05:00.000Z"},
    "docs":              {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"},
    "cleanup":           {"status": "complete", "updated_at": "2026-04-11T10:08:00.000Z"}
  }
}'
RESULT=$(run_gate "$REPO" "$COMMIT_JSON")
if echo "$RESULT" | grep -q '"block"' && echo "$RESULT" | grep -qi "detail" && echo "$RESULT" | grep -qi "write_tests"; then
    pass "6. Multiple pending steps → block, message contains both step names"
else
    fail "6. Multiple pending steps → expected block with 'detail' and 'write_tests', got: $RESULT"
fi

# Test 7: run_tests set to skipped (non-skippable) → block
REPO=$(setup_repo)
write_state "test-session" '{
  "version": 1,
  "session_id": "test-session",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "complete", "updated_at": "2026-04-11T10:01:00.000Z"},
    "outline":           {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "detail":            {"status": "complete", "updated_at": "2026-04-11T10:02:30.000Z"},
    "write_tests":       {"status": "complete", "updated_at": "2026-04-11T10:03:00.000Z"},
    "review_tests":      {"status": "skipped", "updated_at": "2026-04-11T10:03:30.000Z"},
    "review_security":   {"status": "complete", "updated_at": "2026-04-11T10:04:30.000Z"},
    "run_tests":         {"status": "skipped",  "updated_at": "2026-04-11T10:05:00.000Z"},
    "docs":              {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"},
    "cleanup":           {"status": "complete", "updated_at": "2026-04-11T10:08:00.000Z"}
  }
}'
expect_block_gate "7. run_tests skipped (non-skippable) → block" "$REPO" "$COMMIT_JSON"

# Test 8: user_verification set to skipped → block
REPO=$(setup_repo)
write_state "test-session" '{
  "version": 1,
  "session_id": "test-session",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "complete", "updated_at": "2026-04-11T10:01:00.000Z"},
    "outline":           {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "detail":            {"status": "complete", "updated_at": "2026-04-11T10:02:30.000Z"},
    "write_tests":       {"status": "complete", "updated_at": "2026-04-11T10:03:00.000Z"},
    "review_tests":      {"status": "skipped", "updated_at": "2026-04-11T10:03:30.000Z"},
    "review_security":   {"status": "complete", "updated_at": "2026-04-11T10:04:30.000Z"},
    "run_tests":         {"status": "complete", "updated_at": "2026-04-11T10:05:00.000Z"},
    "docs":              {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "skipped",  "updated_at": "2026-04-11T10:07:00.000Z"},
    "cleanup":           {"status": "complete", "updated_at": "2026-04-11T10:08:00.000Z"}
  }
}'
expect_block_gate "8. user_verification skipped → block" "$REPO" "$COMMIT_JSON"

# ---------------------------------------------------------------------------
# === workflow-gate.js: Fail-safe cases (BLOCK, not approve) ===
# ---------------------------------------------------------------------------

echo ""
echo "=== workflow-gate: Fail-safe cases (block) ==="

# Test 9: session_id missing from stdin → block (fail-safe)
REPO=$(setup_repo)
NO_SID_JSON='{"tool_name":"Bash","tool_input":{"command":"git commit -m test"}}'
expect_block_gate "9. session_id missing from stdin → block (fail-safe)" "$REPO" "$NO_SID_JSON"

# Test 10: State file not found → block (fail-safe)
REPO=$(setup_repo)
# No write_state call — state file does not exist
expect_block_gate "10. State file not found → block (fail-safe)" "$REPO" "$COMMIT_JSON"

# Test 11: State JSON corrupted → block (fail-safe)
REPO=$(setup_repo)
write_state "test-session" "NOT VALID JSON }{{"
expect_block_gate "11. Corrupted state JSON → block (fail-safe)" "$REPO" "$COMMIT_JSON"

# ---------------------------------------------------------------------------
# === workflow-gate.js: Other edge cases ===
# ---------------------------------------------------------------------------

echo ""
echo "=== workflow-gate: Other edge cases ==="

# Test 12: Non-Bash tool (Read) → approve
REPO=$(setup_repo)
NON_BASH_JSON='{"tool_name":"Read","tool_input":{"file_path":"README.md"},"session_id":"test-session"}'
expect_approve_gate "12. Non-Bash tool (Read) → approve" "$REPO" "$NON_BASH_JSON"

# Test 13: git status command (not commit) → approve
REPO=$(setup_repo)
GIT_STATUS_JSON='{"tool_name":"Bash","tool_input":{"command":"git status"},"session_id":"test-session"}'
expect_approve_gate "13. git status (not commit) → approve" "$REPO" "$GIT_STATUS_JSON"

# Test 14: Private repo → approve
# SKIPPED: requires gh API network call or complex mocking.
# The is-private-repo.js module calls `gh api repos/<id> --jq .private` which
# requires GitHub authentication and network access. Mocking it in a shell test
# would require modifying the module or adding test-only injection points.
echo "SKIP: 14. Private repo → approve (requires gh API / network)"

# Test 15: Empty/missing tool_input → approve
REPO=$(setup_repo)
EMPTY_INPUT_JSON='{"tool_name":"Bash","session_id":"test-session"}'
expect_approve_gate "15. Missing tool_input → approve" "$REPO" "$EMPTY_INPUT_JSON"

# ---------------------------------------------------------------------------
# === workflow-gate.js: Idempotency ===
# ---------------------------------------------------------------------------

echo ""
echo "=== workflow-gate: Idempotency ==="

# Test 16: Same state, hook called twice → identical result
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
RESULT1=$(run_gate "$REPO" "$COMMIT_JSON")
RESULT2=$(run_gate "$REPO" "$COMMIT_JSON")
if [ "$RESULT1" = "$RESULT2" ]; then pass "16. Idempotent block result"
else fail "16. Idempotent block — results differ: '$RESULT1' vs '$RESULT2'"; fi
