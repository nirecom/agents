#!/usr/bin/env bash
# TDD tests for the readState() migration in claude-global/hooks/lib/workflow-state.js
# Migration (not yet implemented) transforms old state files:
#   - verify key → renamed to run_tests
#   - code key  → deleted
#   - review_security key → added as pending if absent
# NOTE: Migration is NOT yet implemented. All M* tests are expected to FAIL (TDD).
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_STATE_JS="$DOTFILES_DIR/claude-global/hooks/lib/workflow-state.js"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

# ---------------------------------------------------------------------------
# Temporary workspace
# ---------------------------------------------------------------------------

TMPDIR_BASE=$(mktemp -d)
WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
mkdir -p "$WORKFLOW_DIR"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# write_state_file <session_id> <json>
# Writes raw JSON directly to the workflow state file (bypasses readState migration).
write_state_file() {
    local sid="$1" json="$2"
    printf '%s' "$json" > "$WORKFLOW_DIR/${sid}.json"
}

# call_read_state <session_id>
# Calls readState(sid) via inline Node.js and prints the resulting JSON.
# Returns empty string on error.
call_read_state() {
    local sid="$1"
    CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node -e "
process.env.CLAUDE_WORKFLOW_DIR = process.argv[1];
const { readState } = require(process.argv[2]);
const state = readState(process.argv[3]);
console.log(JSON.stringify(state));
" "$WORKFLOW_DIR" "$WORKFLOW_STATE_JS" "$sid" 2>/dev/null || echo "null"
}

# get_step_status_from_json <json> <step_name>
# Extracts steps.<step>.status from a JSON string using Node.js.
get_step_status_from_json() {
    local json="$1" step="$2"
    echo "$json" | node -e "
let b=''; process.stdin.on('data',c=>b+=c);
process.stdin.on('end',()=>{
  try{
    const s=JSON.parse(b);
    const st=s&&s.steps&&s.steps['$step'];
    console.log(st?st.status:'absent');
  }catch(e){console.log('error');}
})
" 2>/dev/null || echo "error"
}

# has_key_in_steps <json> <key>
# Returns "yes" if steps.<key> exists (even if null), "no" otherwise.
has_key_in_steps() {
    local json="$1" key="$2"
    echo "$json" | node -e "
let b=''; process.stdin.on('data',c=>b+=c);
process.stdin.on('end',()=>{
  try{
    const s=JSON.parse(b);
    console.log(s&&s.steps&&'$key' in s.steps ? 'yes' : 'no');
  }catch(e){console.log('error');}
})
" 2>/dev/null || echo "error"
}

# ---------------------------------------------------------------------------
# === Normal cases — old state files are migrated ===
# ---------------------------------------------------------------------------

echo "=== workflow-migration: Normal cases ==="

# M1: old state {verify: complete, code: complete} → result has run_tests: complete,
#     no code key, review_security: pending
SID="m1-$$-$RANDOM"
write_state_file "$SID" '{
  "version": 1,
  "session_id": "'"$SID"'",
  "created_at": "2026-03-01T10:00:00.000Z",
  "steps": {
    "research":          {"status": "complete", "updated_at": "2026-03-01T10:01:00.000Z"},
    "plan":              {"status": "complete", "updated_at": "2026-03-01T10:02:00.000Z"},
    "write_tests":       {"status": "complete", "updated_at": "2026-03-01T10:03:00.000Z"},
    "code":              {"status": "complete", "updated_at": "2026-03-01T10:04:00.000Z"},
    "verify":            {"status": "complete", "updated_at": "2026-03-01T10:05:00.000Z"},
    "docs":              {"status": "complete", "updated_at": "2026-03-01T10:06:00.000Z"},
    "user_verification": {"status": "complete", "updated_at": "2026-03-01T10:07:00.000Z"}
  }
}'
RESULT=$(call_read_state "$SID")

RUN_TESTS_STATUS=$(get_step_status_from_json "$RESULT" "run_tests")
if [ "$RUN_TESTS_STATUS" = "complete" ]; then
    pass "M1a. verify=complete → run_tests=complete (renamed)"
else
    fail "M1a. verify=complete → expected run_tests=complete, got: $RUN_TESTS_STATUS"
fi

CODE_KEY=$(has_key_in_steps "$RESULT" "code")
if [ "$CODE_KEY" = "no" ]; then
    pass "M1b. code key deleted after migration"
else
    fail "M1b. expected code key deleted, but has_key_in_steps returned: $CODE_KEY"
fi

REVIEW_SECURITY_STATUS=$(get_step_status_from_json "$RESULT" "review_security")
if [ "$REVIEW_SECURITY_STATUS" = "pending" ]; then
    pass "M1c. review_security added as pending"
else
    fail "M1c. expected review_security=pending, got: $REVIEW_SECURITY_STATUS"
fi

VERIFY_KEY=$(has_key_in_steps "$RESULT" "verify")
if [ "$VERIFY_KEY" = "no" ]; then
    pass "M1d. verify key deleted after migration"
else
    fail "M1d. expected verify key deleted, but has_key_in_steps returned: $VERIFY_KEY"
fi

# M2: old state {verify: skipped} → result has run_tests: skipped
SID="m2-$$-$RANDOM"
write_state_file "$SID" '{
  "version": 1,
  "session_id": "'"$SID"'",
  "created_at": "2026-03-01T10:00:00.000Z",
  "steps": {
    "research": {"status": "complete", "updated_at": "2026-03-01T10:01:00.000Z"},
    "plan":     {"status": "complete", "updated_at": "2026-03-01T10:02:00.000Z"},
    "verify":   {"status": "skipped",  "updated_at": "2026-03-01T10:05:00.000Z"},
    "docs":     {"status": "complete", "updated_at": "2026-03-01T10:06:00.000Z"},
    "user_verification": {"status": "pending", "updated_at": null}
  }
}'
RESULT=$(call_read_state "$SID")
RUN_TESTS_STATUS=$(get_step_status_from_json "$RESULT" "run_tests")
if [ "$RUN_TESTS_STATUS" = "skipped" ]; then
    pass "M2. verify=skipped → run_tests=skipped"
else
    fail "M2. verify=skipped → expected run_tests=skipped, got: $RUN_TESTS_STATUS"
fi

# M3: old state {verify: pending} → result has run_tests: pending
SID="m3-$$-$RANDOM"
write_state_file "$SID" '{
  "version": 1,
  "session_id": "'"$SID"'",
  "created_at": "2026-03-01T10:00:00.000Z",
  "steps": {
    "research": {"status": "complete", "updated_at": "2026-03-01T10:01:00.000Z"},
    "verify":   {"status": "pending",  "updated_at": null},
    "docs":     {"status": "pending",  "updated_at": null},
    "user_verification": {"status": "pending", "updated_at": null}
  }
}'
RESULT=$(call_read_state "$SID")
RUN_TESTS_STATUS=$(get_step_status_from_json "$RESULT" "run_tests")
if [ "$RUN_TESTS_STATUS" = "pending" ]; then
    pass "M3. verify=pending → run_tests=pending"
else
    fail "M3. verify=pending → expected run_tests=pending, got: $RUN_TESTS_STATUS"
fi

# ---------------------------------------------------------------------------
# === Edge cases ===
# ---------------------------------------------------------------------------

echo ""
echo "=== workflow-migration: Edge cases ==="

# M4: state has neither verify nor code → run_tests: pending added, review_security: pending added, others preserved
SID="m4-$$-$RANDOM"
write_state_file "$SID" '{
  "version": 1,
  "session_id": "'"$SID"'",
  "created_at": "2026-03-01T10:00:00.000Z",
  "steps": {
    "research":    {"status": "complete", "updated_at": "2026-03-01T10:01:00.000Z"},
    "plan":        {"status": "complete", "updated_at": "2026-03-01T10:02:00.000Z"},
    "write_tests": {"status": "complete", "updated_at": "2026-03-01T10:03:00.000Z"},
    "docs":        {"status": "pending",  "updated_at": null},
    "user_verification": {"status": "pending", "updated_at": null}
  }
}'
RESULT=$(call_read_state "$SID")

RUN_TESTS_STATUS=$(get_step_status_from_json "$RESULT" "run_tests")
if [ "$RUN_TESTS_STATUS" = "pending" ]; then
    pass "M4a. no verify/code → run_tests=pending added"
else
    fail "M4a. no verify/code → expected run_tests=pending, got: $RUN_TESTS_STATUS"
fi

REVIEW_SECURITY_STATUS=$(get_step_status_from_json "$RESULT" "review_security")
if [ "$REVIEW_SECURITY_STATUS" = "pending" ]; then
    pass "M4b. no review_security in old state → review_security=pending added"
else
    fail "M4b. expected review_security=pending, got: $REVIEW_SECURITY_STATUS"
fi

# Verify others are preserved
RESEARCH_STATUS=$(get_step_status_from_json "$RESULT" "research")
if [ "$RESEARCH_STATUS" = "complete" ]; then
    pass "M4c. research preserved as complete"
else
    fail "M4c. research.status changed unexpectedly: $RESEARCH_STATUS"
fi

# M5: state has both run_tests AND verify → run_tests preserved (not overwritten), verify deleted
SID="m5-$$-$RANDOM"
write_state_file "$SID" '{
  "version": 1,
  "session_id": "'"$SID"'",
  "created_at": "2026-03-01T10:00:00.000Z",
  "steps": {
    "research":    {"status": "complete", "updated_at": "2026-03-01T10:01:00.000Z"},
    "run_tests":   {"status": "complete", "updated_at": "2026-03-01T10:05:00.000Z"},
    "verify":      {"status": "pending",  "updated_at": null},
    "docs":        {"status": "complete", "updated_at": "2026-03-01T10:06:00.000Z"},
    "user_verification": {"status": "pending", "updated_at": null}
  }
}'
RESULT=$(call_read_state "$SID")

RUN_TESTS_STATUS=$(get_step_status_from_json "$RESULT" "run_tests")
if [ "$RUN_TESTS_STATUS" = "complete" ]; then
    pass "M5a. existing run_tests=complete preserved (not overwritten by verify=pending)"
else
    fail "M5a. expected run_tests=complete (preserved), got: $RUN_TESTS_STATUS"
fi

VERIFY_KEY=$(has_key_in_steps "$RESULT" "verify")
if [ "$VERIFY_KEY" = "no" ]; then
    pass "M5b. verify key deleted when run_tests already exists"
else
    fail "M5b. expected verify deleted, got has_key_in_steps: $VERIFY_KEY"
fi

# ---------------------------------------------------------------------------
# === Idempotency cases ===
# ---------------------------------------------------------------------------

echo ""
echo "=== workflow-migration: Idempotency cases ==="

# M6: call readState on already-migrated state → result unchanged (no double-migration)
SID="m6-$$-$RANDOM"
write_state_file "$SID" '{
  "version": 1,
  "session_id": "'"$SID"'",
  "created_at": "2026-03-01T10:00:00.000Z",
  "steps": {
    "research":        {"status": "complete", "updated_at": "2026-03-01T10:01:00.000Z"},
    "plan":            {"status": "complete", "updated_at": "2026-03-01T10:02:00.000Z"},
    "write_tests":     {"status": "complete", "updated_at": "2026-03-01T10:03:00.000Z"},
    "review_security": {"status": "skipped",  "updated_at": "2026-03-01T10:04:00.000Z"},
    "run_tests":       {"status": "complete", "updated_at": "2026-03-01T10:05:00.000Z"},
    "docs":            {"status": "complete", "updated_at": "2026-03-01T10:06:00.000Z"},
    "user_verification": {"status": "complete", "updated_at": "2026-03-01T10:07:00.000Z"}
  }
}'
RESULT1=$(call_read_state "$SID")
RESULT2=$(call_read_state "$SID")

RUN_TESTS_1=$(get_step_status_from_json "$RESULT1" "run_tests")
RUN_TESTS_2=$(get_step_status_from_json "$RESULT2" "run_tests")
REVIEW_1=$(get_step_status_from_json "$RESULT1" "review_security")
REVIEW_2=$(get_step_status_from_json "$RESULT2" "review_security")

if [ "$RUN_TESTS_1" = "complete" ] && [ "$RUN_TESTS_1" = "$RUN_TESTS_2" ]; then
    pass "M6a. already-migrated state: run_tests=complete unchanged on second call"
else
    fail "M6a. run_tests mismatch: first=$RUN_TESTS_1 second=$RUN_TESTS_2"
fi

if [ "$REVIEW_1" = "skipped" ] && [ "$REVIEW_1" = "$REVIEW_2" ]; then
    pass "M6b. already-migrated state: review_security=skipped unchanged on second call"
else
    fail "M6b. review_security mismatch: first=$REVIEW_1 second=$REVIEW_2"
fi

CODE_KEY_1=$(has_key_in_steps "$RESULT1" "code")
CODE_KEY_2=$(has_key_in_steps "$RESULT2" "code")
if [ "$CODE_KEY_1" = "no" ] && [ "$CODE_KEY_2" = "no" ]; then
    pass "M6c. code key absent in both calls (no double-migration artifact)"
else
    fail "M6c. code key present in migrated state: first=$CODE_KEY_1 second=$CODE_KEY_2"
fi

# M7: cwd, git_branch, created_at preserved through migration
SID="m7-$$-$RANDOM"
write_state_file "$SID" '{
  "version": 1,
  "session_id": "'"$SID"'",
  "created_at": "2026-01-15T08:30:00.000Z",
  "cwd": "/home/user/project",
  "git_branch": "feature/my-branch",
  "steps": {
    "research": {"status": "complete", "updated_at": "2026-01-15T08:31:00.000Z"},
    "code":     {"status": "complete", "updated_at": "2026-01-15T08:34:00.000Z"},
    "verify":   {"status": "pending",  "updated_at": null},
    "docs":     {"status": "pending",  "updated_at": null},
    "user_verification": {"status": "pending", "updated_at": null}
  }
}'
RESULT=$(call_read_state "$SID")

CWD_VAL=$(echo "$RESULT" | node -e "
let b=''; process.stdin.on('data',c=>b+=c);
process.stdin.on('end',()=>{
  try{const s=JSON.parse(b);console.log(s.cwd||'absent');}
  catch(e){console.log('error');}
})
" 2>/dev/null || echo "error")
if [ "$CWD_VAL" = "/home/user/project" ]; then
    pass "M7a. cwd preserved through migration"
else
    fail "M7a. expected cwd=/home/user/project, got: $CWD_VAL"
fi

BRANCH_VAL=$(echo "$RESULT" | node -e "
let b=''; process.stdin.on('data',c=>b+=c);
process.stdin.on('end',()=>{
  try{const s=JSON.parse(b);console.log(s.git_branch||'absent');}
  catch(e){console.log('error');}
})
" 2>/dev/null || echo "error")
if [ "$BRANCH_VAL" = "feature/my-branch" ]; then
    pass "M7b. git_branch preserved through migration"
else
    fail "M7b. expected git_branch=feature/my-branch, got: $BRANCH_VAL"
fi

CREATED_AT_VAL=$(echo "$RESULT" | node -e "
let b=''; process.stdin.on('data',c=>b+=c);
process.stdin.on('end',()=>{
  try{const s=JSON.parse(b);console.log(s.created_at||'absent');}
  catch(e){console.log('error');}
})
" 2>/dev/null || echo "error")
if [ "$CREATED_AT_VAL" = "2026-01-15T08:30:00.000Z" ]; then
    pass "M7c. created_at preserved through migration"
else
    fail "M7c. expected created_at=2026-01-15T08:30:00.000Z, got: $CREATED_AT_VAL"
fi

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------

echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi
