#!/usr/bin/env bash
# Test suite for claude-global/hooks/block-tests-direct.js PreToolUse hook.
# Tests will FAIL until the hook is implemented — that is expected.
set -uo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$DOTFILES_DIR/claude-global/hooks/block-tests-direct.js"
ERRORS=0
PASS_COUNT=0

# ---------------------------------------------------------------------------
# Portable timeout wrapper (macOS does not have timeout)
# ---------------------------------------------------------------------------
run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

# ---------------------------------------------------------------------------
# Temp dir / env file setup
# ---------------------------------------------------------------------------
TMPDIR_ROOT="$(node -e "const os=require('os'),path=require('path'),fs=require('fs'),crypto=require('crypto');const d=path.join(os.tmpdir(),'btest-'+crypto.randomBytes(6).toString('hex'));fs.mkdirSync(d,{recursive:true});process.stdout.write(d);")"
CLAUDE_WORKFLOW_DIR="$TMPDIR_ROOT/workflow"
CLAUDE_ENV_FILE="$TMPDIR_ROOT/claude_env"
mkdir -p "$CLAUDE_WORKFLOW_DIR"

cleanup() {
    rm -rf "$TMPDIR_ROOT"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helper: write state file
# make_state <session_id> <write_tests_status>
# ---------------------------------------------------------------------------
make_state() {
    local session_id="$1"
    local write_tests_status="$2"
    cat > "$CLAUDE_WORKFLOW_DIR/${session_id}.json" <<EOF
{
  "version": 1,
  "session_id": "${session_id}",
  "steps": {
    "write_tests": {"status": "${write_tests_status}", "updated_at": null}
  }
}
EOF
}

# ---------------------------------------------------------------------------
# Helper: write env file with session id
# make_env_file <session_id>
# ---------------------------------------------------------------------------
make_env_file() {
    local session_id="$1"
    printf 'CLAUDE_SESSION_ID=%s\n' "$session_id" > "$CLAUDE_ENV_FILE"
}

# ---------------------------------------------------------------------------
# Helper: run hook with given JSON, optional extra env vars (KEY=VAL format)
# run_hook <json> [KEY=VAL ...]
# ---------------------------------------------------------------------------
run_hook() {
    local json="$1"
    shift
    local extra_env=("$@")
    # Write JSON to a temp file to avoid shell quoting issues
    local input_file
    input_file="$(mktemp "$TMPDIR_ROOT/hook_input.XXXXXX")"
    printf '%s' "$json" > "$input_file"
    local result
    result=$(
        (
            export CLAUDE_ENV_FILE="$CLAUDE_ENV_FILE"
            export CLAUDE_WORKFLOW_DIR="$CLAUDE_WORKFLOW_DIR"
            for kv in "${extra_env[@]+"${extra_env[@]}"}"; do export "$kv"; done
            run_with_timeout node "$HOOK" < "$input_file" 2>/dev/null
        )
    ) || true
    rm -f "$input_file"
    printf '%s' "$result"
}

# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------
fail() {
    echo "FAIL: $1"
    ERRORS=$((ERRORS + 1))
}

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

assert_approve() {
    local id="$1"
    local desc="$2"
    local json="$3"
    shift 3
    local extra_env=("$@")
    local result
    result=$(run_hook "$json" "${extra_env[@]+"${extra_env[@]}"}")
    local decision
    decision=$(node -e "try{const d=JSON.parse(process.argv[1]);process.stdout.write(d.decision||'')}catch(e){}" -- "$result" 2>/dev/null || true)
    if [ "$decision" = "approve" ]; then
        pass "${id}. ${desc}"
    else
        fail "${id}. ${desc} — expected approve, got: ${result}"
    fi
}

assert_block() {
    local id="$1"
    local desc="$2"
    local json="$3"
    shift 3
    local extra_env=("$@")
    local result
    result=$(run_hook "$json" "${extra_env[@]+"${extra_env[@]}"}")
    local decision
    decision=$(node -e "try{const d=JSON.parse(process.argv[1]);process.stdout.write(d.decision||'')}catch(e){}" -- "$result" 2>/dev/null || true)
    if [ "$decision" = "block" ]; then
        pass "${id}. ${desc}"
    else
        fail "${id}. ${desc} — expected block, got: ${result}"
    fi
}

# ---------------------------------------------------------------------------
# Session setup shortcut: set env file + state file together
# setup_session <session_id> <write_tests_status>
# ---------------------------------------------------------------------------
setup_session() {
    local session_id="$1"
    local status="$2"
    make_env_file "$session_id"
    make_state "$session_id" "$status"
}

# ===========================================================================
# Section A — Normal cases
# ===========================================================================
echo ""
echo "=== Section A — Normal cases ==="

# A1: Write + src/foo.js + pending → approve (no tests/ component)
setup_session "sess-a1" "pending"
assert_approve "A1" "Write + src/foo.js + pending → approve (no tests/ component)" \
    '{"tool_name":"Write","tool_input":{"file_path":"src/foo.js"},"session_id":"sess-a1","agent_id":""}'

# A2: Write + tests/foo.sh + pending + no agent_id → block
setup_session "sess-a2" "pending"
assert_block "A2" "Write + tests/foo.sh + pending + no agent_id → block" \
    '{"tool_name":"Write","tool_input":{"file_path":"tests/foo.sh"},"session_id":"sess-a2","agent_id":""}'

# A3: Write + tests/foo.sh + in_progress → approve
setup_session "sess-a3" "in_progress"
assert_approve "A3" "Write + tests/foo.sh + in_progress → approve" \
    '{"tool_name":"Write","tool_input":{"file_path":"tests/foo.sh"},"session_id":"sess-a3","agent_id":""}'

# A4: Write + tests/foo.sh + complete → approve
setup_session "sess-a4" "complete"
assert_approve "A4" "Write + tests/foo.sh + complete → approve" \
    '{"tool_name":"Write","tool_input":{"file_path":"tests/foo.sh"},"session_id":"sess-a4","agent_id":""}'

# A5: Write + tests/foo.sh + skipped → approve
setup_session "sess-a5" "skipped"
assert_approve "A5" "Write + tests/foo.sh + skipped → approve" \
    '{"tool_name":"Write","tool_input":{"file_path":"tests/foo.sh"},"session_id":"sess-a5","agent_id":""}'

# A6: Edit + tests/foo.sh + pending → block
setup_session "sess-a6" "pending"
assert_block "A6" "Edit + tests/foo.sh + pending → block" \
    '{"tool_name":"Edit","tool_input":{"file_path":"tests/foo.sh"},"session_id":"sess-a6","agent_id":""}'

# A7: MultiEdit + tests/foo.sh + pending → block
setup_session "sess-a7" "pending"
assert_block "A7" "MultiEdit + tests/foo.sh + pending → block" \
    '{"tool_name":"MultiEdit","tool_input":{"file_path":"tests/foo.sh"},"session_id":"sess-a7","agent_id":""}'

# A8: Bash + no file_path + pending → approve (tool_name not in Write/Edit/MultiEdit)
setup_session "sess-a8" "pending"
assert_approve "A8" "Bash + no file_path + pending → approve (wrong tool)" \
    '{"tool_name":"Bash","tool_input":{"command":"echo hi"},"session_id":"sess-a8","agent_id":""}'

# A9: Write + tests/foo.sh + pending + agent_id="sub-xxx" → approve (subagent)
setup_session "sess-a9" "pending"
assert_approve "A9" "Write + tests/foo.sh + pending + agent_id=sub-xxx → approve (subagent)" \
    '{"tool_name":"Write","tool_input":{"file_path":"tests/foo.sh"},"session_id":"sess-a9","agent_id":"sub-xxx"}'

# ===========================================================================
# Section B — Error / fail-open
# ===========================================================================
echo ""
echo "=== Section B — Error / fail-open ==="

# B10: no CLAUDE_ENV_FILE env var set → approve (fail-open)
b10_input='{"tool_name":"Write","tool_input":{"file_path":"tests/foo.sh"},"session_id":"sess-b10","agent_id":""}'
b10_input_file="$(mktemp "$TMPDIR_ROOT/b10_input.XXXXXX")"
printf '%s' "$b10_input" > "$b10_input_file"
b10_result=$(
    (
        unset CLAUDE_ENV_FILE
        export CLAUDE_WORKFLOW_DIR="$CLAUDE_WORKFLOW_DIR"
        run_with_timeout node "$HOOK" < "$b10_input_file" 2>/dev/null
    )
) || true
rm -f "$b10_input_file"
b10_decision=$(node -e "try{const d=JSON.parse(process.argv[1]);process.stdout.write(d.decision||'')}catch(e){}" -- "$b10_result" 2>/dev/null || true)
if [ "$b10_decision" = "approve" ]; then
    pass "B10. no CLAUDE_ENV_FILE → approve (fail-open)"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    fail "B10. no CLAUDE_ENV_FILE → expected approve, got: ${b10_result}"
fi

# B11: CLAUDE_ENV_FILE set with session_id but no state file → approve (fail-open)
make_env_file "sess-b11"
rm -f "$CLAUDE_WORKFLOW_DIR/sess-b11.json"
assert_approve "B11" "state file missing → approve (fail-open)" \
    '{"tool_name":"Write","tool_input":{"file_path":"tests/foo.sh"},"session_id":"sess-b11","agent_id":""}'

# B12: state file JSON corrupt → approve (fail-open)
make_env_file "sess-b12"
printf 'NOT VALID JSON {{{{' > "$CLAUDE_WORKFLOW_DIR/sess-b12.json"
assert_approve "B12" "state file JSON corrupt → approve (fail-open)" \
    '{"tool_name":"Write","tool_input":{"file_path":"tests/foo.sh"},"session_id":"sess-b12","agent_id":""}'

# B13: steps.write_tests key missing from state → approve (fail-open)
make_env_file "sess-b13"
cat > "$CLAUDE_WORKFLOW_DIR/sess-b13.json" <<'EOF'
{
  "version": 1,
  "session_id": "sess-b13",
  "steps": {}
}
EOF
assert_approve "B13" "steps.write_tests missing → approve (fail-open)" \
    '{"tool_name":"Write","tool_input":{"file_path":"tests/foo.sh"},"session_id":"sess-b13","agent_id":""}'

# B14: stdin malformed JSON → approve (fail-open)
make_env_file "sess-b14"
make_state "sess-b14" "pending"
b14_input_file="$(mktemp "$TMPDIR_ROOT/b14_input.XXXXXX")"
printf '%s' 'NOT VALID JSON' > "$b14_input_file"
b14_result=$(
    (
        export CLAUDE_ENV_FILE="$CLAUDE_ENV_FILE"
        export CLAUDE_WORKFLOW_DIR="$CLAUDE_WORKFLOW_DIR"
        run_with_timeout node "$HOOK" < "$b14_input_file" 2>/dev/null
    )
) || true
rm -f "$b14_input_file"
b14_decision=$(node -e "try{const d=JSON.parse(process.argv[1]);process.stdout.write(d.decision||'')}catch(e){}" -- "$b14_result" 2>/dev/null || true)
if [ "$b14_decision" = "approve" ]; then
    pass "B14. stdin malformed JSON → approve (fail-open)"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    fail "B14. stdin malformed JSON — expected approve, got: ${b14_result}"
fi

# ===========================================================================
# Section C — Edge cases
# ===========================================================================
echo ""
echo "=== Section C — Edge cases ==="

# C15: foo/tests/bar/baz.sh (mid-path tests/) → block
setup_session "sess-c15" "pending"
assert_block "C15" "foo/tests/bar/baz.sh + pending → block (tests/ mid-path)" \
    '{"tool_name":"Write","tool_input":{"file_path":"foo/tests/bar/baz.sh"},"session_id":"sess-c15","agent_id":""}'

# C16: integration-tests/foo.sh → approve (not isolated component)
setup_session "sess-c16" "pending"
assert_approve "C16" "integration-tests/foo.sh + pending → approve (not isolated tests/ component)" \
    '{"tool_name":"Write","tool_input":{"file_path":"integration-tests/foo.sh"},"session_id":"sess-c16","agent_id":""}'

# C17: Windows backslash path C:\git\dotfiles\tests\foo.sh → block
setup_session "sess-c17" "pending"
assert_block "C17" "Windows backslash path tests\\foo.sh + pending → block" \
    '{"tool_name":"Write","tool_input":{"file_path":"C:\\git\\dotfiles\\tests\\foo.sh"},"session_id":"sess-c17","agent_id":""}'

# C18: Unix absolute /home/user/tests/foo.sh → block
setup_session "sess-c18" "pending"
assert_block "C18" "/home/user/tests/foo.sh + pending → block (Unix absolute)" \
    '{"tool_name":"Write","tool_input":{"file_path":"/home/user/tests/foo.sh"},"session_id":"sess-c18","agent_id":""}'

# C19: Git Bash style /c/git/dotfiles/tests/foo.sh → block
setup_session "sess-c19" "pending"
assert_block "C19" "/c/git/dotfiles/tests/foo.sh + pending → block (Git Bash style)" \
    '{"tool_name":"Write","tool_input":{"file_path":"/c/git/dotfiles/tests/foo.sh"},"session_id":"sess-c19","agent_id":""}'

# C20: file_path="" (empty string) → approve
setup_session "sess-c20" "pending"
assert_approve "C20" "file_path=empty string → approve" \
    '{"tool_name":"Write","tool_input":{"file_path":""},"session_id":"sess-c20","agent_id":""}'

# C21: file_path="tests/" (directory only, no filename) → approve
setup_session "sess-c21" "pending"
assert_approve "C21" "file_path=tests/ (directory only) → approve" \
    '{"tool_name":"Write","tool_input":{"file_path":"tests/"},"session_id":"sess-c21","agent_id":""}'

# C22: spec/foo.js + CLAUDE_BLOCK_TESTS_DIR_NAMES=spec,__tests__ → block
setup_session "sess-c22" "pending"
assert_block "C22" "spec/foo.js + CLAUDE_BLOCK_TESTS_DIR_NAMES=spec,__tests__ → block" \
    '{"tool_name":"Write","tool_input":{"file_path":"spec/foo.js"},"session_id":"sess-c22","agent_id":""}' \
    "CLAUDE_BLOCK_TESTS_DIR_NAMES=spec,__tests__"

# C23: tests/foo.sh + CLAUDE_BLOCK_TESTS_DIR_NAMES=spec,__tests__ → approve (tests not in custom list)
setup_session "sess-c23" "pending"
assert_approve "C23" "tests/foo.sh + CLAUDE_BLOCK_TESTS_DIR_NAMES=spec,__tests__ → approve (not in custom list)" \
    '{"tool_name":"Write","tool_input":{"file_path":"tests/foo.sh"},"session_id":"sess-c23","agent_id":""}' \
    "CLAUDE_BLOCK_TESTS_DIR_NAMES=spec,__tests__"

# ===========================================================================
# Section D — Idempotency
# ===========================================================================
echo ""
echo "=== Section D — Idempotency ==="

# D24: same stdin twice → same decision both times
setup_session "sess-d24" "pending"
d24_json='{"tool_name":"Write","tool_input":{"file_path":"tests/foo.sh"},"session_id":"sess-d24","agent_id":""}'
d24_result1=$(run_hook "$d24_json")
d24_result2=$(run_hook "$d24_json")
d24_dec1=$(node -e "try{const d=JSON.parse(process.argv[1]);process.stdout.write(d.decision||'')}catch(e){}" -- "$d24_result1" 2>/dev/null || true)
d24_dec2=$(node -e "try{const d=JSON.parse(process.argv[1]);process.stdout.write(d.decision||'')}catch(e){}" -- "$d24_result2" 2>/dev/null || true)
if [ "$d24_dec1" = "$d24_dec2" ] && [ -n "$d24_dec1" ]; then
    pass "D24. same stdin twice → same decision (${d24_dec1}) both times"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    fail "D24. idempotency — got '${d24_dec1}' then '${d24_dec2}'"
fi

# ===========================================================================
# Section E — Security
# ===========================================================================
echo ""
echo "=== Section E — Security ==="

# E25: ../../etc/tests/exploit.sh + pending → block (path traversal still matches tests/)
setup_session "sess-e25" "pending"
assert_block "E25" "../../etc/tests/exploit.sh + pending → block (path traversal with tests/)" \
    '{"tool_name":"Write","tool_input":{"file_path":"../../etc/tests/exploit.sh"},"session_id":"sess-e25","agent_id":""}'

# E26: tests/$(rm -rf /).sh + pending → block and no shell execution (pure string match)
setup_session "sess-e26" "pending"
assert_block "E26" 'tests/$(rm -rf /).sh + pending → block (no shell execution)' \
    '{"tool_name":"Write","tool_input":{"file_path":"tests/$(rm -rf /).sh"},"session_id":"sess-e26","agent_id":""}'

# E27: DENY_MESSAGE drift check — hook must export DENY_MESSAGE matching expected string
EXPECTED_DENY_MESSAGE="write_tests step is still pending. Run /write-tests first — it spawns a subagent that writes tests/ autonomously. If tests are genuinely not needed, mark the step skipped with: echo \"<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: <reason>>>\""
HOOK_ABS="$(cd "$(dirname "$HOOK")" && pwd)/$(basename "$HOOK")"
e27_result=$(node -e "
var hookPath = process.argv[1];
try {
  var m = require(hookPath);
  if (typeof m.DENY_MESSAGE === 'string') {
    process.stdout.write(m.DENY_MESSAGE);
  } else {
    process.stdout.write('ERROR: DENY_MESSAGE not exported or not a string');
  }
} catch(e) {
  process.stdout.write('ERROR: ' + e.message);
}
" -- "$HOOK_ABS" 2>/dev/null || true)

if [ "$e27_result" = "$EXPECTED_DENY_MESSAGE" ]; then
    pass "E27. DENY_MESSAGE exported and matches expected string"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    fail "E27. DENY_MESSAGE drift — expected: '${EXPECTED_DENY_MESSAGE}' — got: '${e27_result}'"
fi

# ===========================================================================
# Section F — Integration (broad)
# ===========================================================================
echo ""
echo "=== Section F — Integration (broad) ==="

# F28: real state file (write_tests=pending) + main-style stdin (no agent_id) → block
setup_session "sess-f28" "pending"
assert_block "F28" "real state + write_tests=pending + no agent_id → block (integration)" \
    '{"tool_name":"Write","tool_input":{"file_path":"tests/integration.sh"},"session_id":"sess-f28","agent_id":""}'

# F29: real state file (write_tests=pending) + agent_id="sub-abc" → approve
setup_session "sess-f29" "pending"
assert_approve "F29" "real state + write_tests=pending + agent_id=sub-abc → approve (subagent, integration)" \
    '{"tool_name":"Write","tool_input":{"file_path":"tests/integration.sh"},"session_id":"sess-f29","agent_id":"sub-abc"}'

# ===========================================================================
# Results
# ===========================================================================
echo ""
echo "=== Results ==="
TOTAL=$((PASS_COUNT + ERRORS))
echo "${PASS_COUNT}/${TOTAL} tests passed, ${ERRORS} failed"
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
    exit 0
else
    echo "${ERRORS} test(s) failed"
    exit 1
fi
