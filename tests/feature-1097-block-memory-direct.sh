#!/usr/bin/env bash
# Tests: hooks/block-memory-direct.js
# Tags: workflow, hook, memory, env, scope:issue-specific
# Test suite for hooks/block-memory-direct.js PreToolUse hook.
# Tests will FAIL until the hook is implemented — that is expected.
#
# L3 gap (hook-registration):
#   - Whether hooks/block-memory-direct.js actually fires in Claude Code requires
#     settings.json wiring that only the real CC session confirms.
#   - Whether Claude Code presents the AskUserQuestion popup when the hook blocks
#     is only observable in a live session — L2 can only check the JSON decision.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO_DIR/hooks/block-memory-direct.js"
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
# Temp dir / env setup
# ---------------------------------------------------------------------------
TMPDIR_ROOT="$(node -e "const os=require('os'),path=require('path'),fs=require('fs'),crypto=require('crypto');const d=path.join(os.tmpdir(),'bmtest-'+crypto.randomBytes(6).toString('hex'));fs.mkdirSync(d,{recursive:true});process.stdout.write(d);")"
CLAUDE_WORKFLOW_DIR="$TMPDIR_ROOT/workflow"
WORKFLOW_PLANS_DIR="$TMPDIR_ROOT/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR"
mkdir -p "$WORKFLOW_PLANS_DIR"

# Derive MEMORY_DIR the same way the hook does:
# path.join(os.homedir(), '.claude', 'projects', 'c--git-agents', 'memory')
MEMORY_DIR="$(node -e "const os=require('os'),path=require('path');process.stdout.write(path.join(os.homedir(),'.claude','projects','c--git-agents','memory').split(path.sep).join('/'));")"

cleanup() {
    rm -rf "$TMPDIR_ROOT"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helper: run hook with given JSON, optional extra env vars (KEY=VAL format)
# run_hook <json> [KEY=VAL ...]
# ---------------------------------------------------------------------------
run_hook() {
    local json="$1"
    shift
    local extra_env=("$@")
    local input_file
    input_file="$(mktemp "$TMPDIR_ROOT/hook_input.XXXXXX")"
    printf '%s' "$json" > "$input_file"
    local result
    result=$(
        (
            export CLAUDE_WORKFLOW_DIR="$CLAUDE_WORKFLOW_DIR"
            export WORKFLOW_PLANS_DIR="$WORKFLOW_PLANS_DIR"
            export CLAUDE_CODE_SESSION_ID="test-sess-1097"
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

assert_block_reason_contains() {
    local id="$1"
    local desc="$2"
    local json="$3"
    local expected_substr="$4"
    shift 4
    local extra_env=("$@")
    local result
    result=$(run_hook "$json" "${extra_env[@]+"${extra_env[@]}"}")
    local decision
    decision=$(node -e "try{const d=JSON.parse(process.argv[1]);process.stdout.write(d.decision||'')}catch(e){}" -- "$result" 2>/dev/null || true)
    local reason
    reason=$(node -e "try{const d=JSON.parse(process.argv[1]);process.stdout.write(d.reason||'')}catch(e){}" -- "$result" 2>/dev/null || true)
    if [ "$decision" = "block" ] && echo "$reason" | grep -qF "$expected_substr"; then
        pass "${id}. ${desc}"
    else
        fail "${id}. ${desc} — expected block with reason containing '${expected_substr}', got decision='${decision}' reason='${reason}'"
    fi
}

# ===========================================================================
# Section A — Normal cases
# ===========================================================================
echo ""
echo "=== Section A — Normal cases ==="

# A1: Write + non-memory path → approve
assert_approve "A1" "Write + non-memory path → approve" \
    '{"tool_name":"Write","tool_input":{"file_path":"src/foo.js"},"session_id":"test-sess-1097","agent_id":""}'

# A2: Read tool → approve (tool not in Edit|Write|MultiEdit|editFiles)
assert_approve "A2" "Read tool → approve (not in checked tools)" \
    '{"tool_name":"Read","tool_input":{"file_path":"'"$MEMORY_DIR"'/MEMORY.md"},"session_id":"test-sess-1097","agent_id":""}'

# A3: Write + memory dir → block (reason contains "Memory write intercepted")
assert_block_reason_contains "A3" "Write + memory dir → block with intercepted message" \
    '{"tool_name":"Write","tool_input":{"file_path":"'"$MEMORY_DIR"'/MEMORY.md"},"session_id":"test-sess-1097","agent_id":""}' \
    "Memory write intercepted."

# A4: Write + memory dir + valid marker file → approve + marker deleted
MARKER_FILE="$WORKFLOW_PLANS_DIR/test-sess-1097.memory-write-allow.tmp"
touch "$MARKER_FILE"
assert_approve "A4" "Write + memory dir + valid marker file → approve (one-shot consumed)" \
    '{"tool_name":"Write","tool_input":{"file_path":"'"$MEMORY_DIR"'/MEMORY.md"},"session_id":"test-sess-1097","agent_id":""}'
# Verify marker was deleted
if [ ! -f "$MARKER_FILE" ]; then
    pass "A4b. Marker file deleted after one-shot consume"
else
    fail "A4b. Marker file NOT deleted after one-shot consume"
fi

# A5: Write + memory dir + WORKFLOW_OFF active → approve
WORKFLOW_OFF_MARKER="$CLAUDE_WORKFLOW_DIR/test-sess-1097.workflow-off"
touch "$WORKFLOW_OFF_MARKER"
assert_approve "A5" "Write + memory dir + WORKFLOW_OFF active → approve" \
    '{"tool_name":"Write","tool_input":{"file_path":"'"$MEMORY_DIR"'/MEMORY.md"},"session_id":"test-sess-1097","agent_id":""}'
rm -f "$WORKFLOW_OFF_MARKER"

# A6: Edit + memory dir → block
assert_block "A6" "Edit + memory dir → block" \
    '{"tool_name":"Edit","tool_input":{"file_path":"'"$MEMORY_DIR"'/MEMORY.md"},"session_id":"test-sess-1097","agent_id":""}'

# A7: MultiEdit + memory dir → block
assert_block "A7" "MultiEdit + memory dir → block" \
    '{"tool_name":"MultiEdit","tool_input":{"file_path":"'"$MEMORY_DIR"'/MEMORY.md"},"session_id":"test-sess-1097","agent_id":""}'

# A8: editFiles + memory dir → block
assert_block "A8" "editFiles + memory dir → block" \
    '{"tool_name":"editFiles","tool_input":{"file_path":"'"$MEMORY_DIR"'/MEMORY.md"},"session_id":"test-sess-1097","agent_id":""}'

# A9: Write + empty file_path → approve
assert_approve "A9" "Write + empty file_path → approve" \
    '{"tool_name":"Write","tool_input":{"file_path":""},"session_id":"test-sess-1097","agent_id":""}'

# ===========================================================================
# Section B — Error / fail cases
# ===========================================================================
echo ""
echo "=== Section B — Error / fail cases ==="

# B10: Malformed JSON stdin → approve (fail-open)
b10_input_file="$(mktemp "$TMPDIR_ROOT/b10_input.XXXXXX")"
printf '%s' 'NOT VALID JSON {{{' > "$b10_input_file"
b10_result=$(
    (
        export CLAUDE_WORKFLOW_DIR="$CLAUDE_WORKFLOW_DIR"
        export WORKFLOW_PLANS_DIR="$WORKFLOW_PLANS_DIR"
        export CLAUDE_CODE_SESSION_ID="test-sess-1097"
        run_with_timeout node "$HOOK" < "$b10_input_file" 2>/dev/null
    )
) || true
rm -f "$b10_input_file"
b10_decision=$(node -e "try{const d=JSON.parse(process.argv[1]);process.stdout.write(d.decision||'')}catch(e){}" -- "$b10_result" 2>/dev/null || true)
if [ "$b10_decision" = "approve" ]; then
    pass "B10. Malformed JSON stdin → approve (fail-open)"
else
    fail "B10. Malformed JSON stdin — expected approve, got: ${b10_result}"
fi

# B11: Missing file_path → approve
assert_approve "B11" "Missing file_path → approve" \
    '{"tool_name":"Write","tool_input":{},"session_id":"test-sess-1097","agent_id":""}'

# B12: Session ID unresolvable (all env vars unset) → block (fail-closed: no sid means can't verify bypass)
b12_input_file="$(mktemp "$TMPDIR_ROOT/b12_input.XXXXXX")"
printf '%s' '{"tool_name":"Write","tool_input":{"file_path":"'"$MEMORY_DIR"'/MEMORY.md"},"session_id":"","agent_id":""}' > "$b12_input_file"
b12_result=$(
    (
        unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
        unset CLAUDE_SESSION_ID 2>/dev/null || true
        unset CLAUDE_ENV_FILE 2>/dev/null || true
        export CLAUDE_WORKFLOW_DIR="$CLAUDE_WORKFLOW_DIR"
        export WORKFLOW_PLANS_DIR="$WORKFLOW_PLANS_DIR"
        run_with_timeout node "$HOOK" < "$b12_input_file" 2>/dev/null
    )
) || true
rm -f "$b12_input_file"
b12_decision=$(node -e "try{const d=JSON.parse(process.argv[1]);process.stdout.write(d.decision||'')}catch(e){}" -- "$b12_result" 2>/dev/null || true)
if [ "$b12_decision" = "block" ]; then
    pass "B12. Session ID unresolvable (empty session_id, no env vars) → block (fail-closed)"
else
    fail "B12. Session ID unresolvable — expected block (fail-closed), got: ${b12_result}"
fi

# B13: Marker file exists but is a directory (unlinkSync fails with EISDIR) → block (fail-closed)
# Use a distinct session ID to avoid path conflict with A4's marker file
B13_SID="test-sess-b13"
MARKER_DIR_PATH="$WORKFLOW_PLANS_DIR/${B13_SID}.memory-write-allow.tmp"
rm -f "$MARKER_DIR_PATH" 2>/dev/null || true
mkdir -p "$MARKER_DIR_PATH"
b13_result=$(run_hook \
    '{"tool_name":"Write","tool_input":{"file_path":"'"$MEMORY_DIR"'/MEMORY.md"},"session_id":"'"$B13_SID"'","agent_id":""}' \
    "CLAUDE_CODE_SESSION_ID=$B13_SID")
b13_decision=$(node -e "try{const d=JSON.parse(process.argv[1]);process.stdout.write(d.decision||'')}catch(e){}" -- "$b13_result" 2>/dev/null || true)
if [ "$b13_decision" = "block" ]; then
    pass "B13. Marker is a directory (unlinkSync EISDIR) → block (fail-closed)"
else
    fail "B13. Marker is a directory (unlinkSync EISDIR) — expected block (fail-closed), got: ${b13_result}"
fi
rm -rf "$MARKER_DIR_PATH"

# ===========================================================================
# Section C — Edge cases
# ===========================================================================
echo ""
echo "=== Section C — Edge cases ==="

# C14: Windows backslash path under memory dir → block
# Send a properly JSON-encoded backslash path (the format Claude Code actually sends).
# repairWindowsPaths converts \\ → / so isUnderPath can match.
C14_JSON="$(node -e "const os=require('os'),path=require('path');const d=path.join(os.homedir(),'.claude','projects','c--git-agents','memory');const fp=d+path.sep+'MEMORY.md';process.stdout.write(JSON.stringify({tool_name:'Write',tool_input:{file_path:fp},session_id:'test-sess-1097',agent_id:''}))")"
assert_block "C14" "Windows backslash path under memory dir → block" "$C14_JSON"

# C15: Memory dir subdirectory → block
assert_block "C15" "Memory dir subdirectory → block" \
    '{"tool_name":"Write","tool_input":{"file_path":"'"$MEMORY_DIR"'/subdir/foo.md"},"session_id":"test-sess-1097","agent_id":""}'

# C16: Path with "memory" in name but not under MEMORY_DIR → approve
assert_approve "C16" "Path with 'memory' in name but not under MEMORY_DIR → approve" \
    '{"tool_name":"Write","tool_input":{"file_path":"/some/other/memory/foo.md"},"session_id":"test-sess-1097","agent_id":""}'

# ===========================================================================
# Section D — One-shot marker idempotency
# ===========================================================================
echo ""
echo "=== Section D — One-shot marker idempotency ==="

# D17: Marker one-shot — 1st call approve, 2nd call block after marker consumed
MARKER_FILE_D="$WORKFLOW_PLANS_DIR/test-sess-1097.memory-write-allow.tmp"
touch "$MARKER_FILE_D"

d17_json='{"tool_name":"Write","tool_input":{"file_path":"'"$MEMORY_DIR"'/MEMORY.md"},"session_id":"test-sess-1097","agent_id":""}'

# 1st call: should approve (consumes marker)
d17_result1=$(run_hook "$d17_json")
d17_dec1=$(node -e "try{const d=JSON.parse(process.argv[1]);process.stdout.write(d.decision||'')}catch(e){}" -- "$d17_result1" 2>/dev/null || true)

# 2nd call: marker gone, should block
d17_result2=$(run_hook "$d17_json")
d17_dec2=$(node -e "try{const d=JSON.parse(process.argv[1]);process.stdout.write(d.decision||'')}catch(e){}" -- "$d17_result2" 2>/dev/null || true)

if [ "$d17_dec1" = "approve" ] && [ "$d17_dec2" = "block" ]; then
    pass "D17. Marker one-shot: 1st call approve, 2nd call block after marker consumed"
else
    fail "D17. Marker one-shot — 1st='${d17_dec1}' (want approve), 2nd='${d17_dec2}' (want block)"
fi
# Cleanup in case first call failed and marker remains
rm -f "$MARKER_FILE_D"

# ===========================================================================
# Section E — Bash shell-write arm
# ===========================================================================
echo ""
echo "=== Section E — Bash shell-write arm ==="

# E18: Bash redirect to memory dir → block
assert_block "E18" "Bash redirect (>>) to memory dir → block" \
    '{"tool_name":"Bash","tool_input":{"command":"echo foo >> '"$MEMORY_DIR"'/MEMORY.md"},"session_id":"test-sess-1097","agent_id":""}'

# E19: Bash redirect to non-memory dir → approve
assert_approve "E19" "Bash redirect to non-memory dir → approve" \
    '{"tool_name":"Bash","tool_input":{"command":"echo foo >> /tmp/other.md"},"session_id":"test-sess-1097","agent_id":""}'

# E20: runInTerminal redirect to memory dir → block
assert_block "E20" "runInTerminal redirect to memory dir → block" \
    '{"tool_name":"runInTerminal","tool_input":{"command":"echo foo > '"$MEMORY_DIR"'/new.md"},"session_id":"test-sess-1097","agent_id":""}'

# E21: Bash tee to memory dir → block
assert_block "E21" "Bash tee to memory dir → block" \
    '{"tool_name":"Bash","tool_input":{"command":"echo bar | tee '"$MEMORY_DIR"'/MEMORY.md"},"session_id":"test-sess-1097","agent_id":""}'

# ===========================================================================
# Section F — Security / adversarial inputs
# ===========================================================================
echo ""
echo "=== Section F — Security / adversarial inputs ==="

# F22: session_id with path-traversal chars ("../") → block (fail-closed or sanitized)
# resolveSessionId validates with ^[A-Za-z0-9_-]+$ regex; traversal id returns null → block.
assert_block "F22" "session_id with path-traversal chars → block (fail-closed, traversal rejected)" \
    '{"tool_name":"Write","tool_input":{"file_path":"'"$MEMORY_DIR"'/MEMORY.md"},"session_id":"../evil-session","agent_id":""}'

# F23: null file_path (as JSON null) → approve (fail-open; hitsMemory returns false)
assert_approve "F23" "null file_path (JSON null) → approve (fail-open)" \
    '{"tool_name":"Write","tool_input":{"file_path":null},"session_id":"test-sess-1097","agent_id":""}'

# F24: file_path is a number → approve (fail-open; isUnderPath type-normalizes or returns false)
assert_approve "F24" "file_path is a number → approve (fail-open)" \
    '{"tool_name":"Write","tool_input":{"file_path":42},"session_id":"test-sess-1097","agent_id":""}'

# F25: Bash read-only command (cat) → approve (no write operators)
assert_approve "F25" "Bash read-only command → approve" \
    '{"tool_name":"Bash","tool_input":{"command":"cat '"$MEMORY_DIR"'/MEMORY.md"},"session_id":"test-sess-1097","agent_id":""}'

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
