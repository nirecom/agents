#!/usr/bin/env bash
# Tests: hooks/block-memory-direct.js
# Tags: workflow, hook, memory, env, scope:issue-specific
# Memory-dir writes are blocked unconditionally; WORKFLOW_OFF is the only bypass
# (the retired <sid>.memory-write-allow.tmp marker must be ignored, #2435).
# TL3 gap (hook-registration):
#   - Whether the hook actually fires needs settings.json wiring only a real CC session confirms.
#   - How CC surfaces the block reason to the model is observable only in a live session.
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
. "$AGENTS_DIR/tests/lib/harness.sh"

HOOK="$AGENTS_DIR/hooks/block-memory-direct.js"

# ---------------------------------------------------------------------------
# Temp dir / env setup
# ---------------------------------------------------------------------------
TMPDIR_ROOT="$(node -e "const os=require('os'),path=require('path'),fs=require('fs'),crypto=require('crypto');const d=path.join(os.tmpdir(),'bmtest-'+crypto.randomBytes(6).toString('hex'));fs.mkdirSync(d,{recursive:true});process.stdout.write(d);")"
harness_isolate "$TMPDIR_ROOT"
HOOK_RC_FILE="$TMPDIR_ROOT/hook_rc"

# Derive MEMORY_DIR the same way the hook does:
# path.join(os.homedir(), '.claude', 'projects', 'c--git-agents', 'memory')
MEMORY_DIR="$(node -e "const os=require('os'),path=require('path');process.stdout.write(path.join(os.homedir(),'.claude','projects','c--git-agents','memory').split(path.sep).join('/'));")"

# MSYS2 POSIX drive-letter form — shared by C17 and E22; defined outside all spans
MEMORY_DIR_MSYS="$(node -e "const os=require('os'),path=require('path');if(process.platform!=='win32')process.exit(0);const home=os.homedir();const m=home.match(/^([A-Za-z]):/);if(!m)process.exit(0);const rel=path.join(home,'.claude','projects','c--git-agents','memory').slice(2).split(path.sep).join('/');process.stdout.write('/'+m[1].toLowerCase()+rel);")"

cleanup() { rm -rf "$TMPDIR_ROOT"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helper: run hook with given JSON, optional extra env vars (KEY=VAL format)
# ---------------------------------------------------------------------------
run_hook() {
    local json="$1"
    shift
    local extra_env=("$@")
    local input_file result _rc
    input_file="$(mktemp "$TMPDIR_ROOT/hook_input.XXXXXX")"
    printf '%s' "$json" > "$input_file"
    result=$(
        (
            export CLAUDE_WORKFLOW_DIR="$CLAUDE_WORKFLOW_DIR"
            export WORKFLOW_PLANS_DIR="$WORKFLOW_PLANS_DIR"
            export CLAUDE_CODE_SESSION_ID="test-sess-1097"
            # shellcheck disable=SC2163
            for kv in "${extra_env[@]+"${extra_env[@]}"}"; do export "$kv"; done
            run_with_timeout 120 node "$HOOK" < "$input_file" 2>/dev/null
        )
    )
    _rc=$?
    printf '%d' "$_rc" > "$HOOK_RC_FILE"
    rm -f "$input_file"
    printf '%s' "$result"
}

# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------
assert_approve() {
    local id="$1" desc="$2" json="$3"
    shift 3
    local extra_env=("$@")
    local result decision hook_rc
    result=$(run_hook "$json" "${extra_env[@]+"${extra_env[@]}"}")
    hook_rc=$(cat "$HOOK_RC_FILE" 2>/dev/null || echo "1")
    if [ "$hook_rc" != "0" ]; then
        fail "${id}. ${desc} — hook process exited with rc=${hook_rc}"
        return
    fi
    decision=$(node -e "try{const d=JSON.parse(process.argv[1]);process.stdout.write(d.decision||'')}catch(e){}" -- "$result" 2>/dev/null || true)
    if [ "$decision" = "approve" ]; then
        pass "${id}. ${desc}"
    else
        fail "${id}. ${desc} — expected approve, got: ${result}"
    fi
}

assert_block() {
    local id="$1" desc="$2" json="$3"
    shift 3
    local extra_env=("$@")
    local result decision hook_rc
    result=$(run_hook "$json" "${extra_env[@]+"${extra_env[@]}"}")
    hook_rc=$(cat "$HOOK_RC_FILE" 2>/dev/null || echo "1")
    if [ "$hook_rc" != "0" ]; then
        fail "${id}. ${desc} — hook process exited with rc=${hook_rc}"
        return
    fi
    decision=$(node -e "try{const d=JSON.parse(process.argv[1]);process.stdout.write(d.decision||'')}catch(e){}" -- "$result" 2>/dev/null || true)
    if [ "$decision" = "block" ]; then
        pass "${id}. ${desc}"
    else
        fail "${id}. ${desc} — expected block, got: ${result}"
    fi
}

# assert_block_reason_contains <id> <desc> <json> <substr1> [substr2 ...]
# Passes when decision=block and every listed substring appears in the reason.
assert_block_reason_contains() {
    local id="$1" desc="$2" json="$3"
    shift 3
    local result decision reason hook_rc
    result=$(run_hook "$json")
    hook_rc=$(cat "$HOOK_RC_FILE" 2>/dev/null || echo "1")
    if [ "$hook_rc" != "0" ]; then
        fail "${id}. ${desc} — hook process exited with rc=${hook_rc}"
        return
    fi
    decision=$(node -e "try{const d=JSON.parse(process.argv[1]);process.stdout.write(d.decision||'')}catch(e){}" -- "$result" 2>/dev/null || true)
    reason=$(node -e "try{const d=JSON.parse(process.argv[1]);process.stdout.write(d.reason||'')}catch(e){}" -- "$result" 2>/dev/null || true)
    if [ "$decision" != "block" ]; then
        fail "${id}. ${desc} — expected block, got decision='${decision}' reason='${reason}'"
        return
    fi
    local missing=() substr
    for substr in "$@"; do
        if ! echo "$reason" | grep -qF "$substr"; then
            missing+=("$substr")
        fi
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        pass "${id}. ${desc}"
    else
        fail "${id}. ${desc} — reason missing substrings: ${missing[*]} (reason='${reason}')"
    fi
}

# assert_block_reason_not_contains <id> <desc> <json> <forbidden1> [forbidden2 ...]
# Passes only when decision=block, reason is non-empty, and no forbidden substring appears.
assert_block_reason_not_contains() {
    local id="$1" desc="$2" json="$3"
    shift 3
    local result decision reason hook_rc
    result=$(run_hook "$json")
    hook_rc=$(cat "$HOOK_RC_FILE" 2>/dev/null || echo "1")
    if [ "$hook_rc" != "0" ]; then
        fail "${id}. ${desc} — hook process exited with rc=${hook_rc}"
        return
    fi
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

case_begin "a1-write-non-memory" "hooks/block-memory-direct.js"
assert_approve "A1" "Write + non-memory path → approve" \
    '{"tool_name":"Write","tool_input":{"file_path":"src/foo.js"},"session_id":"test-sess-1097","agent_id":""}'
case_end

case_begin "a2-read-memory" "hooks/block-memory-direct.js"
assert_approve "A2" "Read tool → approve (not in checked tools)" \
    '{"tool_name":"Read","tool_input":{"file_path":"'"$MEMORY_DIR"'/MEMORY.md"},"session_id":"test-sess-1097","agent_id":""}'
case_end

case_begin "a3-write-memory-block" "hooks/block-memory-direct.js"
assert_block_reason_contains "A3" "Write + memory dir → block with unconditional message" \
    '{"tool_name":"Write","tool_input":{"file_path":"'"$MEMORY_DIR"'/MEMORY.md"},"session_id":"test-sess-1097","agent_id":""}' \
    "rules/mid-workflow-findings.md" "unconditionally blocked" "/issue-create"
case_end

case_begin "a4-allow-marker-still-blocks" "hooks/block-memory-direct.js"
MARKER_FILE="$WORKFLOW_PLANS_DIR/test-sess-1097.memory-write-allow.tmp"
touch "$MARKER_FILE"
a4_json='{"tool_name":"Write","tool_input":{"file_path":"'"$MEMORY_DIR"'/MEMORY.md"},"session_id":"test-sess-1097","agent_id":""}'
a4_result1=$(run_hook "$a4_json")
a4_rc1=$(cat "$HOOK_RC_FILE" 2>/dev/null || echo "1")
a4_result2=$(run_hook "$a4_json")
a4_rc2=$(cat "$HOOK_RC_FILE" 2>/dev/null || echo "1")
a4_dec1=$(node -e "try{const d=JSON.parse(process.argv[1]);process.stdout.write(d.decision||'')}catch(e){}" -- "$a4_result1" 2>/dev/null || true)
a4_dec2=$(node -e "try{const d=JSON.parse(process.argv[1]);process.stdout.write(d.decision||'')}catch(e){}" -- "$a4_result2" 2>/dev/null || true)
a4_reason=$(node -e "try{const d=JSON.parse(process.argv[1]);process.stdout.write(d.reason||'')}catch(e){}" -- "$a4_result1" 2>/dev/null || true)
if [[ "$a4_dec1" == "block" && "$a4_dec2" == "block" && -n "$a4_reason" && -f "$MARKER_FILE" && "$a4_rc1" == "0" && "$a4_rc2" == "0" ]]; then
    pass "A4. Write + memory dir + allow-marker present → block on repeated calls, marker not consumed"
else
    a4_marker_state="absent"
    [[ -f "$MARKER_FILE" ]] && a4_marker_state="present"
    fail "A4. allow-marker must not bypass — 1st='${a4_dec1}', 2nd='${a4_dec2}' (want block/block), reason-empty=$([[ -z "$a4_reason" ]] && echo yes || echo no), marker=${a4_marker_state} (want present), rc1=${a4_rc1}, rc2=${a4_rc2}"
fi
rm -f "$MARKER_FILE"
case_end

case_begin "a4n-block-reason-no-retired-prompt" "hooks/block-memory-direct.js"
assert_block_reason_not_contains "A4n" "Block reason omits retired 4-option prompt text" \
    '{"tool_name":"Write","tool_input":{"file_path":"'"$MEMORY_DIR"'/MEMORY.md"},"session_id":"test-sess-1097","agent_id":""}' \
    "Memory write intercepted" "Allow this memory write" "Deny this memory write" \
    "Please ask the user" "Cancel / do nothing" "The dialog below asks the user"
case_end

case_begin "a5-workflow-off-bypass-write" "hooks/block-memory-direct.js"
WORKFLOW_OFF_MARKER="$CLAUDE_WORKFLOW_DIR/test-sess-1097.workflow-off"
touch "$WORKFLOW_OFF_MARKER"
assert_approve "A5" "Write + memory dir + WORKFLOW_OFF active → approve" \
    '{"tool_name":"Write","tool_input":{"file_path":"'"$MEMORY_DIR"'/MEMORY.md"},"session_id":"test-sess-1097","agent_id":""}'
rm -f "$WORKFLOW_OFF_MARKER"
case_end

case_begin "a5b-workflow-off-bypass-bash" "hooks/block-memory-direct.js"
WORKFLOW_OFF_MARKER="$CLAUDE_WORKFLOW_DIR/test-sess-1097.workflow-off"
touch "$WORKFLOW_OFF_MARKER"
assert_approve "A5b" "Bash redirect to memory dir + WORKFLOW_OFF active → approve" \
    '{"tool_name":"Bash","tool_input":{"command":"echo foo >> '"$MEMORY_DIR"'/MEMORY.md"},"session_id":"test-sess-1097","agent_id":""}'
rm -f "$WORKFLOW_OFF_MARKER"
case_end

case_begin "a6-edit-memory-block" "hooks/block-memory-direct.js"
assert_block "A6" "Edit + memory dir → block" \
    '{"tool_name":"Edit","tool_input":{"file_path":"'"$MEMORY_DIR"'/MEMORY.md"},"session_id":"test-sess-1097","agent_id":""}'
case_end

case_begin "a7-multiedit-memory-block" "hooks/block-memory-direct.js"
assert_block "A7" "MultiEdit + memory dir → block" \
    '{"tool_name":"MultiEdit","tool_input":{"file_path":"'"$MEMORY_DIR"'/MEMORY.md"},"session_id":"test-sess-1097","agent_id":""}'
case_end

case_begin "a8-editfiles-memory-block" "hooks/block-memory-direct.js"
assert_block "A8" "editFiles + memory dir → block" \
    '{"tool_name":"editFiles","tool_input":{"file_path":"'"$MEMORY_DIR"'/MEMORY.md"},"session_id":"test-sess-1097","agent_id":""}'
case_end

case_begin "a9-write-empty-path" "hooks/block-memory-direct.js"
assert_approve "A9" "Write + empty file_path → approve" \
    '{"tool_name":"Write","tool_input":{"file_path":""},"session_id":"test-sess-1097","agent_id":""}'
case_end

# ===========================================================================
# Section B — Error / fail cases
# ===========================================================================
echo ""
echo "=== Section B — Error / fail cases ==="

case_begin "b10-malformed-json-fail-open" "hooks/block-memory-direct.js"
b10_input_file="$(mktemp "$TMPDIR_ROOT/b10_input.XXXXXX")"
printf '%s' 'NOT VALID JSON {{{' > "$b10_input_file"
b10_result=$(
    (
        export CLAUDE_WORKFLOW_DIR="$CLAUDE_WORKFLOW_DIR"
        export WORKFLOW_PLANS_DIR="$WORKFLOW_PLANS_DIR"
        export CLAUDE_CODE_SESSION_ID="test-sess-1097"
        run_with_timeout 120 node "$HOOK" < "$b10_input_file" 2>/dev/null
    )
)
printf '%d' "$?" > "$HOOK_RC_FILE"
rm -f "$b10_input_file"
b10_rc=$(cat "$HOOK_RC_FILE" 2>/dev/null || echo "1")
b10_decision=$(node -e "try{const d=JSON.parse(process.argv[1]);process.stdout.write(d.decision||'')}catch(e){}" -- "$b10_result" 2>/dev/null || true)
if [ "$b10_rc" = "0" ] && [ "$b10_decision" = "approve" ]; then
    pass "B10. Malformed JSON stdin → approve (fail-open)"
else
    fail "B10. Malformed JSON stdin — expected approve rc=0, got: rc=${b10_rc} decision=${b10_decision} result=${b10_result}"
fi
case_end

case_begin "b11-missing-filepath-fail-open" "hooks/block-memory-direct.js"
assert_approve "B11" "Missing file_path → approve" \
    '{"tool_name":"Write","tool_input":{},"session_id":"test-sess-1097","agent_id":""}'
case_end

case_begin "b12-no-session-id-fail-closed" "hooks/block-memory-direct.js"
b12_input_file="$(mktemp "$TMPDIR_ROOT/b12_input.XXXXXX")"
printf '%s' '{"tool_name":"Write","tool_input":{"file_path":"'"$MEMORY_DIR"'/MEMORY.md"},"session_id":"","agent_id":""}' > "$b12_input_file"
b12_result=$(
    (
        unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
        export CLAUDE_WORKFLOW_DIR="$CLAUDE_WORKFLOW_DIR"
        export WORKFLOW_PLANS_DIR="$WORKFLOW_PLANS_DIR"
        run_with_timeout 120 node "$HOOK" < "$b12_input_file" 2>/dev/null
    )
)
printf '%d' "$?" > "$HOOK_RC_FILE"
rm -f "$b12_input_file"
b12_rc=$(cat "$HOOK_RC_FILE" 2>/dev/null || echo "1")
b12_decision=$(node -e "try{const d=JSON.parse(process.argv[1]);process.stdout.write(d.decision||'')}catch(e){}" -- "$b12_result" 2>/dev/null || true)
if [ "$b12_rc" = "0" ] && [ "$b12_decision" = "block" ]; then
    pass "B12. Session ID unresolvable (empty session_id, no env vars) → block (fail-closed)"
else
    fail "B12. Session ID unresolvable — expected block rc=0, got: rc=${b12_rc} decision=${b12_decision} result=${b12_result}"
fi
case_end

# ===========================================================================
# Section C — Edge cases
# ===========================================================================
echo ""
echo "=== Section C — Edge cases ==="

case_begin "c14-windows-backslash-path" "hooks/block-memory-direct.js"
C14_JSON="$(node -e "const os=require('os'),path=require('path');const d=path.join(os.homedir(),'.claude','projects','c--git-agents','memory');const fp=d+path.sep+'MEMORY.md';process.stdout.write(JSON.stringify({tool_name:'Write',tool_input:{file_path:fp},session_id:'test-sess-1097',agent_id:''}))")"
assert_block "C14" "Windows backslash path under memory dir → block" "$C14_JSON"
case_end

case_begin "c15-memory-subdir" "hooks/block-memory-direct.js"
assert_block "C15" "Memory dir subdirectory → block" \
    '{"tool_name":"Write","tool_input":{"file_path":"'"$MEMORY_DIR"'/subdir/foo.md"},"session_id":"test-sess-1097","agent_id":""}'
case_end

case_begin "c16-memory-in-name-not-under-dir" "hooks/block-memory-direct.js"
assert_approve "C16" "Path with 'memory' in name but not under MEMORY_DIR → approve" \
    '{"tool_name":"Write","tool_input":{"file_path":"/some/other/memory/foo.md"},"session_id":"test-sess-1097","agent_id":""}'
case_end

# C17: MSYS2 POSIX drive-letter path (/c/Users/...) under memory dir → block.
# Git Bash delivers file_path in this form to the hook; normalizeCwd must fold
# /c/... back to C:\... before isUnderPath, or the guard fails open. win32-only:
# on POSIX, /c/... is legitimately not under a $HOME-rooted MEMORY_DIR.
case_begin "c17-msys2-drive-letter" "hooks/block-memory-direct.js"
if [ -n "$MEMORY_DIR_MSYS" ]; then
    assert_block "C17" "MSYS2 /c/ drive-letter path under memory dir → block (normalizeCwd)" \
        '{"tool_name":"Write","tool_input":{"file_path":"'"$MEMORY_DIR_MSYS"'/MEMORY.md"},"session_id":"test-sess-1097","agent_id":""}'
else
    skip "C17 (MSYS2 /c/ path form) — not win32"
fi
case_end

# ===========================================================================
# Section E — Bash shell-write arm
# ===========================================================================
echo ""
echo "=== Section E — Bash shell-write arm ==="

case_begin "e18-bash-redirect-memory" "hooks/block-memory-direct.js"
assert_block "E18" "Bash redirect (>>) to memory dir → block" \
    '{"tool_name":"Bash","tool_input":{"command":"echo foo >> '"$MEMORY_DIR"'/MEMORY.md"},"session_id":"test-sess-1097","agent_id":""}'
case_end

case_begin "e19-bash-redirect-non-memory" "hooks/block-memory-direct.js"
assert_approve "E19" "Bash redirect to non-memory dir → approve" \
    '{"tool_name":"Bash","tool_input":{"command":"echo foo >> /tmp/other.md"},"session_id":"test-sess-1097","agent_id":""}'
case_end

case_begin "e20-run-in-terminal-redirect" "hooks/block-memory-direct.js"
assert_block "E20" "runInTerminal redirect to memory dir → block" \
    '{"tool_name":"runInTerminal","tool_input":{"command":"echo foo > '"$MEMORY_DIR"'/new.md"},"session_id":"test-sess-1097","agent_id":""}'
case_end

case_begin "e21-bash-tee-memory" "hooks/block-memory-direct.js"
assert_block "E21" "Bash tee to memory dir → block" \
    '{"tool_name":"Bash","tool_input":{"command":"echo bar | tee '"$MEMORY_DIR"'/MEMORY.md"},"session_id":"test-sess-1097","agent_id":""}'
case_end

# E22: Bash redirect to MSYS2 /c/ drive-letter memory path → block (bashHitsMemory
# arm of the normalizeCwd fix; symmetric with C17). win32-only for the same reason.
case_begin "e22-bash-msys2-drive-letter" "hooks/block-memory-direct.js"
if [ -n "$MEMORY_DIR_MSYS" ]; then
    assert_block "E22" "Bash redirect to MSYS2 /c/ memory path → block (normalizeCwd)" \
        '{"tool_name":"Bash","tool_input":{"command":"echo foo >> '"$MEMORY_DIR_MSYS"'/MEMORY.md"},"session_id":"test-sess-1097","agent_id":""}'
else
    skip "E22 (MSYS2 /c/ path form) — not win32"
fi
case_end

case_begin "e23-bash-allow-marker-still-blocks" "hooks/block-memory-direct.js"
MARKER_FILE_E="$WORKFLOW_PLANS_DIR/test-sess-1097.memory-write-allow.tmp"
touch "$MARKER_FILE_E"
assert_block "E23" "Bash redirect to memory dir + allow-marker present → block" \
    '{"tool_name":"Bash","tool_input":{"command":"echo foo >> '"$MEMORY_DIR"'/MEMORY.md"},"session_id":"test-sess-1097","agent_id":""}'
rm -f "$MARKER_FILE_E"
case_end

case_begin "e24-run-commands-redirect-memory" "hooks/block-memory-direct.js"
assert_block "E24" "runCommands redirect to memory dir → block" \
    '{"tool_name":"runCommands","tool_input":{"command":"echo foo >> '"$MEMORY_DIR"'/MEMORY.md"},"session_id":"test-sess-1097","agent_id":""}'
case_end

case_begin "e25-run-commands-redirect-non-memory" "hooks/block-memory-direct.js"
assert_approve "E25" "runCommands redirect to non-memory dir → approve" \
    '{"tool_name":"runCommands","tool_input":{"command":"echo foo >> /tmp/other.md"},"session_id":"test-sess-1097","agent_id":""}'
case_end

# ===========================================================================
# Section F — Security / adversarial inputs
# ===========================================================================
echo ""
echo "=== Section F — Security / adversarial inputs ==="

case_begin "f22-session-path-traversal" "hooks/block-memory-direct.js"
assert_block "F22" "session_id with path-traversal chars → block (fail-closed, traversal rejected)" \
    '{"tool_name":"Write","tool_input":{"file_path":"'"$MEMORY_DIR"'/MEMORY.md"},"session_id":"../evil-session","agent_id":""}'
case_end

case_begin "f23-null-filepath" "hooks/block-memory-direct.js"
assert_approve "F23" "null file_path (JSON null) → approve (fail-open)" \
    '{"tool_name":"Write","tool_input":{"file_path":null},"session_id":"test-sess-1097","agent_id":""}'
case_end

case_begin "f24-numeric-filepath" "hooks/block-memory-direct.js"
assert_approve "F24" "file_path is a number → approve (fail-open)" \
    '{"tool_name":"Write","tool_input":{"file_path":42},"session_id":"test-sess-1097","agent_id":""}'
case_end

case_begin "f25-bash-readonly" "hooks/block-memory-direct.js"
assert_approve "F25" "Bash read-only command → approve" \
    '{"tool_name":"Bash","tool_input":{"command":"cat '"$MEMORY_DIR"'/MEMORY.md"},"session_id":"test-sess-1097","agent_id":""}'
case_end

echo ""
echo "# PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
