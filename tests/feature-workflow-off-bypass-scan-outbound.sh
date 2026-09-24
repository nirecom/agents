#!/bin/bash
# tests/feature-workflow-off-bypass-scan-outbound.sh
# Tests: hooks/scan-outbound.js
# Tags: scan, filter, outbound, hook, workflow, scope:common
#
# PR2: scan-outbound.js must NOT bypass the private-info security scan even when
# the session has a <workflowDir>/<sid>.workflow-off marker. Contract: without a
# marker the hook just runs without crashing (verdict depends on content +
# public-repo detection, not asserted); with marker + valid sid the scan still
# runs and blocks; with a traversal sid the bypass MUST NOT apply.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
HOOK_JS="${_AGENTS_DIR_NODE}/hooks/scan-outbound.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'escanout-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Plans-dir isolation (#1799): supervisor-emit must never write into the
# developer's real ~/.workflow-plans/. Pinned alongside CLAUDE_WORKFLOW_DIR.
WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_PLANS_DIR"
export WORKFLOW_PLANS_DIR

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

require_hook() {
    if [ ! -f "$HOOK_JS" ]; then
        fail "$1 (hooks/scan-outbound.js not present)"
        return 1
    fi
    return 0
}

fresh_workflow_dir() {
    local d="$TMPDIR_BASE/wf-$RANDOM-$$"
    mkdir -p "$d"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$d"
    else
        echo "$d"
    fi
}

write_marker_file() {
    local wfdir="$1" sid="$2"
    printf '{"set_at":"2026-01-01T00:00:00Z"}\n' > "$wfdir/$sid.workflow-off"
}

json_quote() {
    node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$1"
}

# Build an Edit payload writing benign content. Note: scan-outbound detects
# private-info patterns; we use a clearly synthetic value so the test does not
# accidentally land in any blocklist.
build_edit_payload() {
    local sid="$1" fp="$2" new="$3"
    local q_sid q_fp q_new
    q_sid="$(json_quote "$sid")"
    q_fp="$(json_quote "$fp")"
    q_new="$(json_quote "$new")"
    printf '{"session_id":%s,"tool_name":"Edit","tool_input":{"file_path":%s,"old_string":"x","new_string":%s}}' \
        "$q_sid" "$q_fp" "$q_new"
}

HOOK_OUT=""
HOOK_RC=0
run_hook() {
    local payload="$1" wfdir="$2"
    HOOK_RC=0
    HOOK_OUT="$(printf '%s' "$payload" | run_with_timeout 30 \
        env -u CLAUDE_ENV_FILE \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        "WORKFLOW_PLANS_DIR=$WORKFLOW_PLANS_DIR" \
        node "$HOOK_JS" 2>&1)" || HOOK_RC=$?
}

# ============================================================================
# Tests
# ============================================================================

# Content that the scanner reliably flags: an RFC1918 private IPv4 literal.
# This avoids depending on any specific secret-like pattern.
PRIVATE_INFO_CONTENT='Internal note: gateway at 10.20.30.40 is offline.'

# A: Without marker, hook scans and blocks private-info content (baseline).
test_A_no_marker_blocks_private_info() {
    require_hook "A" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="testsession123"
    local payload; payload="$(build_edit_payload "$sid" "$TMPDIR_BASE/foo.txt" "$PRIVATE_INFO_CONTENT")"
    run_hook "$payload" "$wfdir"
    if [ "$HOOK_RC" -ne 0 ]; then
        fail "A: hook crashed rc=$HOOK_RC (out: $HOOK_OUT)"
        return
    fi
    if echo "$HOOK_OUT" | grep -q '"decision":"block"'; then
        pass "A: no marker → scan blocks private-info content (baseline)"
    else
        fail "A: expected block on private-info content but got: $HOOK_OUT"
    fi
}

# B: With marker present and valid sid, private-info scan still blocks (no bypass).
test_B_marker_still_scans_private_info() {
    require_hook "B" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="testsession123"
    write_marker_file "$wfdir" "$sid"
    local payload; payload="$(build_edit_payload "$sid" "$TMPDIR_BASE/foo.txt" "$PRIVATE_INFO_CONTENT")"
    run_hook "$payload" "$wfdir"
    if [ "$HOOK_RC" -ne 0 ]; then
        fail "B: hook crashed rc=$HOOK_RC (out: $HOOK_OUT)"
        return
    fi
    if echo "$HOOK_OUT" | grep -q '"decision":"block"'; then
        pass "B: marker present → scan still blocks private-info (no bypass)"
    elif echo "$HOOK_OUT" | grep -q '"decision":"approve"'; then
        fail "B: marker bypassed private-info scan (expected block): $HOOK_OUT"
    else
        fail "B: expected block decision but got: $HOOK_OUT"
    fi
}

# B2: With marker present and valid sid, benign (non-flagged) content still approves.
# This verifies that the fix doesn't accidentally turn the hook into an unconditional blocker.
test_B2_marker_approves_benign_content() {
    require_hook "B2" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="testsession123"
    write_marker_file "$wfdir" "$sid"
    local benign_content="This is a perfectly ordinary log message with no secrets."
    local payload; payload="$(build_edit_payload "$sid" "$TMPDIR_BASE/bar.txt" "$benign_content")"
    run_hook "$payload" "$wfdir"
    if [ "$HOOK_RC" -ne 0 ]; then
        fail "B2: hook crashed rc=$HOOK_RC (out: $HOOK_OUT)"
        return
    fi
    if echo "$HOOK_OUT" | grep -q '"decision":"block"'; then
        fail "B2: marker present but hook blocked benign content (unconditional blocker bug): $HOOK_OUT"
    elif echo "$HOOK_OUT" | grep -q '"decision":"approve"'; then
        pass "B2: marker present → benign content still approves (not unconditional blocker)"
    else
        fail "B2: unexpected response for benign content: $HOOK_OUT"
    fi
}

# C: Traversal sid must NOT bypass — same private-info content still blocks.
test_C_traversal_sid_no_bypass() {
    require_hook "C" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local parent; parent="$(dirname "$wfdir")"
    printf '{"set_at":"x"}' > "$parent/evil.workflow-off"
    local payload; payload="$(build_edit_payload "../evil" "$TMPDIR_BASE/foo.txt" "$PRIVATE_INFO_CONTENT")"
    run_hook "$payload" "$wfdir"
    rm -f "$parent/evil.workflow-off" 2>/dev/null || true
    if [ "$HOOK_RC" -ne 0 ]; then
        fail "C: hook crashed rc=$HOOK_RC (out: $HOOK_OUT)"
        return
    fi
    if echo "$HOOK_OUT" | grep -q '"decision":"block"'; then
        pass "C: traversal sid → bypass NOT granted, private-info still blocks"
    else
        fail "C: traversal sid wrongly granted bypass: $HOOK_OUT"
    fi
}

# ============================================================================
# Group C (#1593): staged-content scan + inline Bash-write scan + rc=4 mapping
# ============================================================================
# hooks/scan-outbound.js must scan (a) staged file CONTENT on git commit — not
# only the -m message — and (b) inline literals of arbitrary Bash file-writes,
# and must map scanner rc=4 (blocklist unresolvable) to a block. Pre-fix the
# Bash branch scans only commit messages and forge writes, so every C-*block*
# case approves today (fail-before-fix); the C-*approve* cases guard against
# over-blocking / scope creep. Detail plan Step 9-3 / 9-4 / 9-5.

# RFC1918 IPv4 is a scan_line built-in (blocklist-independent) → reliable rc=1.
C_PRIVATE='Internal gateway at 10.20.30.40 is offline.'
C_CLEAN='Just an ordinary log line with nothing sensitive.'

c_np() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi; }

# Config dir WITH a resolvable blocklist+allowlist so the scanner never hits rc=4.
C_CFG="$TMPDIR_BASE/c-cfg"; mkdir -p "$C_CFG"
printf 'forbiddenword[0-9]+\n' > "$C_CFG/.private-info-blocklist"
: > "$C_CFG/.private-info-allowlist"
# Config dir WITHOUT a blocklist → forces rc=4 fail-closed after the fix.
C_CFG_NOBL="$TMPDIR_BASE/c-cfg-nobl"; mkdir -p "$C_CFG_NOBL"
: > "$C_CFG_NOBL/.private-info-allowlist"
# Neutral no-remote CWD so listPrivateRepoNames() resolves to [] deterministically.
C_NEUTRAL="$TMPDIR_BASE/c-neutral"; mkdir -p "$C_NEUTRAL"

c_make_repo() {
    local repo="$1"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email "t@example.com"
    git -C "$repo" config user.name "T"
    git -C "$repo" config core.hooksPath /dev/null
    git -C "$repo" commit -q --allow-empty -m init
}
c_stage() { printf '%s\n' "$2" > "$1/$3"; git -C "$1" add "$3" >/dev/null 2>&1; }

c_build_bash_payload() {
    node -e 'const j={session_id:"csid",tool_name:"Bash",tool_input:{command:process.argv[1],cwd:process.argv[2]}};console.log(JSON.stringify(j))' \
        -- "$1" "$2" 2>/dev/null
}

# c_run_hook <payload> <cfgdir> <cwd> — pins AGENTS_CONFIG_DIR at the fixture cfg
# (not $AGENTS_DIR) and runs node from <cwd>. Captures HOOK_OUT / HOOK_RC.
c_run_hook() {
    local payload="$1" cfg="$2" cwd="$3"
    HOOK_RC=0
    HOOK_OUT="$( ( cd "$cwd" && printf '%s' "$payload" | run_with_timeout 30 \
        env -u CLAUDE_ENV_FILE \
        "AGENTS_CONFIG_DIR=$cfg" \
        "CLAUDE_WORKFLOW_DIR=$(fresh_workflow_dir)" \
        "WORKFLOW_PLANS_DIR=$WORKFLOW_PLANS_DIR" \
        node "$HOOK_JS" 2>&1 ) )" || HOOK_RC=$?
}
c_is_block() { echo "$HOOK_OUT" | grep -q '"decision":"block"'; }

# C1: heredoc file-write with private inline content → block (inline scan path).
test_C1_inline_heredoc_write_blocks() {
    require_hook "C1" || return
    local f="$C_NEUTRAL/note.txt" cmd payload
    cmd="cat > $(c_np "$f") <<'EOF'
$C_PRIVATE
EOF"
    payload="$(c_build_bash_payload "$cmd" "$(c_np "$C_NEUTRAL")")"
    c_run_hook "$payload" "$C_CFG" "$C_NEUTRAL"
    if [ "$HOOK_RC" -ne 0 ]; then fail "C1: hook crashed rc=$HOOK_RC ($HOOK_OUT)"; return; fi
    if c_is_block; then pass "C1: heredoc file-write with private IP → block (fail-before-fix)"
    else fail "C1: expected block on inline heredoc private content: $HOOK_OUT"; fi
    if c_is_block && echo "$HOOK_OUT" | grep -qF "$C_PRIVATE"; then
        fail "C1: block decision echoes private content (secret leakage): $HOOK_OUT"
    fi
}

# C2: echo-redirect file-write with private inline content → block.
test_C2_inline_echo_redirect_blocks() {
    require_hook "C2" || return
    local f="$C_NEUTRAL/note2.txt" cmd payload
    cmd="echo '$C_PRIVATE' > $(c_np "$f")"
    payload="$(c_build_bash_payload "$cmd" "$(c_np "$C_NEUTRAL")")"
    c_run_hook "$payload" "$C_CFG" "$C_NEUTRAL"
    if [ "$HOOK_RC" -ne 0 ]; then fail "C2: hook crashed rc=$HOOK_RC ($HOOK_OUT)"; return; fi
    if c_is_block; then pass "C2: echo-redirect file-write with private IP → block (fail-before-fix)"
    else fail "C2: expected block on inline echo-redirect private content: $HOOK_OUT"; fi
    if c_is_block && echo "$HOOK_OUT" | grep -qF "$C_PRIVATE"; then
        fail "C2: block decision echoes private content (secret leakage): $HOOK_OUT"
    fi
}

# C3: echo-redirect file-write with CLEAN content → approve (no over-block guard).
test_C3_inline_clean_write_approves() {
    require_hook "C3" || return
    local f="$C_NEUTRAL/note3.txt" cmd payload
    cmd="echo '$C_CLEAN' > $(c_np "$f")"
    payload="$(c_build_bash_payload "$cmd" "$(c_np "$C_NEUTRAL")")"
    c_run_hook "$payload" "$C_CFG" "$C_NEUTRAL"
    if [ "$HOOK_RC" -ne 0 ]; then fail "C3: hook crashed rc=$HOOK_RC ($HOOK_OUT)"; return; fi
    if c_is_block; then fail "C3: clean file-write wrongly blocked: $HOOK_OUT"
    else pass "C3: clean file-write → approve (inline scan not an unconditional blocker)"; fi
}

# C4: non-write command carrying a private IP → approve (inline scan is write-scoped).
test_C4_non_write_not_scanned() {
    require_hook "C4" || return
    local cmd payload
    cmd="echo '$C_PRIVATE'"
    payload="$(c_build_bash_payload "$cmd" "$(c_np "$C_NEUTRAL")")"
    c_run_hook "$payload" "$C_CFG" "$C_NEUTRAL"
    if [ "$HOOK_RC" -ne 0 ]; then fail "C4: hook crashed rc=$HOOK_RC ($HOOK_OUT)"; return; fi
    if c_is_block; then fail "C4: non-write (echo to stdout) wrongly scanned+blocked: $HOOK_OUT"
    else pass "C4: non-write command → approve (inline scan scoped to file-writes)"; fi
}

# C5: runtime side-effect boundary — no inline literal → approve (out of scope).
test_C5_runtime_side_effect_out_of_scope() {
    require_hook "C5" || return
    local cmd payload
    cmd="python3 $(c_np "$C_NEUTRAL")/app.py"
    payload="$(c_build_bash_payload "$cmd" "$(c_np "$C_NEUTRAL")")"
    c_run_hook "$payload" "$C_CFG" "$C_NEUTRAL"
    if [ "$HOOK_RC" -ne 0 ]; then fail "C5: hook crashed rc=$HOOK_RC ($HOOK_OUT)"; return; fi
    if c_is_block; then fail "C5: runtime side-effect (python app.py) wrongly blocked: $HOOK_OUT"
    else pass "C5: runtime side-effect → approve (only inline literals scanned)"; fi
}

# C6: git commit with a private STAGED file but a clean -m message → block.
test_C6_staged_private_blocks() {
    require_hook "C6" || return
    local repo="$TMPDIR_BASE/c6-repo-$$"
    c_make_repo "$repo"; c_stage "$repo" "$C_PRIVATE" "leak.txt"
    local cmd payload
    cmd="git -C $(c_np "$repo") commit -m 'chore: routine update'"
    payload="$(c_build_bash_payload "$cmd" "$(c_np "$repo")")"
    c_run_hook "$payload" "$C_CFG" "$repo"
    if [ "$HOOK_RC" -ne 0 ]; then fail "C6: hook crashed rc=$HOOK_RC ($HOOK_OUT)"; return; fi
    if c_is_block; then pass "C6: private staged content (clean message) → block (fail-before-fix)"
    else fail "C6: staged private content not scanned — expected block: $HOOK_OUT"; fi
}

# C7: git commit with a CLEAN staged file + clean message → approve.
test_C7_staged_clean_approves() {
    require_hook "C7" || return
    local repo="$TMPDIR_BASE/c7-repo-$$"
    c_make_repo "$repo"; c_stage "$repo" "$C_CLEAN" "ok.txt"
    local cmd payload
    cmd="git -C $(c_np "$repo") commit -m 'chore: routine update'"
    payload="$(c_build_bash_payload "$cmd" "$(c_np "$repo")")"
    c_run_hook "$payload" "$C_CFG" "$repo"
    if [ "$HOOK_RC" -ne 0 ]; then fail "C7: hook crashed rc=$HOOK_RC ($HOOK_OUT)"; return; fi
    if c_is_block; then fail "C7: clean staged content wrongly blocked: $HOOK_OUT"
    else pass "C7: clean staged content → approve (staged scan not an unconditional blocker)"; fi
}

# C8: `git commit --amend` (no -m) with private staged content → block
#     (staged scan runs independent of message presence).
test_C8_amend_message_independent_blocks() {
    require_hook "C8" || return
    local repo="$TMPDIR_BASE/c8-repo-$$"
    c_make_repo "$repo"; c_stage "$repo" "$C_PRIVATE" "leak.txt"
    local cmd payload
    cmd="git -C $(c_np "$repo") commit --amend --no-edit"
    payload="$(c_build_bash_payload "$cmd" "$(c_np "$repo")")"
    c_run_hook "$payload" "$C_CFG" "$repo"
    if [ "$HOOK_RC" -ne 0 ]; then fail "C8: hook crashed rc=$HOOK_RC ($HOOK_OUT)"; return; fi
    if c_is_block; then pass "C8: --amend (no -m) private staged → block (message-independent, fail-before-fix)"
    else fail "C8: --amend staged private not scanned — expected block: $HOOK_OUT"; fi
}

# C9: commit recognized through a `cd <repo> && git commit` form (IR-based,
#     not the fragile message regex) → staged private content → block.
test_C9_cd_form_recognized_blocks() {
    require_hook "C9" || return
    local repo="$TMPDIR_BASE/c9-repo-$$"
    c_make_repo "$repo"; c_stage "$repo" "$C_PRIVATE" "leak.txt"
    local cmd payload
    cmd="cd $(c_np "$repo") && git commit -m 'wip'"
    payload="$(c_build_bash_payload "$cmd" "$(c_np "$C_NEUTRAL")")"
    c_run_hook "$payload" "$C_CFG" "$C_NEUTRAL"
    if [ "$HOOK_RC" -ne 0 ]; then fail "C9: hook crashed rc=$HOOK_RC ($HOOK_OUT)"; return; fi
    if c_is_block; then pass "C9: 'cd repo && git commit' recognized → staged scan → block (fail-before-fix)"
    else fail "C9: cd-form commit not recognized as staged-scan target: $HOOK_OUT"; fi
}

# C10: scanner rc=4 (blocklist unresolvable via AGENTS_CONFIG_DIR) maps to block,
#      even for clean content (fail-closed). Uses Edit so no new commit/inline path.
test_C10_rc4_fail_closed_blocks() {
    require_hook "C10" || return
    local payload
    payload="$(build_edit_payload "csid" "$C_NEUTRAL/x.txt" "$C_CLEAN")"
    c_run_hook "$payload" "$C_CFG_NOBL" "$C_NEUTRAL"
    if [ "$HOOK_RC" -ne 0 ]; then fail "C10: hook crashed rc=$HOOK_RC ($HOOK_OUT)"; return; fi
    if c_is_block; then pass "C10: blocklist unresolvable → scanner rc=4 → block (fail-before-fix)"
    else fail "C10: rc=4 not mapped to block (silent degrade): $HOOK_OUT"; fi
}

# C11: a deletion + a private modification staged in one commit — the deletion is
#      excluded (--diff-filter=ACM), the modified file is scanned → block (C4).
test_C11_deleted_excluded_modified_scanned() {
    require_hook "C11" || return
    local repo="$TMPDIR_BASE/c11-repo-$$"
    c_make_repo "$repo"
    printf 'old\n' > "$repo/old.txt"; printf 'keep\n' > "$repo/keep.txt"
    git -C "$repo" add old.txt keep.txt >/dev/null 2>&1
    git -C "$repo" commit -q -m base
    git -C "$repo" rm -q old.txt >/dev/null 2>&1
    printf '%s\n' "$C_PRIVATE" > "$repo/keep.txt"; git -C "$repo" add keep.txt >/dev/null 2>&1
    local cmd payload
    cmd="git -C $(c_np "$repo") commit -m 'prune + edit'"
    payload="$(c_build_bash_payload "$cmd" "$(c_np "$repo")")"
    c_run_hook "$payload" "$C_CFG" "$repo"
    if [ "$HOOK_RC" -ne 0 ]; then fail "C11: hook crashed rc=$HOOK_RC ($HOOK_OUT)"; return; fi
    if c_is_block; then pass "C11: deletion excluded (ACM), modified private scanned → block (fail-before-fix)"
    else fail "C11: staged deletion+modification not scanned correctly: $HOOK_OUT"; fi
}

# C12: staged (index) vs working-tree distinction — private IN index, clean in
#      working tree → block (staged scan reads the index, not the file on disk).
test_C12_staged_index_not_wt() {
    require_hook "C12" || return
    local repo="$TMPDIR_BASE/c12-repo-$$"
    c_make_repo "$repo"
    c_stage "$repo" "$C_PRIVATE" "secret.txt"
    # Overwrite working-tree copy with clean content WITHOUT re-staging.
    printf '%s\n' "$C_CLEAN" > "$repo/secret.txt"
    local cmd payload
    cmd="git -C $(c_np "$repo") commit -m 'should read index not wt'"
    payload="$(c_build_bash_payload "$cmd" "$(c_np "$repo")")"
    c_run_hook "$payload" "$C_CFG" "$repo"
    if [ "$HOOK_RC" -ne 0 ]; then fail "C12: hook crashed rc=$HOOK_RC ($HOOK_OUT)"; return; fi
    if c_is_block; then pass "C12: staged index has private (wt is clean) → block (reads index, fail-before-fix)"
    else fail "C12: staged scan read working tree instead of index — expected block: $HOOK_OUT"; fi
}

# C13: two staged files (one clean, one private) → block on the private one.
test_C13_two_staged_one_private() {
    require_hook "C13" || return
    local repo="$TMPDIR_BASE/c13-repo-$$"
    c_make_repo "$repo"
    c_stage "$repo" "$C_CLEAN" "safe.txt"
    c_stage "$repo" "$C_PRIVATE" "leak.txt"
    local cmd payload
    cmd="git -C $(c_np "$repo") commit -m 'two files commit'"
    payload="$(c_build_bash_payload "$cmd" "$(c_np "$repo")")"
    c_run_hook "$payload" "$C_CFG" "$repo"
    if [ "$HOOK_RC" -ne 0 ]; then fail "C13: hook crashed rc=$HOOK_RC ($HOOK_OUT)"; return; fi
    if c_is_block; then pass "C13: 2 staged files (clean+private) → block (private file detected, fail-before-fix)"
    else fail "C13: 2-file commit with private file not blocked: $HOOK_OUT"; fi
}

# C14: block decision must not echo back the private content (no secret leakage).
test_C14_no_secret_leakage_in_output() {
    require_hook "C14" || return
    local repo="$TMPDIR_BASE/c14-repo-$$"
    c_make_repo "$repo"; c_stage "$repo" "$C_PRIVATE" "leak.txt"
    local cmd payload
    cmd="git -C $(c_np "$repo") commit -m 'sensitive update'"
    payload="$(c_build_bash_payload "$cmd" "$(c_np "$repo")")"
    c_run_hook "$payload" "$C_CFG" "$repo"
    if [ "$HOOK_RC" -ne 0 ]; then fail "C14: hook crashed rc=$HOOK_RC ($HOOK_OUT)"; return; fi
    if ! c_is_block; then fail "C14: expected block on private staged content (setup issue): $HOOK_OUT"; return; fi
    if echo "$HOOK_OUT" | grep -qF "$C_PRIVATE"; then
        fail "C14: block decision echoes private content in output (secret leakage): $HOOK_OUT"
    else
        pass "C14: block decision does not echo back private content (fail-before-fix)"
    fi
}

# TL3 gap (what this test does NOT catch):
#   PreToolUse registration path — hooks/scan-outbound.js is loaded as a
#   PreToolUse hook via settings.json; the hook fires only when Claude Code
#   invokes a tool in a live interactive session. These TL2 tests drive the
#   hook directly (stdin JSON), so settings.json wiring is untested here.
#   Closest-to-action mitigation: `bin/check-verification-gate.sh` verifies
#   scan-outbound is listed in the PreToolUse array of settings.json.
#   Full end-to-end coverage requires a TL3 `claude -p` run; see
#   docs/architecture/claude-code/e2e-testing.md for the hook coverage map.

run_all() {
    test_A_no_marker_blocks_private_info
    test_B_marker_still_scans_private_info
    test_B2_marker_approves_benign_content
    test_C_traversal_sid_no_bypass
    test_C1_inline_heredoc_write_blocks
    test_C2_inline_echo_redirect_blocks
    test_C3_inline_clean_write_approves
    test_C4_non_write_not_scanned
    test_C5_runtime_side_effect_out_of_scope
    test_C6_staged_private_blocks
    test_C7_staged_clean_approves
    test_C8_amend_message_independent_blocks
    test_C9_cd_form_recognized_blocks
    test_C10_rc4_fail_closed_blocks
    test_C11_deleted_excluded_modified_scanned
    test_C12_staged_index_not_wt
    test_C13_two_staged_one_private
    test_C14_no_secret_leakage_in_output
}

if command -v timeout >/dev/null 2>&1; then
    if [ -z "${_BYPASS_SCAN_OUTBOUND_INNER:-}" ]; then
        _BYPASS_SCAN_OUTBOUND_INNER=1 timeout 600 bash "$0" "$@"
        exit $?
    fi
fi

run_all

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
