#!/bin/bash
# Tests: hooks/workflow-gate.js
# Tags: clarify-intent-gate
# Integration tests for clarify-intent earlyGate in workflow-gate.js.
# Pre-implementation: tests 1-5 and 13 are expected to FAIL until earlyGate lands.
set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GATE_HOOK="$AGENTS_DIR/hooks/workflow-gate.js"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then timeout 120 "$@"
    else perl -e 'alarm 120; exec @ARGV' -- "$@"; fi
}

# Windows-compatible tmpdir
_NODE_TMPDIR=$(node -e "process.stdout.write(require('os').tmpdir())" 2>/dev/null || echo "")
if [[ "$_NODE_TMPDIR" =~ ^[A-Za-z]: ]]; then
    _DRIVE=$(echo "$_NODE_TMPDIR" | cut -c1 | tr 'A-Z' 'a-z')
    _REST=$(echo "$_NODE_TMPDIR" | cut -c3- | tr '\\' '/')
    _BASH_WIN_TMPDIR="/${_DRIVE}${_REST}"
    TMPDIR_BASE=$(mktemp -d "${_BASH_WIN_TMPDIR}/cctests.XXXXXXXX")
else
    TMPDIR_BASE=$(mktemp -d)
fi
WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
mkdir -p "$WORKFLOW_DIR"
export CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

NOW_ISO=$(node -e "console.log(new Date().toISOString())" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")

# Resolve the actual plans dir from Node so the test path matches what the hook expects
# (path.resolve() on /c/Users/... yields C:\c\Users\... on Windows, not the home dir).
PLANS_DIR_NATIVE=$(node -e "console.log(require('path').join(require('os').homedir(), '.workflow-plans').replace(/\\\\/g, '/'))")

pending_state() {
    local sid="$1"
    cat <<EOF
{"version":1,"session_id":"$sid","created_at":"$NOW_ISO","cwd":"/tmp","git_branch":"main","steps":{"clarify_intent":{"status":"pending","updated_at":null},"research":{"status":"pending","updated_at":null},"outline":{"status":"pending","updated_at":null},"detail":{"status":"pending","updated_at":null},"branching_complete":{"status":"pending","updated_at":null},"write_tests":{"status":"pending","updated_at":null},"run_tests":{"status":"pending","updated_at":null},"review_security":{"status":"pending","updated_at":null},"docs":{"status":"pending","updated_at":null},"user_verification":{"status":"pending","updated_at":null},"cleanup":{"status":"pending","updated_at":null}}}
EOF
}

complete_state() {
    local sid="$1"
    cat <<EOF
{"version":1,"session_id":"$sid","created_at":"$NOW_ISO","cwd":"/tmp","git_branch":"main","steps":{"clarify_intent":{"status":"complete","updated_at":"$NOW_ISO"},"research":{"status":"pending","updated_at":null},"outline":{"status":"pending","updated_at":null},"detail":{"status":"pending","updated_at":null},"branching_complete":{"status":"pending","updated_at":null},"write_tests":{"status":"pending","updated_at":null},"run_tests":{"status":"pending","updated_at":null},"review_security":{"status":"pending","updated_at":null},"docs":{"status":"pending","updated_at":null},"user_verification":{"status":"pending","updated_at":null},"cleanup":{"status":"pending","updated_at":null}}}
EOF
}

skipped_state() {
    local sid="$1"
    cat <<EOF
{"version":1,"session_id":"$sid","created_at":"$NOW_ISO","cwd":"/tmp","git_branch":"main","steps":{"clarify_intent":{"status":"skipped","updated_at":"$NOW_ISO"},"research":{"status":"pending","updated_at":null},"outline":{"status":"pending","updated_at":null},"detail":{"status":"pending","updated_at":null},"branching_complete":{"status":"pending","updated_at":null},"write_tests":{"status":"pending","updated_at":null},"run_tests":{"status":"pending","updated_at":null},"review_security":{"status":"pending","updated_at":null},"docs":{"status":"pending","updated_at":null},"user_verification":{"status":"pending","updated_at":null},"cleanup":{"status":"pending","updated_at":null}}}
EOF
}

write_state() {
    local sid="$1" json="$2"
    mkdir -p "$WORKFLOW_DIR"
    printf '%s' "$json" > "$WORKFLOW_DIR/${sid}.json"
}

run_gate() {
    local input="$1"
    echo "$input" | run_with_timeout node "$GATE_HOOK" 2>/dev/null || true
}

assert_decision() {
    local test_name="$1" input="$2" expected="$3"
    local output
    output=$(run_gate "$input")
    local actual
    actual=$(echo "$output" | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{try{process.stdout.write(JSON.parse(d).decision||'')}catch(e){process.stdout.write('')}})")
    if [ "$actual" = "$expected" ]; then
        pass "$test_name"
    else
        fail "$test_name (expected=$expected, got=$actual, output=$output)"
    fi
}

input_edit()         { local sid="$1" fp="$2"; printf '{"session_id":"%s","tool_name":"Edit","tool_input":{"file_path":"%s","old_string":"x","new_string":"y"}}' "$sid" "$fp"; }
input_write()        { local sid="$1" fp="$2"; printf '{"session_id":"%s","tool_name":"Write","tool_input":{"file_path":"%s","content":"hello"}}' "$sid" "$fp"; }
input_multiedit()    { local sid="$1" fp="$2"; printf '{"session_id":"%s","tool_name":"MultiEdit","tool_input":{"file_path":"%s","edits":[{"old_string":"a","new_string":"b"}]}}' "$sid" "$fp"; }
input_editfiles()    { local sid="$1" fp="$2"; printf '{"session_id":"%s","tool_name":"editFiles","tool_input":{"file_path":"%s","old_string":"x","new_string":"y"}}' "$sid" "$fp"; }
input_notebookedit() { local sid="$1" fp="$2"; printf '{"session_id":"%s","tool_name":"NotebookEdit","tool_input":{"notebook_path":"%s","cell_id":"c1","new_source":"x"}}' "$sid" "$fp"; }
input_edit_no_sid()  { local fp="$1"; printf '{"tool_name":"Edit","tool_input":{"file_path":"%s","old_string":"x","new_string":"y"}}' "$fp"; }

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

# 1. pending + Edit → block  [NEW BEHAVIOR — will fail pre-implementation]
SID="sid-pending-edit"
write_state "$SID" "$(pending_state "$SID")"
assert_decision "pending_edit_blocks" "$(input_edit "$SID" "/c/git/myproject/src/foo.js")" "block"

# 2. pending + Write(source) → block  [NEW BEHAVIOR — will fail pre-implementation]
SID="sid-pending-write"
write_state "$SID" "$(pending_state "$SID")"
assert_decision "pending_write_source_blocks" "$(input_write "$SID" "/c/git/myproject/src/foo.js")" "block"

# 3. pending + MultiEdit → block  [NEW BEHAVIOR — will fail pre-implementation]
SID="sid-pending-multiedit"
write_state "$SID" "$(pending_state "$SID")"
assert_decision "pending_multiedit_blocks" "$(input_multiedit "$SID" "/c/git/myproject/src/foo.js")" "block"

# 4. pending + editFiles → block  [NEW BEHAVIOR — will fail pre-implementation]
SID="sid-pending-editfiles"
write_state "$SID" "$(pending_state "$SID")"
assert_decision "pending_editfiles_blocks" "$(input_editfiles "$SID" "/c/git/myproject/src/foo.js")" "block"

# 5. pending + NotebookEdit → block  [NEW BEHAVIOR — will fail pre-implementation]
SID="sid-pending-notebookedit"
write_state "$SID" "$(pending_state "$SID")"
assert_decision "pending_notebookedit_blocks" "$(input_notebookedit "$SID" "/c/git/myproject/nb.ipynb")" "block"

# 6. complete + Edit → approve  [guardrail — earlyGate must not over-block]
SID="sid-complete-edit"
write_state "$SID" "$(complete_state "$SID")"
assert_decision "complete_edit_approves" "$(input_edit "$SID" "/c/git/myproject/src/foo.js")" "approve"

# 7. skipped + Edit → approve  [guardrail — earlyGate must not over-block]
SID="sid-skipped-edit"
write_state "$SID" "$(skipped_state "$SID")"
assert_decision "skipped_edit_approves" "$(input_edit "$SID" "/c/git/myproject/src/foo.js")" "approve"

# 8. pending + Write(.workflow-plans/...) → approve  [skill output path allowlist]
SID="sid-pending-plans"
write_state "$SID" "$(pending_state "$SID")"
assert_decision "pending_write_plans_approves" "$(input_write "$SID" "$PLANS_DIR_NATIVE/test-intent.md")" "approve"

# 9. no session_id → approve  [fail-open]
assert_decision "no_session_id_approves" "$(input_edit_no_sid "/c/git/myproject/src/foo.js")" "approve"

# 10. session_id present but no state file → approve  [fail-open]
assert_decision "no_state_file_approves" "$(input_edit "sid-no-file" "/c/git/myproject/src/foo.js")" "approve"

# 11. corrupt state JSON → approve  [fail-open]
SID="sid-corrupt"
write_state "$SID" "{not valid json"
assert_decision "corrupt_state_approves" "$(input_edit "$SID" "/c/git/myproject/src/foo.js")" "approve"

# 12. commit gate regression — clarify_intent complete, others pending, real git repo → block
COMMIT_REPO="$TMPDIR_BASE/commit-repo"
mkdir -p "$COMMIT_REPO"
(
    cd "$COMMIT_REPO"
    git init -q
    git config user.email test@example.com
    git config user.name Test
    echo hello > a.txt
    git add a.txt
    # Use core.hooksPath="" to bypass the global hooks (core.hooksPath is set globally
    # to C:\git\agents\hooks which includes enforce-worktree; temp repos must bypass it)
    git -c core.hooksPath="" commit -q -m initial
    echo world >> a.txt
    git add a.txt
)
SID="sid-commit-regression"
write_state "$SID" "$(complete_state "$SID")"
COMMIT_INPUT=$(printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"git -C %s commit -m test"}}' "$SID" "$COMMIT_REPO")
assert_decision "commit_gate_regression" "$COMMIT_INPUT" "block"

# 13a+b. same pending+Edit input twice → both block  [NEW BEHAVIOR — will fail pre-implementation]
SID="sid-twice"
write_state "$SID" "$(pending_state "$SID")"
TWICE_INPUT=$(input_edit "$SID" "/c/git/myproject/src/foo.js")
assert_decision "same_input_twice_consistent_a" "$TWICE_INPUT" "block"
assert_decision "same_input_twice_consistent_b" "$TWICE_INPUT" "block"

# ---------------------------------------------------------------------------
echo
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed."
else
    echo "$ERRORS test(s) failed."
fi
exit "$ERRORS"
