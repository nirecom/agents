#!/bin/bash
# Test suite for workflow state machine:
#   claude-global/hooks/workflow-gate.js   (PreToolUse commit gate)
#   claude-global/hooks/session-start.js   (SessionStart hook)
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GATE_HOOK="$DOTFILES_DIR/claude-global/hooks/workflow-gate.js"
MARK_HOOK="$DOTFILES_DIR/claude-global/hooks/workflow-mark.js"
SESSION_START="$DOTFILES_DIR/claude-global/hooks/session-start.js"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

# Portable timeout: use system timeout if available, else perl alarm
run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 180 "$@"
    else
        perl -e 'alarm 180; exec @ARGV' -- "$@"
    fi
}

# ---------------------------------------------------------------------------
# Temporary git repo setup
# ---------------------------------------------------------------------------

TMPDIR_BASE=$(mktemp -d)
WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
mkdir -p "$WORKFLOW_DIR"
export CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

setup_repo() {
    local repo="$TMPDIR_BASE/repo-$RANDOM"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q -m "initial"
    echo "$repo"
}

# Create the workflow/<session-id>.json state file in WORKFLOW_DIR
# Usage: write_state <session_id> <json_content>
write_state() {
    local sid="${1:-}"
    local json="${2:-}"
    mkdir -p "$WORKFLOW_DIR"
    printf '%s' "$json" > "$WORKFLOW_DIR/${sid}.json"
}

# ---------------------------------------------------------------------------
# Helper: all-complete state JSON
# ---------------------------------------------------------------------------

ALL_COMPLETE_JSON() {
    local sid="${1:-test-session}"
    cat <<EOF
{
  "version": 1,
  "session_id": "$sid",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "complete", "updated_at": "2026-04-11T10:01:00.000Z"},
    "plan":              {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "write_tests":       {"status": "complete", "updated_at": "2026-04-11T10:03:00.000Z"},
    "review_security":   {"status": "complete", "updated_at": "2026-04-11T10:04:30.000Z"},
    "run_tests":         {"status": "complete", "updated_at": "2026-04-11T10:05:00.000Z"},
    "docs":              {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"}
  }
}
EOF
}

ALL_PENDING_JSON() {
    local sid="${1:-test-session}"
    cat <<EOF
{
  "version": 1,
  "session_id": "$sid",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "pending", "updated_at": null},
    "plan":              {"status": "pending", "updated_at": null},
    "write_tests":       {"status": "pending", "updated_at": null},
    "review_security":   {"status": "pending", "updated_at": null},
    "run_tests":         {"status": "pending", "updated_at": null},
    "docs":              {"status": "pending", "updated_at": null},
    "user_verification": {"status": "pending", "updated_at": null}
  }
}
EOF
}

COMMIT_JSON='{"tool_name":"Bash","tool_input":{"command":"git commit -m \"test\""},"session_id":"test-session"}'

# ---------------------------------------------------------------------------
# workflow-gate.js helpers
# ---------------------------------------------------------------------------

run_gate() {
    local repo="$1" json="$2"
    echo "$json" | CLAUDE_PROJECT_DIR="$repo" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node "$GATE_HOOK" 2>/dev/null || true
}

expect_approve_gate() {
    local desc="$1" repo="$2" json="$3"
    local result
    result=$(run_gate "$repo" "$json")
    if echo "$result" | grep -q '"approve"'; then pass "$desc"
    else fail "$desc — expected approve, got: $result"; fi
}

expect_block_gate() {
    local desc="$1" repo="$2" json="$3"
    local result
    result=$(run_gate "$repo" "$json")
    if echo "$result" | grep -q '"block"'; then pass "$desc"
    else fail "$desc — expected block, got: $result"; fi
}

expect_block_gate_contains() {
    local desc="$1" repo="$2" json="$3" needle="$4"
    local result
    result=$(run_gate "$repo" "$json")
    if echo "$result" | grep -q '"block"' && echo "$result" | grep -qi "$needle"; then
        pass "$desc"
    else
        fail "$desc — expected block containing '$needle', got: $result"
    fi
}

# ---------------------------------------------------------------------------
# workflow-mark.js helpers
# ---------------------------------------------------------------------------

run_mark_hook() {
    local repo="$1" json="$2"
    echo "$json" | CLAUDE_PROJECT_DIR="$repo" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node "$MARK_HOOK" 2>/dev/null || true
}

# Read the state file and extract steps.<step>.status using node.
# Prints the status string, or "MISSING" if the file / step is absent.
read_state_status() {
    local sid="$1" step="$2"
    local state_file="$WORKFLOW_DIR/${sid}.json"
    if [ ! -f "$state_file" ]; then
        echo "MISSING"
        return
    fi
    node -e "
      try {
        const s = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
        const step = s.steps && s.steps['$step'];
        console.log(step && step.status ? step.status : 'MISSING');
      } catch (e) { console.log('MISSING'); }
    " "$state_file" 2>/dev/null || echo "MISSING"
}

expect_state_step() {
    local desc="$1" sid="$2" step="$3" expected="$4"
    local actual
    actual=$(read_state_status "$sid" "$step")
    if [ "$actual" = "$expected" ]; then
        pass "$desc"
    else
        fail "$desc — expected steps.$step.status=$expected, got: $actual"
    fi
}

expect_no_state_change() {
    local desc="$1" sid="$2" step="$3" expected_unchanged="$4"
    local actual
    actual=$(read_state_status "$sid" "$step")
    if [ "$actual" = "$expected_unchanged" ]; then
        pass "$desc"
    else
        fail "$desc — expected steps.$step.status to remain $expected_unchanged, got: $actual"
    fi
}

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
    "plan":              {"status": "complete",  "updated_at": "2026-04-11T10:02:00.000Z"},
    "write_tests":       {"status": "complete",  "updated_at": "2026-04-11T10:03:00.000Z"},
    "review_security":   {"status": "complete",  "updated_at": "2026-04-11T10:04:30.000Z"},
    "run_tests":         {"status": "complete",  "updated_at": "2026-04-11T10:05:00.000Z"},
    "docs":              {"status": "complete",  "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "complete",  "updated_at": "2026-04-11T10:07:00.000Z"}
  }
}'
expect_approve_gate "2. research skipped, rest complete → approve" "$REPO" "$COMMIT_JSON"

# Test 3: plan skipped, rest complete → approve
REPO=$(setup_repo)
write_state "test-session" '{
  "version": 1,
  "session_id": "test-session",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "complete",  "updated_at": "2026-04-11T10:01:00.000Z"},
    "plan":              {"status": "skipped",   "updated_at": "2026-04-11T10:02:00.000Z"},
    "write_tests":       {"status": "complete",  "updated_at": "2026-04-11T10:03:00.000Z"},
    "review_security":   {"status": "complete",  "updated_at": "2026-04-11T10:04:30.000Z"},
    "run_tests":         {"status": "complete",  "updated_at": "2026-04-11T10:05:00.000Z"},
    "docs":              {"status": "complete",  "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "complete",  "updated_at": "2026-04-11T10:07:00.000Z"}
  }
}'
expect_approve_gate "3. plan skipped, rest complete → approve" "$REPO" "$COMMIT_JSON"

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

# Test 5: research pending → block, message contains "research"
REPO=$(setup_repo)
write_state "test-session" '{
  "version": 1,
  "session_id": "test-session",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "pending",  "updated_at": null},
    "plan":              {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "write_tests":       {"status": "complete", "updated_at": "2026-04-11T10:03:00.000Z"},
    "review_security":   {"status": "complete", "updated_at": "2026-04-11T10:04:30.000Z"},
    "run_tests":         {"status": "complete", "updated_at": "2026-04-11T10:05:00.000Z"},
    "docs":              {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"}
  }
}'
expect_block_gate_contains "5. research pending → block with 'research' in message" "$REPO" "$COMMIT_JSON" "research"

# Test 6: Multiple steps pending (plan, write_tests) → block, message contains both
REPO=$(setup_repo)
write_state "test-session" '{
  "version": 1,
  "session_id": "test-session",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "complete", "updated_at": "2026-04-11T10:01:00.000Z"},
    "plan":              {"status": "pending",  "updated_at": null},
    "write_tests":       {"status": "pending",  "updated_at": null},
    "review_security":   {"status": "complete", "updated_at": "2026-04-11T10:04:30.000Z"},
    "run_tests":         {"status": "complete", "updated_at": "2026-04-11T10:05:00.000Z"},
    "docs":              {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"}
  }
}'
RESULT=$(run_gate "$REPO" "$COMMIT_JSON")
if echo "$RESULT" | grep -q '"block"' && echo "$RESULT" | grep -qi "plan" && echo "$RESULT" | grep -qi "write_tests"; then
    pass "6. Multiple pending steps → block, message contains both step names"
else
    fail "6. Multiple pending steps → expected block with 'plan' and 'write_tests', got: $RESULT"
fi

# Test 7: run_tests set to skipped (non-skippable) → block
REPO=$(setup_repo)
write_state "test-session" '{
  "version": 1,
  "session_id": "test-session",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "complete", "updated_at": "2026-04-11T10:01:00.000Z"},
    "plan":              {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "write_tests":       {"status": "complete", "updated_at": "2026-04-11T10:03:00.000Z"},
    "review_security":   {"status": "complete", "updated_at": "2026-04-11T10:04:30.000Z"},
    "run_tests":         {"status": "skipped",  "updated_at": "2026-04-11T10:05:00.000Z"},
    "docs":              {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"}
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
    "plan":              {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "write_tests":       {"status": "complete", "updated_at": "2026-04-11T10:03:00.000Z"},
    "review_security":   {"status": "complete", "updated_at": "2026-04-11T10:04:30.000Z"},
    "run_tests":         {"status": "complete", "updated_at": "2026-04-11T10:05:00.000Z"},
    "docs":              {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "skipped",  "updated_at": "2026-04-11T10:07:00.000Z"}
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

# ---------------------------------------------------------------------------
# State file helpers
# ---------------------------------------------------------------------------

get_state_file() {
    local sid="$1"
    echo "$WORKFLOW_DIR/${sid}.json"
}

read_state_field() {
    # read_state_field <state_file> <step> <field>
    # Uses node to parse JSON — avoids jq dependency
    node -e "let b='';process.stdin.on('data',c=>b+=c);process.stdin.on('end',()=>console.log(JSON.parse(b).steps['$2']['$3']))" < "$1" 2>/dev/null || echo "null"
}

# ---------------------------------------------------------------------------
# session-start.js helpers
# ---------------------------------------------------------------------------

run_session_start() {
    local json="$1"
    shift
    echo "$json" | "$@" node "$SESSION_START" 2>/dev/null
}

# ---------------------------------------------------------------------------
# === session-start.js: Normal cases ===
# ---------------------------------------------------------------------------

echo ""
echo "=== session-start: Normal cases ==="

# Test 35: With CLAUDE_ENV_FILE set → file contains CLAUDE_SESSION_ID=abc123
REPO=$(setup_repo)
ENV_FILE="$TMPDIR_BASE/claude-env-$RANDOM.txt"
touch "$ENV_FILE"
echo '{"session_id":"abc123"}' | CLAUDE_PROJECT_DIR="$REPO" CLAUDE_ENV_FILE="$ENV_FILE" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node "$SESSION_START" 2>/dev/null || true
if grep -qx "CLAUDE_SESSION_ID=abc123" "$ENV_FILE" 2>/dev/null; then
    pass "35. CLAUDE_ENV_FILE → file contains KEY=VALUE line (no export prefix)"
else
    fail "35. CLAUDE_ENV_FILE → expected exact line 'CLAUDE_SESSION_ID=abc123', file content: $(cat "$ENV_FILE" 2>/dev/null || echo '(not found)')"
fi

# Test 36: stdout is valid JSON (may include additionalContext)
REPO=$(setup_repo)
STDOUT=$(echo '{"session_id":"abc123"}' | CLAUDE_PROJECT_DIR="$REPO" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node "$SESSION_START" 2>/dev/null || true)
if [[ "$STDOUT" == "{"* ]] || [[ "$STDOUT" == "" ]]; then
    pass "36. session-start stdout is valid JSON"
else
    fail "36. session-start stdout → expected valid JSON starting with '{', got: '$STDOUT'"
fi

# Test 37: Zombie cleanup — state file with all updated_at 8 days ago → deleted
REPO=$(setup_repo)
SID_ZOMBIE="zombie-$RANDOM"
mkdir -p "$WORKFLOW_DIR"
ZOMBIE_FILE="$WORKFLOW_DIR/${SID_ZOMBIE}.json"
# updated_at values set to 8 days ago in JSON content — cleanup checks JSON timestamps
EIGHT_DAYS_AGO=$(node -e "console.log(new Date(Date.now()-8*24*60*60*1000).toISOString())" 2>/dev/null || echo "2026-04-03T10:00:00.000Z")
cat > "$ZOMBIE_FILE" <<EOF
{
  "version": 1,
  "session_id": "$SID_ZOMBIE",
  "created_at": "$EIGHT_DAYS_AGO",
  "steps": {
    "research":          {"status": "complete", "updated_at": "$EIGHT_DAYS_AGO"},
    "plan":              {"status": "complete", "updated_at": "$EIGHT_DAYS_AGO"},
    "write_tests":       {"status": "complete", "updated_at": "$EIGHT_DAYS_AGO"},
    "review_security":   {"status": "complete", "updated_at": "$EIGHT_DAYS_AGO"},
    "run_tests":         {"status": "complete", "updated_at": "$EIGHT_DAYS_AGO"},
    "docs":              {"status": "complete", "updated_at": "$EIGHT_DAYS_AGO"},
    "user_verification": {"status": "complete", "updated_at": "$EIGHT_DAYS_AGO"}
  }
}
EOF
echo '{"session_id":"new-session"}' | CLAUDE_PROJECT_DIR="$REPO" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node "$SESSION_START" 2>/dev/null || true
if [ ! -f "$ZOMBIE_FILE" ]; then
    pass "37. Zombie cleanup: 8-day-old state file deleted"
else
    fail "37. Zombie cleanup: state file still exists: $ZOMBIE_FILE"
fi

# Test 38: State file with updated_at 3 days ago → NOT deleted
REPO=$(setup_repo)
SID_RECENT="recent-$RANDOM"
mkdir -p "$WORKFLOW_DIR"
RECENT_FILE="$WORKFLOW_DIR/${SID_RECENT}.json"
THREE_DAYS_AGO=$(node -e "console.log(new Date(Date.now()-3*24*60*60*1000).toISOString())" 2>/dev/null || echo "2026-04-08T10:00:00.000Z")
cat > "$RECENT_FILE" <<EOF
{
  "version": 1,
  "session_id": "$SID_RECENT",
  "created_at": "$THREE_DAYS_AGO",
  "steps": {
    "research":          {"status": "complete", "updated_at": "$THREE_DAYS_AGO"},
    "plan":              {"status": "complete", "updated_at": "$THREE_DAYS_AGO"},
    "write_tests":       {"status": "complete", "updated_at": "$THREE_DAYS_AGO"},
    "review_security":   {"status": "complete", "updated_at": "$THREE_DAYS_AGO"},
    "run_tests":         {"status": "complete", "updated_at": "$THREE_DAYS_AGO"},
    "docs":              {"status": "complete", "updated_at": "$THREE_DAYS_AGO"},
    "user_verification": {"status": "complete", "updated_at": "$THREE_DAYS_AGO"}
  }
}
EOF
echo '{"session_id":"new-session"}' | CLAUDE_PROJECT_DIR="$REPO" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node "$SESSION_START" 2>/dev/null || true
if [ -f "$RECENT_FILE" ]; then
    pass "38. Recent state file (3 days) NOT deleted by zombie cleanup"
else
    fail "38. Recent state file was incorrectly deleted"
fi

# ---------------------------------------------------------------------------
# === session-start.js: Edge cases ===
# ---------------------------------------------------------------------------

echo ""
echo "=== session-start: Edge cases ==="

# Test 39: CLAUDE_ENV_FILE not set → exits 0, no error
REPO=$(setup_repo)
if echo '{"session_id":"abc123"}' | CLAUDE_PROJECT_DIR="$REPO" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node "$SESSION_START" 2>/dev/null; then
    pass "39. CLAUDE_ENV_FILE not set → exits 0"
else
    fail "39. CLAUDE_ENV_FILE not set → expected exit 0, got non-zero"
fi

# Test 40: .git/workflow/ directory doesn't exist → cleanup runs without error
REPO=$(setup_repo)
# Do NOT create the workflow directory — verify no crash
if echo '{"session_id":"abc123"}' | CLAUDE_PROJECT_DIR="$REPO" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node "$SESSION_START" 2>/dev/null; then
    pass "40. Missing workflow dir → cleanup runs without error"
else
    fail "40. Missing workflow dir → session-start crashed (exit non-zero)"
fi

# Test 41: stdin is invalid JSON → exits 0 (fail-open for SessionStart)
REPO=$(setup_repo)
if echo 'NOT VALID JSON' | CLAUDE_PROJECT_DIR="$REPO" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node "$SESSION_START" 2>/dev/null; then
    pass "41. Invalid JSON stdin → exits 0 (fail-open)"
else
    fail "41. Invalid JSON stdin → expected exit 0 (fail-open), got non-zero"
fi

# ---------------------------------------------------------------------------
# === is-private-repo.js: toNativePath / resolveRepoDir ===
# ---------------------------------------------------------------------------

echo ""
echo "=== is-private-repo: toNativePath / resolveRepoDir ==="

# Test 42: toNativePath converts /c/... to C:/... on win32
RESULT=$(cd "$DOTFILES_DIR" && node -e "
  Object.defineProperty(process,'platform',{value:'win32',configurable:true});
  const {toNativePath}=require('./claude-global/hooks/lib/is-private-repo.js');
  console.log(toNativePath('/c/git/dotfiles'));
" 2>/dev/null)
[ "$RESULT" = "C:/git/dotfiles" ] && pass "42. toNativePath /c/git/dotfiles → C:/git/dotfiles" || fail "42. toNativePath: expected C:/git/dotfiles, got '$RESULT'"

# Test 43: toNativePath handles different drive letters
RESULT=$(cd "$DOTFILES_DIR" && node -e "
  Object.defineProperty(process,'platform',{value:'win32',configurable:true});
  const {toNativePath}=require('./claude-global/hooks/lib/is-private-repo.js');
  console.log(toNativePath('/d/foo/bar'));
" 2>/dev/null)
[ "$RESULT" = "D:/foo/bar" ] && pass "43. toNativePath /d/foo/bar → D:/foo/bar" || fail "43. toNativePath: expected D:/foo/bar, got '$RESULT'"

# Test 44: toNativePath leaves already-Windows paths unchanged
RESULT=$(cd "$DOTFILES_DIR" && node -e "
  Object.defineProperty(process,'platform',{value:'win32',configurable:true});
  const {toNativePath}=require('./claude-global/hooks/lib/is-private-repo.js');
  console.log(toNativePath('C:/git/dotfiles'));
" 2>/dev/null)
[ "$RESULT" = "C:/git/dotfiles" ] && pass "44. toNativePath C:/git/dotfiles → C:/git/dotfiles (no change)" || fail "44. toNativePath: expected C:/git/dotfiles, got '$RESULT'"

# Test 45: toNativePath leaves relative paths unchanged
RESULT=$(cd "$DOTFILES_DIR" && node -e "
  Object.defineProperty(process,'platform',{value:'win32',configurable:true});
  const {toNativePath}=require('./claude-global/hooks/lib/is-private-repo.js');
  console.log(toNativePath('.'));
" 2>/dev/null)
[ "$RESULT" = "." ] && pass "45. toNativePath '.' → '.' (no change)" || fail "45. toNativePath: expected '.', got '$RESULT'"

# Test 46: toNativePath leaves Linux-style non-drive paths unchanged on win32
RESULT=$(cd "$DOTFILES_DIR" && node -e "
  Object.defineProperty(process,'platform',{value:'win32',configurable:true});
  const {toNativePath}=require('./claude-global/hooks/lib/is-private-repo.js');
  console.log(toNativePath('/usr/local/bin'));
" 2>/dev/null)
[ "$RESULT" = "/usr/local/bin" ] && pass "46. toNativePath /usr/local/bin → /usr/local/bin (no change)" || fail "46. toNativePath: expected /usr/local/bin, got '$RESULT'"

# Test 47: toNativePath handles single-char drive with trailing slash
RESULT=$(cd "$DOTFILES_DIR" && node -e "
  Object.defineProperty(process,'platform',{value:'win32',configurable:true});
  const {toNativePath}=require('./claude-global/hooks/lib/is-private-repo.js');
  console.log(toNativePath('/z/'));
" 2>/dev/null)
[ "$RESULT" = "Z:/" ] && pass "47. toNativePath /z/ → Z:/" || fail "47. toNativePath: expected Z:/, got '$RESULT'"

# Test 48: resolveRepoDir converts WSL path via toNativePath on win32 (CLAUDE_PROJECT_DIR unset)
RESULT=$(cd "$DOTFILES_DIR" && node -e "
  delete process.env.HOOK_CWD; delete process.env.CLAUDE_PROJECT_DIR;
  Object.defineProperty(process,'platform',{value:'win32',configurable:true});
  const {resolveRepoDir}=require('./claude-global/hooks/lib/is-private-repo.js');
  console.log(resolveRepoDir('git -C /c/git/dotfiles commit'));
" 2>/dev/null)
[ "$RESULT" = "C:/git/dotfiles" ] && pass "48. resolveRepoDir: WSL path /c/git/dotfiles → C:/git/dotfiles on win32" || fail "48. resolveRepoDir: expected C:/git/dotfiles, got '$RESULT'"

# Test 49: resolveRepoDir returns "." when no -C flag and CLAUDE_PROJECT_DIR unset
RESULT=$(cd "$DOTFILES_DIR" && node -e "
  delete process.env.HOOK_CWD; delete process.env.CLAUDE_PROJECT_DIR;
  Object.defineProperty(process,'platform',{value:'win32',configurable:true});
  const {resolveRepoDir}=require('./claude-global/hooks/lib/is-private-repo.js');
  console.log(resolveRepoDir('git commit'));
" 2>/dev/null)
[ "$RESULT" = "." ] && pass "49. resolveRepoDir: no -C flag → '.'" || fail "49. resolveRepoDir: expected '.', got '$RESULT'"

# ---------------------------------------------------------------------------
# === workflow-mark: New hook ===
# ---------------------------------------------------------------------------
# TDD: workflow-mark.js does NOT exist yet. These tests are expected to FAIL
# with a "Cannot find module" / MODULE_NOT_FOUND style error until the hook is
# implemented. Each test asserts state changes (or lack thereof) via the state
# file rather than hook stdout so the failure mode is always a node error from
# the missing hook, surfaced as state==MISSING on our side.

echo ""
echo "=== workflow-mark: New hook — Normal cases ==="

# Helper: build a PostToolUse-style hook input JSON with a Bash command and
# tool_response.exit_code=0. Escape embedded double quotes in $cmd.
build_mark_json() {
    local cmd="$1" sid="${2:-test-session}"
    # Escape backslashes and double quotes in $cmd for JSON
    local esc=${cmd//\\/\\\\}
    esc=${esc//\"/\\\"}
    printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":{"exit_code":0,"stdout":"%s\\n","stderr":""},"session_id":"%s"}' "$esc" "$esc" "$sid"
}

# Test N1: echo "<<WORKFLOW_MARK_STEP:research:complete>>" (double-quoted)
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
N1_JSON=$(build_mark_json 'echo "<<WORKFLOW_MARK_STEP_research_complete>>"')
run_mark_hook "$REPO" "$N1_JSON" >/dev/null
expect_state_step "N1. echo \"<<...>>\" (double-quoted) → research=complete" "test-session" "research" "complete"

# Test N2: echo '<<WORKFLOW_MARK_STEP_research_complete>>' (single-quoted)
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
N2_JSON=$(build_mark_json "echo '<<WORKFLOW_MARK_STEP_research_complete>>'")
run_mark_hook "$REPO" "$N2_JSON" >/dev/null
expect_state_step "N2. echo '<<...>>' (single-quoted) → research=complete" "test-session" "research" "complete"

# Test N3: status skipped on research → recorded
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
N3_JSON=$(build_mark_json 'echo "<<WORKFLOW_MARK_STEP_research_skipped>>"')
run_mark_hook "$REPO" "$N3_JSON" >/dev/null
expect_state_step "N3. status=skipped on research → recorded" "test-session" "research" "skipped"

# Test N4: MARK_STEP for write_tests is rejected (evidence-based step, stays pending)
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
N4_JSON=$(build_mark_json 'echo "<<WORKFLOW_MARK_STEP_write_tests_in_progress>>"')
run_mark_hook "$REPO" "$N4_JSON" >/dev/null
expect_state_step "N4. MARK_STEP for write_tests → rejected (stays pending)" "test-session" "write_tests" "pending"

echo ""
echo "=== workflow-mark: New hook — Must-NOT-mark cases ==="

# Test F1: cat SKILL.md (marker in file contents, not a literal echo command)
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
F1_JSON=$(build_mark_json 'cat SKILL.md')
run_mark_hook "$REPO" "$F1_JSON" >/dev/null
expect_no_state_change "F1. cat SKILL.md with marker in stdout → unchanged" "test-session" "research" "pending"

# Test F2: git diff showing marker
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
F2_JSON=$(build_mark_json 'git diff')
run_mark_hook "$REPO" "$F2_JSON" >/dev/null
expect_no_state_change "F2. git diff showing marker → unchanged" "test-session" "research" "pending"

# Test F3: grep WORKFLOW_MARK_STEP file.sh
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
F3_JSON=$(build_mark_json 'grep WORKFLOW_MARK_STEP file.sh')
run_mark_hook "$REPO" "$F3_JSON" >/dev/null
expect_no_state_change "F3. grep WORKFLOW_MARK_STEP → unchanged" "test-session" "research" "pending"

# Test F4: echo piped to tee
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
F4_JSON=$(build_mark_json 'echo "<<WORKFLOW_MARK_STEP_research_complete>>" | tee /tmp/log')
run_mark_hook "$REPO" "$F4_JSON" >/dev/null
expect_no_state_change "F4. echo \"<<...>>\" | tee /tmp/log → unchanged" "test-session" "research" "pending"

# Test F5: cd /tmp && echo "<<...>>" (prefix chaining)
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
F5_JSON=$(build_mark_json 'cd /tmp && echo "<<WORKFLOW_MARK_STEP_research_complete>>"')
run_mark_hook "$REPO" "$F5_JSON" >/dev/null
expect_no_state_change "F5. cd /tmp && echo \"<<...>>\" (prefix chain) → unchanged" "test-session" "research" "pending"

# Test F6: echo "<<...>>" ; rm foo (trailing chain)
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
F6_JSON=$(build_mark_json 'echo "<<WORKFLOW_MARK_STEP_research_complete>>" ; rm foo')
run_mark_hook "$REPO" "$F6_JSON" >/dev/null
expect_no_state_change "F6. echo \"<<...>>\" ; rm foo (trailing chain) → unchanged" "test-session" "research" "pending"

# Test F7: echo " <<...>> " (inner spaces around marker inside quotes)
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
F7_JSON=$(build_mark_json 'echo " <<WORKFLOW_MARK_STEP_research_complete>> "')
run_mark_hook "$REPO" "$F7_JSON" >/dev/null
expect_no_state_change "F7. echo \" <<...>> \" (inner spaces) → unchanged" "test-session" "research" "pending"

# Test F8: 10KB padded command containing 'echo' as a substring but not as the command
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
F8_PAD=$(printf 'x%.0s' {1..10000})
F8_JSON=$(build_mark_json "node run.js --msg echoes-${F8_PAD}-end")
run_mark_hook "$REPO" "$F8_JSON" >/dev/null
expect_no_state_change "F8. 10KB padded command with 'echo' as substring → unchanged" "test-session" "research" "pending"

# Test F9: printf instead of echo
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
F9_JSON=$(build_mark_json 'printf "<<WORKFLOW_MARK_STEP_research_complete>>"')
run_mark_hook "$REPO" "$F9_JSON" >/dev/null
expect_no_state_change "F9. printf \"<<...>>\" (not echo) → unchanged" "test-session" "research" "pending"

echo ""
echo "=== workflow-mark: New hook — Error / edge cases ==="

# Test E1: unknown step "foo" → state unchanged, hook exit 0
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
E1_JSON=$(build_mark_json 'echo "<<WORKFLOW_MARK_STEP_foo_complete>>"')
run_mark_hook "$REPO" "$E1_JSON" >/dev/null
expect_no_state_change "E1. unknown step 'foo' → research unchanged" "test-session" "research" "pending"

# Test E2: unknown status "done" → state unchanged
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
E2_JSON=$(build_mark_json 'echo "<<WORKFLOW_MARK_STEP_research_done>>"')
run_mark_hook "$REPO" "$E2_JSON" >/dev/null
expect_no_state_change "E2. unknown status 'done' → research unchanged" "test-session" "research" "pending"

# Test E3: user_verification_complete via marker → REJECTED
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
E3_JSON=$(build_mark_json 'echo "<<WORKFLOW_MARK_STEP_user_verification_complete>>"')
run_mark_hook "$REPO" "$E3_JSON" >/dev/null
expect_no_state_change "E3. user_verification_complete via marker → REJECTED" "test-session" "user_verification" "pending"

# Test E4: user_verification_skipped via marker → REJECTED
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
E4_JSON=$(build_mark_json 'echo "<<WORKFLOW_MARK_STEP_user_verification_skipped>>"')
run_mark_hook "$REPO" "$E4_JSON" >/dev/null
expect_no_state_change "E4. user_verification_skipped via marker → REJECTED" "test-session" "user_verification" "pending"

# Test E5: session_id not in stdin AND CLAUDE_ENV_FILE unset →
#   state unchanged, hook stdout JSON contains "systemMessage", exit 0
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
E5_CMD='echo "<<WORKFLOW_MARK_STEP_research_complete>>"'
E5_ESC=${E5_CMD//\"/\\\"}
E5_JSON=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":{"exit_code":0,"stdout":"%s\\n","stderr":""}}' "$E5_ESC" "$E5_ESC")
E5_OUT=$(echo "$E5_JSON" | CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" env -u CLAUDE_ENV_FILE node "$MARK_HOOK" 2>/dev/null || true)
E5_EXIT=$?
expect_no_state_change "E5a. no session_id → research unchanged" "test-session" "research" "pending"
if echo "$E5_OUT" | grep -q "additionalContext"; then
    pass "E5b. no session_id → stdout JSON contains additionalContext"
else
    fail "E5b. no session_id → expected additionalContext in stdout, got: $E5_OUT"
fi
if [ "$E5_EXIT" = "0" ]; then
    pass "E5c. no session_id → hook exit 0"
else
    fail "E5c. no session_id → expected exit 0, got: $E5_EXIT"
fi

# Test E6: private repo test deferred — hard to fake without network.
# TODO: Add test once we can stub is-private-repo.js or use a fixture repo
# with a known-private remote URL. For now, skip.

# Test E7: tool_response.exit_code=1 → state unchanged (echo supposedly failed)
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
E7_CMD='echo "<<WORKFLOW_MARK_STEP_research_complete>>"'
E7_ESC=${E7_CMD//\"/\\\"}
E7_JSON=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":{"exit_code":1,"stdout":"","stderr":"oops"},"session_id":"test-session"}' "$E7_ESC")
run_mark_hook "$REPO" "$E7_JSON" >/dev/null
expect_no_state_change "E7. tool_response.exit_code=1 → unchanged" "test-session" "research" "pending"

# Test E8: tool_name != Bash (e.g. Write) → ignored, state unchanged
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
E8_JSON='{"tool_name":"Write","tool_input":{"file_path":"/tmp/foo","content":"<<WORKFLOW_MARK_STEP_research_complete>>"},"tool_response":{"success":true},"session_id":"test-session"}'
run_mark_hook "$REPO" "$E8_JSON" >/dev/null
expect_no_state_change "E8. tool_name=Write → unchanged" "test-session" "research" "pending"

echo ""
echo "=== workflow-mark: New hook — Idempotency ==="

# Test I1: same marker applied twice → state valid, status=complete
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
I1_JSON=$(build_mark_json 'echo "<<WORKFLOW_MARK_STEP_research_complete>>"')
run_mark_hook "$REPO" "$I1_JSON" >/dev/null
run_mark_hook "$REPO" "$I1_JSON" >/dev/null
expect_state_step "I1. same marker applied twice → research=complete (idempotent)" "test-session" "research" "complete"

# Test I2: concurrent write race — deferred. Platform-dependent and requires
# deterministic interleaving; skip until we have a fixture for file-lock testing.

# ---------------------------------------------------------------------------
# === workflow-mark: RESET_FROM marker ===
# ---------------------------------------------------------------------------

echo ""
echo "=== workflow-mark: RESET_FROM marker — Normal cases ==="

# Helper: build a hook input JSON for WORKFLOW_RESET_FROM commands.
# Like build_mark_json but takes the raw command string (no escaping needed
# for the reset commands which use only alphanumeric step names).
build_reset_json() {
    local cmd="$1" sid="${2:-test-session}"
    local esc=${cmd//\\/\\\\}
    esc=${esc//\"/\\\"}
    printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":{"exit_code":0,"stdout":"%s\\n","stderr":""},"session_id":"%s"}' "$esc" "$esc" "$sid"
}

# Test R1: RESET_FROM_write_tests on ALL_COMPLETE → research=complete, plan=complete,
#          write_tests=pending, review_security=pending, run_tests=pending, docs=pending,
#          user_verification=pending
REPO=$(setup_repo)
write_state "test-session" "$(ALL_COMPLETE_JSON test-session)"
R1_JSON=$(build_reset_json 'echo "<<WORKFLOW_RESET_FROM_write_tests>>"')
run_mark_hook "$REPO" "$R1_JSON" >/dev/null
expect_state_step "R1a. RESET_FROM:write_tests → research=complete"        "test-session" "research"        "complete"
expect_state_step "R1b. RESET_FROM:write_tests → plan=complete"            "test-session" "plan"            "complete"
expect_state_step "R1c. RESET_FROM:write_tests → write_tests=pending"      "test-session" "write_tests"     "pending"
expect_state_step "R1d. RESET_FROM:write_tests → review_security=pending"  "test-session" "review_security" "pending"
expect_state_step "R1e. RESET_FROM:write_tests → run_tests=pending"        "test-session" "run_tests"       "pending"
expect_state_step "R1f. RESET_FROM:write_tests → docs=pending"             "test-session" "docs"            "pending"
expect_state_step "R1g. RESET_FROM:write_tests → user_verification=pending" "test-session" "user_verification" "pending"

# Test R2: RESET_FROM_research → all steps pending (nothing before research)
REPO=$(setup_repo)
write_state "test-session" "$(ALL_COMPLETE_JSON test-session)"
R2_JSON=$(build_reset_json 'echo "<<WORKFLOW_RESET_FROM_research>>"')
run_mark_hook "$REPO" "$R2_JSON" >/dev/null
expect_state_step "R2a. RESET_FROM:research → research=pending"             "test-session" "research"          "pending"
expect_state_step "R2b. RESET_FROM:research → plan=pending"                 "test-session" "plan"              "pending"
expect_state_step "R2c. RESET_FROM:research → write_tests=pending"          "test-session" "write_tests"       "pending"
expect_state_step "R2d. RESET_FROM:research → review_security=pending"      "test-session" "review_security"   "pending"
expect_state_step "R2e. RESET_FROM:research → run_tests=pending"            "test-session" "run_tests"         "pending"
expect_state_step "R2f. RESET_FROM:research → docs=pending"                 "test-session" "docs"              "pending"
expect_state_step "R2g. RESET_FROM:research → user_verification=pending"    "test-session" "user_verification" "pending"

# Test R3: RESET_FROM_user_verification → all steps before it complete, user_verification=pending
REPO=$(setup_repo)
write_state "test-session" "$(ALL_PENDING_JSON test-session)"
R3_JSON=$(build_reset_json 'echo "<<WORKFLOW_RESET_FROM_user_verification>>"')
run_mark_hook "$REPO" "$R3_JSON" >/dev/null
expect_state_step "R3a. RESET_FROM:user_verification → research=complete"        "test-session" "research"          "complete"
expect_state_step "R3b. RESET_FROM:user_verification → plan=complete"            "test-session" "plan"              "complete"
expect_state_step "R3c. RESET_FROM:user_verification → write_tests=complete"     "test-session" "write_tests"       "complete"
expect_state_step "R3d. RESET_FROM:user_verification → review_security=complete" "test-session" "review_security"   "complete"
expect_state_step "R3e. RESET_FROM:user_verification → run_tests=complete"       "test-session" "run_tests"         "complete"
expect_state_step "R3f. RESET_FROM:user_verification → docs=complete"            "test-session" "docs"              "complete"
expect_state_step "R3g. RESET_FROM:user_verification → user_verification=pending" "test-session" "user_verification" "pending"

# Test R4: single-quote variant → NOT processed (SQ RESET_FROM removed from source)
REPO=$(setup_repo)
write_state "test-session" "$(ALL_COMPLETE_JSON test-session)"
R4_JSON=$(build_reset_json "echo '<<WORKFLOW_RESET_FROM_write_tests>>'")
run_mark_hook "$REPO" "$R4_JSON" >/dev/null
expect_no_state_change "R4a. single-quote RESET_FROM → research unchanged (complete)"    "test-session" "research"    "complete"
expect_no_state_change "R4b. single-quote RESET_FROM → plan unchanged (complete)"        "test-session" "plan"        "complete"
expect_no_state_change "R4c. single-quote RESET_FROM → write_tests unchanged (complete)" "test-session" "write_tests" "complete"
expect_no_state_change "R4d. single-quote RESET_FROM → run_tests unchanged (complete)"   "test-session" "run_tests"   "complete"

echo ""
echo "=== workflow-mark: RESET_FROM marker — Must-NOT-match cases ==="

# Test RF1: echo "<<WORKFLOW_RESET_FROM_write_tests>>" | tee /tmp/log → state unchanged
REPO=$(setup_repo)
write_state "test-session" "$(ALL_COMPLETE_JSON test-session)"
RF1_JSON=$(build_reset_json 'echo "<<WORKFLOW_RESET_FROM_write_tests>>" | tee /tmp/log')
run_mark_hook "$REPO" "$RF1_JSON" >/dev/null
expect_no_state_change "RF1. echo \"<<...>>\" | tee /tmp/log → write_tests unchanged (complete)" "test-session" "write_tests" "complete"

# Test RF2: cd /tmp && echo "<<WORKFLOW_RESET_FROM_write_tests>>" → state unchanged
REPO=$(setup_repo)
write_state "test-session" "$(ALL_COMPLETE_JSON test-session)"
RF2_JSON=$(build_reset_json 'cd /tmp && echo "<<WORKFLOW_RESET_FROM_write_tests>>"')
run_mark_hook "$REPO" "$RF2_JSON" >/dev/null
expect_no_state_change "RF2. cd && echo \"<<...>>\" (prefix chain) → write_tests unchanged (complete)" "test-session" "write_tests" "complete"

# Test RF3: printf "<<WORKFLOW_RESET_FROM_write_tests>>" → state unchanged
REPO=$(setup_repo)
write_state "test-session" "$(ALL_COMPLETE_JSON test-session)"
RF3_JSON=$(build_reset_json 'printf "<<WORKFLOW_RESET_FROM_write_tests>>"')
run_mark_hook "$REPO" "$RF3_JSON" >/dev/null
expect_no_state_change "RF3. printf \"<<...>>\" (not echo) → write_tests unchanged (complete)" "test-session" "write_tests" "complete"

echo ""
echo "=== workflow-mark: RESET_FROM marker — Error / edge cases ==="

# Test RE1: unknown step "foo" → state unchanged, hook exit 0
REPO=$(setup_repo)
write_state "test-session" "$(ALL_COMPLETE_JSON test-session)"
RE1_JSON=$(build_reset_json 'echo "<<WORKFLOW_RESET_FROM_foo>>"')
run_mark_hook "$REPO" "$RE1_JSON" >/dev/null
expect_no_state_change "RE1. unknown step 'foo' → research unchanged (complete)" "test-session" "research" "complete"

# Test RE2: missing session_id → state unchanged, hook exit 0, stdout has additionalContext
REPO=$(setup_repo)
write_state "test-session" "$(ALL_COMPLETE_JSON test-session)"
RE2_CMD='echo "<<WORKFLOW_RESET_FROM_write_tests>>"'
RE2_ESC=${RE2_CMD//\"/\\\"}
RE2_JSON=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":{"exit_code":0,"stdout":"%s\\n","stderr":""}}' "$RE2_ESC" "$RE2_ESC")
RE2_OUT=$(echo "$RE2_JSON" | CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" env -u CLAUDE_ENV_FILE node "$MARK_HOOK" 2>/dev/null || true)
RE2_EXIT=$?
expect_no_state_change "RE2a. no session_id → write_tests unchanged (complete)" "test-session" "write_tests" "complete"
if echo "$RE2_OUT" | grep -q "additionalContext"; then
    pass "RE2b. no session_id → stdout JSON contains additionalContext"
else
    fail "RE2b. no session_id → expected additionalContext in stdout, got: $RE2_OUT"
fi
if [ "$RE2_EXIT" = "0" ]; then
    pass "RE2c. no session_id → hook exit 0"
else
    fail "RE2c. no session_id → expected exit 0, got: $RE2_EXIT"
fi

# Test RE3: exit_code=1 → state unchanged
REPO=$(setup_repo)
write_state "test-session" "$(ALL_COMPLETE_JSON test-session)"
RE3_CMD='echo "<<WORKFLOW_RESET_FROM_write_tests>>"'
RE3_ESC=${RE3_CMD//\"/\\\"}
RE3_JSON=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":{"exit_code":1,"stdout":"","stderr":"oops"},"session_id":"test-session"}' "$RE3_ESC")
run_mark_hook "$REPO" "$RE3_JSON" >/dev/null
expect_no_state_change "RE3. exit_code=1 → write_tests unchanged (complete)" "test-session" "write_tests" "complete"

echo ""
echo "=== workflow-mark: RESET_FROM marker — Idempotency ==="

# Test RI1: apply R1 twice → same final state (no crash, write_tests still pending)
REPO=$(setup_repo)
write_state "test-session" "$(ALL_COMPLETE_JSON test-session)"
RI1_JSON=$(build_reset_json 'echo "<<WORKFLOW_RESET_FROM_write_tests>>"')
run_mark_hook "$REPO" "$RI1_JSON" >/dev/null
run_mark_hook "$REPO" "$RI1_JSON" >/dev/null
expect_state_step "RI1a. RESET_FROM applied twice → research=complete (idempotent)"    "test-session" "research"    "complete"
expect_state_step "RI1b. RESET_FROM applied twice → write_tests=pending (idempotent)"  "test-session" "write_tests"  "pending"
expect_state_step "RI1c. RESET_FROM applied twice → run_tests=pending (idempotent)"    "test-session" "run_tests"    "pending"

# ---------------------------------------------------------------------------
# settings.json — hook registration structure
# ---------------------------------------------------------------------------

echo ""
echo "=== settings.json: hook registration structure ==="

SETTINGS="$DOTFILES_DIR/claude-global/settings.json"

# SR1: hooks.PostToolUse exists
# Pass SETTINGS via argv (not embedded in -e string) so MSYS2 translates the path on Windows.
if node -e "const s=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')); process.exit(s.hooks && s.hooks.PostToolUse ? 0 : 1);" -- "$SETTINGS" 2>/dev/null; then
    pass "SR1. hooks.PostToolUse exists"
else
    fail "SR1. hooks.PostToolUse missing — workflow-mark.js will never be called"
fi

# SR2: hooks.PostToolUse[0].matcher === "Bash"
if node -e "const s=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')); const pt=s.hooks&&s.hooks.PostToolUse; process.exit(pt&&pt[0]&&pt[0].matcher==='Bash' ? 0 : 1);" -- "$SETTINGS" 2>/dev/null; then
    pass "SR2. hooks.PostToolUse[0].matcher === \"Bash\""
else
    fail "SR2. hooks.PostToolUse[0].matcher is not \"Bash\""
fi

# SR3: hooks.PostToolUse[0].hooks[0].command references workflow-mark.js
if node -e "const s=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')); const pt=s.hooks&&s.hooks.PostToolUse; const cmd=pt&&pt[0]&&pt[0].hooks&&pt[0].hooks[0]&&pt[0].hooks[0].command||''; process.exit(cmd.includes('workflow-mark.js') ? 0 : 1);" -- "$SETTINGS" 2>/dev/null; then
    pass "SR3. hooks.PostToolUse command references workflow-mark.js"
else
    fail "SR3. hooks.PostToolUse command does not reference workflow-mark.js"
fi

# SR4: permissions.PostToolUse must NOT exist (placement guard)
if node -e "const s=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')); process.exit(s.permissions&&s.permissions.PostToolUse ? 1 : 0);" -- "$SETTINGS" 2>/dev/null; then
    pass "SR4. permissions.PostToolUse absent (not misplaced)"
else
    fail "SR4. permissions.PostToolUse present — PostToolUse is misplaced inside permissions"
fi

# ---------------------------------------------------------------------------
# E2E: PostToolUse hook real invocation (requires RUN_E2E=1)
# ---------------------------------------------------------------------------

echo ""
echo "=== E2E: PostToolUse hook real invocation ==="

if [ "${RUN_E2E:-0}" = "1" ]; then
    E1_SESSION_ID="e1e1e1e1-0000-0000-0000-000000000001"
    E1_REPO="$TMPDIR_BASE/e2e-e1-repo"

    # Setup: fresh git repo (no remote → isPrivateRepo() returns false)
    mkdir -p "$E1_REPO/.claude"
    git -C "$E1_REPO" init -q
    git -C "$E1_REPO" config user.email "test@example.com"
    git -C "$E1_REPO" config user.name "Test"

    # Write minimal settings.json: only PostToolUse hook, no disableBypassPermissionsMode
    # (disableBypassPermissionsMode:disable would neutralize --dangerously-skip-permissions)
    cat > "$E1_REPO/.claude/settings.json" << SETTINGS_EOF
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "node \"$DOTFILES_DIR/claude-global/hooks/workflow-mark.js\"",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
SETTINGS_EOF

    E1_STATE_FILE="$WORKFLOW_DIR/$E1_SESSION_ID.json"

    # Run claude -p with a prompt that emits the workflow marker.
    # DOTFILES_DIR is exported so the hook command (node "$DOTFILES_DIR/...") resolves correctly.
    # --setting-sources project: only load <cwd>/.claude/settings.json (has PostToolUse hook).
    # --dangerously-skip-permissions: allows the echo command without interactive prompt.
    E1_OUTPUT=$(
        cd "$E1_REPO" &&
        unset CLAUDECODE &&
        DOTFILES_DIR="$DOTFILES_DIR" run_with_timeout \
        claude -p \
            'Run exactly this Bash command and nothing else: echo "<<WORKFLOW_MARK_STEP_research_complete>>"' \
            --session-id "$E1_SESSION_ID" \
            --setting-sources project \
            --dangerously-skip-permissions \
            --output-format text \
        2>&1
    )
    E1_EXIT=$?

    if [ -f "$E1_STATE_FILE" ]; then
        # Check that steps.research.status === "complete"
        E1_STATUS=$(node -e "
const s = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
process.stdout.write((s.steps && s.steps.research && s.steps.research.status) || '');
" -- "$E1_STATE_FILE" 2>/dev/null)
        if [ "$E1_STATUS" = "complete" ]; then
            pass "E1. claude -p PostToolUse hook fires → research=complete in state file"
        else
            fail "E1. claude -p PostToolUse hook fired but research.status=\"$E1_STATUS\" (expected \"complete\"). State: $(node -e "process.stdout.write(require('fs').readFileSync(process.argv[1],'utf8'));" -- "$E1_STATE_FILE" 2>/dev/null)"
        fi
    else
        fail "E1. claude -p PostToolUse hook did not create state file $E1_STATE_FILE. claude exit=$E1_EXIT output: $E1_OUTPUT"
    fi
else
    echo "SKIP: E1. claude -p E2E (set RUN_E2E=1 to enable)"
fi

# ---------------------------------------------------------------------------
# === workflow-state.js: Unit-level checks via node -e ===
# ---------------------------------------------------------------------------

echo ""
echo "=== workflow-state: Unit checks ==="

WS_REL="./claude-global/hooks/lib/workflow-state.js"

# WS-UNIT-1: CLAUDE_WORKFLOW_DIR env override → used as workflow dir
# Compare inside Node.js so both sides agree on path format (Git Bash converts /tmp/... to C:/... on Windows).
WS_UNIT1_DIR="$TMPDIR_BASE/custom-workflow-$$"
WS_UNIT1_RESULT=$(cd "$DOTFILES_DIR" && CLAUDE_WORKFLOW_DIR="$WS_UNIT1_DIR" node -e "
const wf = require('$WS_REL');
console.log(wf.getWorkflowDir() === process.env.CLAUDE_WORKFLOW_DIR ? 'ok' : wf.getWorkflowDir());
" 2>/dev/null || echo "ERROR")
if [ "$WS_UNIT1_RESULT" = "ok" ]; then
    pass "WS-UNIT-1. CLAUDE_WORKFLOW_DIR override is respected"
else
    fail "WS-UNIT-1. CLAUDE_WORKFLOW_DIR override not respected: $WS_UNIT1_RESULT"
fi

# WS-UNIT-2: CLAUDE_WORKFLOW_DIR unset → uses os.homedir()/.claude/projects/workflow
WS_FAKEHOME="$TMPDIR_BASE/fakehome"
WS_UNIT2_RESULT=$(cd "$DOTFILES_DIR" && HOME="$WS_FAKEHOME" USERPROFILE="$WS_FAKEHOME" node -e "
process.env.CLAUDE_WORKFLOW_DIR = '';
delete process.env.CLAUDE_WORKFLOW_DIR;
const wf = require('$WS_REL');
const os = require('os');
const path = require('path');
const expected = path.join(os.homedir(), '.claude', 'projects', 'workflow');
console.log(wf.getWorkflowDir() === expected ? 'ok' : wf.getWorkflowDir());
" 2>/dev/null || echo "ERROR")
if [ "$WS_UNIT2_RESULT" = "ok" ]; then
    pass "WS-UNIT-2. CLAUDE_WORKFLOW_DIR unset → os.homedir() path used"
else
    fail "WS-UNIT-2. expected homedir path, got: $WS_UNIT2_RESULT"
fi

# WS-UNIT-3: writeState creates workflow dir if missing
WS_UNIT3_DIR="$TMPDIR_BASE/ws-unit3-$$"
WS_UNIT3_RESULT=$(cd "$DOTFILES_DIR" && CLAUDE_WORKFLOW_DIR="$WS_UNIT3_DIR" node -e "
const wf = require('$WS_REL');
const state = wf.createInitialState('test-sid-unit3');
try {
  wf.writeState('test-sid-unit3', state);
  const fs = require('fs');
  const path = require('path');
  console.log(fs.existsSync(path.join(wf.getWorkflowDir(), 'test-sid-unit3.json')) ? 'ok' : 'missing');
} catch(e) { console.log('ERROR: ' + e.message); }
" 2>/dev/null || echo "ERROR")
if [ "$WS_UNIT3_RESULT" = "ok" ]; then
    pass "WS-UNIT-3. writeState creates workflow dir if missing"
else
    fail "WS-UNIT-3. writeState dir creation: $WS_UNIT3_RESULT"
fi

# WS-UNIT-4: readState with nonexistent session → returns null (no throw)
WS_UNIT4_RESULT=$(cd "$DOTFILES_DIR" && CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node -e "
const wf = require('$WS_REL');
const result = wf.readState('nonexistent-session-xyz');
console.log(result === null ? 'ok' : JSON.stringify(result));
" 2>/dev/null || echo "ERROR")
if [ "$WS_UNIT4_RESULT" = "ok" ]; then
    pass "WS-UNIT-4. readState nonexistent session → null (no throw)"
else
    fail "WS-UNIT-4. readState nonexistent: $WS_UNIT4_RESULT"
fi

# WS-UNIT-5: cleanupZombies does not crash when workflow dir does not exist
WS_UNIT5_DIR="$TMPDIR_BASE/ws-unit5-nonexistent-$$"
WS_UNIT5_EXIT=0
(cd "$DOTFILES_DIR" && CLAUDE_WORKFLOW_DIR="$WS_UNIT5_DIR" node -e "
const wf = require('$WS_REL');
wf.cleanupZombies(7);
" 2>/dev/null) || WS_UNIT5_EXIT=$?
if [ "$WS_UNIT5_EXIT" = "0" ]; then
    pass "WS-UNIT-5. cleanupZombies on nonexistent dir → no crash"
else
    fail "WS-UNIT-5. cleanupZombies crashed: exit $WS_UNIT5_EXIT"
fi

# WS-UNIT-6: cleanupZombies removes stale .tmp files (mtimed in the past)
WS_UNIT6_DIR="$TMPDIR_BASE/ws-unit6-$$"
mkdir -p "$WS_UNIT6_DIR"
TMP_FILE="$WS_UNIT6_DIR/stale.json.tmp"
touch "$TMP_FILE"
# Backdate mtime by 2 days (172800 seconds)
touch -d "2 days ago" "$TMP_FILE" 2>/dev/null || touch -t "$(date -v-2d +%Y%m%d%H%M 2>/dev/null || date -d '2 days ago' +%Y%m%d%H%M 2>/dev/null || echo '202601010000')" "$TMP_FILE" 2>/dev/null || true
(cd "$DOTFILES_DIR" && CLAUDE_WORKFLOW_DIR="$WS_UNIT6_DIR" node -e "
const wf = require('$WS_REL');
wf.cleanupZombies(7);
" 2>/dev/null) || true
if [ ! -f "$TMP_FILE" ]; then
    pass "WS-UNIT-6. cleanupZombies removes stale .tmp files"
else
    # touch -d might not work on macOS — check if mtime was actually set
    MTIME_DIFF=$(node -e "const s=require('fs').statSync('$TMP_FILE');console.log(Date.now()-s.mtimeMs)" 2>/dev/null || echo "0")
    if [ "${MTIME_DIFF:-0}" -lt "86400000" ]; then
        echo "SKIP: WS-UNIT-6. touch -d not supported on this platform, skipping mtime test"
    else
        fail "WS-UNIT-6. stale .tmp file was not removed"
    fi
fi

# WS-IDEM-1: markStep called twice → idempotent result
WS_IDEM1_DIR="$TMPDIR_BASE/ws-idem1-$$"
WS_IDEM1_RESULT=$(cd "$DOTFILES_DIR" && CLAUDE_WORKFLOW_DIR="$WS_IDEM1_DIR" node -e "
const wf = require('$WS_REL');
wf.markStep('idem-sid', 'research', 'complete');
wf.markStep('idem-sid', 'research', 'complete');
const state = wf.readState('idem-sid');
console.log(state && state.steps.research.status === 'complete' ? 'ok' : JSON.stringify(state));
" 2>/dev/null || echo "ERROR")
if [ "$WS_IDEM1_RESULT" = "ok" ]; then
    pass "WS-IDEM-1. markStep twice → idempotent"
else
    fail "WS-IDEM-1. idempotent markStep: $WS_IDEM1_RESULT"
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
