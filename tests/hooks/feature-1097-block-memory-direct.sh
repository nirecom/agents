#!/usr/bin/env bash
# Tests: hooks/block-memory-direct.js
# Tags: workflow, hook, memory, env, scope:issue-specific
# Memory-dir writes are blocked unconditionally; WORKFLOW_OFF is the only bypass
# (the retired <sid>.memory-write-allow.tmp marker must be ignored, #2435).
# TL3 gap (hook-registration):
#   - Whether the hook actually fires needs settings.json wiring only a real CC session confirms.
#   - How CC surfaces the block reason to the model is observable only in a live session.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
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

# assert_block_reason_not_contains <id> <desc> <json> <forbidden1> [forbidden2 ...]
# Passes only when decision=block, reason is non-empty, and no forbidden substring appears.
assert_block_reason_not_contains() {
    local id="$1"
    local desc="$2"
    local json="$3"
    shift 3
    local result decision reason
    result=$(run_hook "$json")
    decision=$(node -e "try{const d=JSON.parse(process.argv[1]);process.stdout.write(d.decision||'')}catch(e){}" -- "$result" 2>/dev/null || true)
    reason=$(node -e "try{const d=JSON.parse(process.argv[1]);process.stdout.write(d.reason||'')}catch(e){}" -- "$result" 2>/dev/null || true)
    if [[ "$decision" != "block" || -z "$reason" ]]; then
        fail "${id}. ${desc} — expected block with non-empty reason, got decision='${decision}' reason='${reason}'"
        return
    fi
    local found=()
    local forbidden
    for forbidden in "$@"; do
        if printf '%s' "$reason" | grep -qF -- "$forbidden"; then
            found+=("$forbidden")
        fi
    done
    if [[ ${#found[@]} -eq 0 ]]; then
        pass "${id}. ${desc}"
    else
        fail "${id}. ${desc} — reason contains forbidden text: ${found[*]}"
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

# A3: Write + memory dir → block; rejection cites the governing rule (#1270)
assert_block_reason_contains "A3" "Write + memory dir → block citing rules/mid-workflow-findings.md" \
    '{"tool_name":"Write","tool_input":{"file_path":"'"$MEMORY_DIR"'/MEMORY.md"},"session_id":"test-sess-1097","agent_id":""}' \
    "rules/mid-workflow-findings.md"

# A4: retired allow-marker present → still block on every call, and the hook leaves the marker untouched
MARKER_FILE="$WORKFLOW_PLANS_DIR/test-sess-1097.memory-write-allow.tmp"
touch "$MARKER_FILE"
a4_json='{"tool_name":"Write","tool_input":{"file_path":"'"$MEMORY_DIR"'/MEMORY.md"},"session_id":"test-sess-1097","agent_id":""}'
a4_result1=$(run_hook "$a4_json")
a4_result2=$(run_hook "$a4_json")
a4_dec1=$(node -e "try{const d=JSON.parse(process.argv[1]);process.stdout.write(d.decision||'')}catch(e){}" -- "$a4_result1" 2>/dev/null || true)
a4_dec2=$(node -e "try{const d=JSON.parse(process.argv[1]);process.stdout.write(d.decision||'')}catch(e){}" -- "$a4_result2" 2>/dev/null || true)
a4_reason=$(node -e "try{const d=JSON.parse(process.argv[1]);process.stdout.write(d.reason||'')}catch(e){}" -- "$a4_result1" 2>/dev/null || true)
if [[ "$a4_dec1" == "block" && "$a4_dec2" == "block" && -n "$a4_reason" && -f "$MARKER_FILE" ]]; then
    pass "A4. Write + memory dir + allow-marker present → block on repeated calls, marker not consumed"
else
    a4_marker_state="absent"
    [[ -f "$MARKER_FILE" ]] && a4_marker_state="present"
    fail "A4. allow-marker must not bypass — 1st='${a4_dec1}', 2nd='${a4_dec2}' (want block/block), reason-empty=$([[ -z "$a4_reason" ]] && echo yes || echo no), marker=${a4_marker_state} (want present)"
fi
rm -f "$MARKER_FILE"

# A4n: block reason must not carry the retired 4-option prompt
assert_block_reason_not_contains "A4n" "Block reason omits retired 4-option prompt text" \
    '{"tool_name":"Write","tool_input":{"file_path":"'"$MEMORY_DIR"'/MEMORY.md"},"session_id":"test-sess-1097","agent_id":""}' \
    "Memory write intercepted" "Allow this memory write" "Deny this memory write" \
    "Please ask the user" "Cancel / do nothing" "The dialog below asks the user"

# A5: Write + memory dir + WORKFLOW_OFF active → approve
WORKFLOW_OFF_MARKER="$CLAUDE_WORKFLOW_DIR/test-sess-1097.workflow-off"
touch "$WORKFLOW_OFF_MARKER"
assert_approve "A5" "Write + memory dir + WORKFLOW_OFF active → approve" \
    '{"tool_name":"Write","tool_input":{"file_path":"'"$MEMORY_DIR"'/MEMORY.md"},"session_id":"test-sess-1097","agent_id":""}'
# A5b: the WORKFLOW_OFF bypass covers the Bash arm too
assert_approve "A5b" "Bash redirect to memory dir + WORKFLOW_OFF active → approve" \
    '{"tool_name":"Bash","tool_input":{"command":"echo foo >> '"$MEMORY_DIR"'/MEMORY.md"},"session_id":"test-sess-1097","agent_id":""}'
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

# C17: MSYS2 POSIX drive-letter path (/c/Users/...) under memory dir → block.
# Git Bash delivers file_path in this form to the hook; normalizeCwd must fold
# /c/... back to C:\... before isUnderPath, or the guard fails open. win32-only:
# on POSIX, /c/... is legitimately not under a $HOME-rooted MEMORY_DIR.
MEMORY_DIR_MSYS="$(node -e "const os=require('os'),path=require('path');if(process.platform!=='win32')process.exit(0);const home=os.homedir();const m=home.match(/^([A-Za-z]):/);if(!m)process.exit(0);const rel=path.join(home,'.claude','projects','c--git-agents','memory').slice(2).split(path.sep).join('/');process.stdout.write('/'+m[1].toLowerCase()+rel);")"
if [ -n "$MEMORY_DIR_MSYS" ]; then
    assert_block "C17" "MSYS2 /c/ drive-letter path under memory dir → block (normalizeCwd)" \
        '{"tool_name":"Write","tool_input":{"file_path":"'"$MEMORY_DIR_MSYS"'/MEMORY.md"},"session_id":"test-sess-1097","agent_id":""}'
else
    echo "SKIP: C17 (MSYS2 /c/ path form) — not win32"
fi

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

# E22: Bash redirect to MSYS2 /c/ drive-letter memory path → block (bashHitsMemory
# arm of the normalizeCwd fix; symmetric with C17). win32-only for the same reason.
if [ -n "$MEMORY_DIR_MSYS" ]; then
    assert_block "E22" "Bash redirect to MSYS2 /c/ memory path → block (normalizeCwd)" \
        '{"tool_name":"Bash","tool_input":{"command":"echo foo >> '"$MEMORY_DIR_MSYS"'/MEMORY.md"},"session_id":"test-sess-1097","agent_id":""}'
else
    echo "SKIP: E22 (MSYS2 /c/ path form) — not win32"
fi

# E23: retired allow-marker does not bypass the Bash arm either (symmetric with A4)
MARKER_FILE_E="$WORKFLOW_PLANS_DIR/test-sess-1097.memory-write-allow.tmp"
touch "$MARKER_FILE_E"
assert_block "E23" "Bash redirect to memory dir + allow-marker present → block" \
    '{"tool_name":"Bash","tool_input":{"command":"echo foo >> '"$MEMORY_DIR"'/MEMORY.md"},"session_id":"test-sess-1097","agent_id":""}'
rm -f "$MARKER_FILE_E"

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
