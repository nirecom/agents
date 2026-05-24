#!/bin/bash
# tests/feature-enforce-worktree-session-override.sh
#
# Integration tests for the session-scoped ENFORCE_WORKTREE escape hatch.
#
# Feature contract:
#   - workflow-mark.js (PostToolUse) intercepts:
#       echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF>>"
#       echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF: <reason>>"
#     and writes a marker file:
#       <workflowDir>/<sessionId>.worktree-off
#     The marker JSON contains "set_at" and (optionally) "reason".
#   - enforce-worktree.js (PreToolUse) checks for that marker file right
#     after isEnforceWorktreeOn(). If present AND the session ID matches,
#     writes from the main worktree are allowed for that session only.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
MARK_JS="${_AGENTS_DIR_NODE}/hooks/workflow-mark.js"
GUARD_JS="${_AGENTS_DIR_NODE}/hooks/enforce-worktree.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'eworktree-sess-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Portable timeout: prefers `timeout`, falls back to perl alarm (macOS-safe).
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

require_files() {
    if [ ! -f "$MARK_JS" ]; then
        fail "$1 (workflow-mark.js not present)"
        return 1
    fi
    if [ ! -f "$GUARD_JS" ]; then
        fail "$1 (enforce-worktree.js not present)"
        return 1
    fi
    return 0
}

# Allocate a fresh per-test workflow dir (so markers don't leak across tests).
fresh_workflow_dir() {
    local d="$TMPDIR_BASE/wf-$RANDOM-$$"
    mkdir -p "$d"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$d"
    else
        echo "$d"
    fi
}

# Construct a throwaway main worktree (no linked worktree). Used by guard tests
# so that `isMainCheckout()` returns true and the main-worktree block fires
# unless the marker bypass allows.
setup_main_checkout() {
    local name="$1"
    local repo="$TMPDIR_BASE/$name"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config core.hooksPath /dev/null
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q -m "initial"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$repo"
    else
        echo "$repo"
    fi
}

# Write an env-file for CLAUDE_ENV_FILE-based session resolution.
# Usage: setup_fake_env_file <session-id>  → echoes the path of the env file.
setup_fake_env_file() {
    local sid="$1"
    local f="$TMPDIR_BASE/envfile-$RANDOM-$$"
    printf 'CLAUDE_SESSION_ID=%s\n' "$sid" > "$f"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$f"
    else
        echo "$f"
    fi
}

MARK_OUT=""
# run_workflow_mark <stdin-json> <workflow-dir> [extra env var ...]
# Returns workflow-mark.js exit code; captures stdout+stderr into MARK_OUT.
run_workflow_mark() {
    local payload="$1"; shift
    local wfdir="$1"; shift
    local rc=0
    MARK_OUT="$(printf '%s' "$payload" | run_with_timeout 30 \
        env -u CLAUDE_ENV_FILE \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        "$@" \
        node "$MARK_JS" 2>&1)" || rc=$?
    return $rc
}

GUARD_OUT=""
GUARD_RC=0
# run_enforce_worktree <stdin-json> <workflow-dir> <repo-in-scope> [extra env var ...]
# Captures stdout+stderr into GUARD_OUT and exit code into GUARD_RC.
# Returns 0 if allowed, 1 if blocked, 2 if the hook crashed (non-zero exit).
#
# The hook always exits 0 in normal operation (both allow and block paths call
# done() which exits 0 — block emits {"decision":"block"} JSON). A non-zero
# exit code therefore signals a crash/timeout/startup failure, not a deny.
# Tests must distinguish "intentionally allowed" from "crashed but no block
# string in output" — codex review HIGH#2.
#
# <repo-in-scope> is the temp repo to register via ENFORCE_WORKTREE_EXTRA_REPOS
# so the guard's session-scope check sees the temp repo and falls through to
# the main-checkout block (otherwise the temp repo is "out of session scope"
# and the guard short-circuits to allow).
run_enforce_worktree() {
    local payload="$1"; shift
    local wfdir="$1"; shift
    local repo_scope="$1"; shift
    GUARD_RC=0
    GUARD_OUT="$(printf '%s' "$payload" | run_with_timeout 30 \
        env -u CLAUDE_ENV_FILE \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "ENFORCE_WORKTREE=on" \
        "ENFORCE_WORKTREE_EXTRA_REPOS=$repo_scope" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        "$@" \
        node "$GUARD_JS" 2>&1)" || GUARD_RC=$?
    if [ "$GUARD_RC" -ne 0 ]; then
        return 2
    fi
    if echo "$GUARD_OUT" | grep -q '"decision":"block"'; then
        return 1
    fi
    return 0
}

# JSON-safely pack a string as a JSON-encoded literal (via node).
json_quote() {
    node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$1"
}

# Build a PostToolUse Bash payload for workflow-mark.js.
# Args: session-id command-string exit-code
build_mark_payload() {
    local sid="$1" cmd="$2" rc="$3"
    local q_sid q_cmd
    q_sid="$(json_quote "$sid")"
    q_cmd="$(json_quote "$cmd")"
    printf '{"session_id":%s,"tool_name":"Bash","tool_input":{"command":%s},"tool_response":{"exit_code":%s,"stdout":"","stderr":""}}' \
        "$q_sid" "$q_cmd" "$rc"
}

# Same but with session_id omitted entirely (env-file fallback test).
build_mark_payload_no_sid() {
    local cmd="$1" rc="$2"
    local q_cmd
    q_cmd="$(json_quote "$cmd")"
    printf '{"tool_name":"Bash","tool_input":{"command":%s},"tool_response":{"exit_code":%s,"stdout":"","stderr":""}}' \
        "$q_cmd" "$rc"
}

# Build payload with transcript_path but no session_id (transcript fallback test).
# Args: command-string exit-code transcript-path
build_mark_payload_with_transcript() {
    local cmd="$1" rc="$2" tp="$3"
    local q_cmd q_tp
    q_cmd="$(json_quote "$cmd")"
    q_tp="$(json_quote "$tp")"
    printf '{"tool_name":"Bash","tool_input":{"command":%s},"tool_response":{"exit_code":%s,"stdout":"","stderr":""},"transcript_path":%s}' \
        "$q_cmd" "$rc" "$q_tp"
}

# Build a PreToolUse payload for enforce-worktree.js.
# Args: session-id tool-name file-path
build_guard_payload_write() {
    local sid="$1" tname="$2" fp="$3"
    local q_sid q_fp
    q_sid="$(json_quote "$sid")"
    q_fp="$(json_quote "$fp")"
    printf '{"session_id":%s,"tool_name":"%s","tool_input":{"file_path":%s,"content":"hi"}}' \
        "$q_sid" "$tname" "$q_fp"
}

# Build a guard payload with session_id absent entirely.
build_guard_payload_write_no_sid() {
    local tname="$1" fp="$2"
    local q_fp
    q_fp="$(json_quote "$fp")"
    printf '{"tool_name":"%s","tool_input":{"file_path":%s,"content":"hi"}}' \
        "$tname" "$q_fp"
}

# Write a marker file directly (simulating a previous workflow-mark.js run).
# Args: workflow-dir session-id [reason]
write_marker_file() {
    local wfdir="$1" sid="$2" reason="${3:-}"
    if [ -n "$reason" ]; then
        printf '{"set_at":"2026-01-01T00:00:00Z","reason":"%s"}\n' "$reason" \
            > "$wfdir/$sid.worktree-off"
    else
        printf '{"set_at":"2026-01-01T00:00:00Z"}\n' \
            > "$wfdir/$sid.worktree-off"
    fi
}

# ============================================================================
# A. Sentinel ingestion (workflow-mark.js)
# ============================================================================

test_A1_marker_created_on_sentinel() {
    require_files "A1" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="abc123"
    local payload; payload="$(build_mark_payload "$sid" 'echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF: A1 marker test>>"' 0)"
    run_workflow_mark "$payload" "$wfdir"
    if [ -f "$wfdir/$sid.worktree-off" ]; then
        pass "A1: marker file created for valid sentinel"
    else
        fail "A1: marker NOT created (out: $MARK_OUT)"
    fi
}

test_A2_marker_with_reason() {
    require_files "A2" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="abc123"
    local payload; payload="$(build_mark_payload "$sid" 'echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF: maintenance recovery>>"' 0)"
    run_workflow_mark "$payload" "$wfdir"
    local mfile="$wfdir/$sid.worktree-off"
    if [ ! -f "$mfile" ]; then
        fail "A2: marker NOT created for sentinel with reason (out: $MARK_OUT)"
        return
    fi
    local content; content="$(cat "$mfile")"
    if echo "$content" | grep -q '"reason"' \
       && echo "$content" | grep -q 'maintenance recovery' \
       && echo "$content" | grep -q '"set_at"'; then
        pass "A2: marker JSON contains reason + set_at"
    else
        fail "A2: marker JSON missing reason/set_at fields (content: $content)"
    fi
}

test_A3_non_zero_exit_skips() {
    require_files "A3" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="abc123"
    local payload; payload="$(build_mark_payload "$sid" 'echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF: A3 non-zero exit>>"' 1)"
    local rc=0
    run_workflow_mark "$payload" "$wfdir" || rc=$?
    if [ -f "$wfdir/$sid.worktree-off" ]; then
        fail "A3: marker should NOT exist when echo exit_code=1 (out: $MARK_OUT)"
        return
    fi
    if [ "$rc" -ne 0 ]; then
        fail "A3: workflow-mark.js crashed with rc=$rc on non-zero exit (out: $MARK_OUT)"
        return
    fi
    pass "A3: non-zero exit_code → no marker, hook exits 0"
}

test_A4_env_file_fallback() {
    require_files "A4" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="xyz"
    local envfile; envfile="$(setup_fake_env_file "$sid")"
    local payload; payload="$(build_mark_payload_no_sid 'echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF: A4 env-file fallback>>"' 0)"
    # Note: run_workflow_mark unsets CLAUDE_ENV_FILE; pass it explicitly here.
    MARK_OUT="$(printf '%s' "$payload" | run_with_timeout 30 \
        env -u CLAUDE_ENV_FILE \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        "CLAUDE_ENV_FILE=$envfile" \
        node "$MARK_JS" 2>&1)" || true
    if [ -f "$wfdir/$sid.worktree-off" ]; then
        pass "A4: env-file fallback resolves session ID"
    else
        fail "A4: env-file fallback did not create marker (out: $MARK_OUT)"
    fi
}

test_A5_no_session_id_hard_blocks() {
    require_files "A5" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local payload; payload="$(build_mark_payload_no_sid 'echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF: A5 no session id>>"' 0)"
    local rc=0
    # No CLAUDE_ENV_FILE → no session ID resolvable. Must hard-block (rc=2).
    MARK_OUT="$(printf '%s' "$payload" | run_with_timeout 30 \
        env -u CLAUDE_ENV_FILE \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        node "$MARK_JS" 2>&1)" || rc=$?
    # No marker should be written.
    local count
    count="$(ls -1 "$wfdir" 2>/dev/null | grep -c '\.worktree-off$' || true)"
    if [ "$count" -ne 0 ]; then
        fail "A5: marker created without session_id (count=$count, out: $MARK_OUT)"
        return
    fi
    if [ "$rc" -ne 2 ]; then
        fail "A5: expected hard-block rc=2 but got rc=$rc (out: $MARK_OUT)"
        return
    fi
    if ! echo "$MARK_OUT" | grep -qiE "session(_id)?|resolve"; then
        fail "A5: stderr missing 'session'/'resolve' diagnostic (out: $MARK_OUT)"
        return
    fi
    pass "A5: missing session_id → hard-block rc=2, no marker, diagnostic surfaced"
}

test_A7_idempotent_marker_write() {
    require_files "A7" || return
    # Running the sentinel twice should produce a stable marker file — no crash,
    # no leftover .tmp file, and the second write overwrites cleanly (atomic
    # tmp+rename pattern). Validates the writeState()-mirroring design choice.
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="abc123"
    local payload; payload="$(build_mark_payload "$sid" 'echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF: A7 idempotent write>>"' 0)"
    run_workflow_mark "$payload" "$wfdir"
    run_workflow_mark "$payload" "$wfdir"
    local marker="$wfdir/$sid.worktree-off"
    # No stale .tmp files.
    local tmp_count; tmp_count="$(find "$wfdir" -name '*.worktree-off.tmp' 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$tmp_count" -ne 0 ]; then
        fail "A7: stale .tmp file left after double-write (out: $MARK_OUT)"
        return
    fi
    if [ -f "$marker" ]; then
        pass "A7: idempotent double-write — marker present, no .tmp residue"
    else
        fail "A7: marker NOT created after double sentinel invocation (out: $MARK_OUT)"
    fi
}

test_A6_chained_sentinels_accepted() {
    require_files "A6" || return
    # workflow-mark.js splits on `&&` and requires every part to be a recognised
    # sentinel. Because WORKFLOW_ENFORCE_WORKTREE_OFF is now part of isSentinel(),
    # chaining it with another valid sentinel (USER_VERIFIED) must succeed: the
    # marker is created alongside the chained sentinel's effects.
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="abc123"
    local cmd='echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF: A6 chain test>>" && echo "<<WORKFLOW_USER_VERIFIED: A6 chain test>>"'
    local payload; payload="$(build_mark_payload "$sid" "$cmd" 0)"
    run_workflow_mark "$payload" "$wfdir"
    if [ -f "$wfdir/$sid.worktree-off" ]; then
        pass "A6: chained sentinels processed — marker created alongside USER_VERIFIED"
    else
        fail "A6: chained sentinel rejected — marker NOT created (out: $MARK_OUT)"
    fi
}

# ----------------------------------------------------------------------------
# A8-A11: WORKFLOW_ENFORCE_WORKTREE_ON sentinel — restores enforcement by
# deleting the per-session marker. Mirrors the OFF handler symmetrically so
# Claude Code can flip enforcement back ON without resolving its own session ID.
# ----------------------------------------------------------------------------

test_A8_on_sentinel_deletes_marker() {
    require_files "A8" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="abc123"
    # Pre-existing marker (e.g. set earlier in the session via OFF sentinel).
    write_marker_file "$wfdir" "$sid"
    [ -f "$wfdir/$sid.worktree-off" ] || { fail "A8 setup: marker not written"; return; }
    local payload; payload="$(build_mark_payload "$sid" 'echo "<<WORKFLOW_ENFORCE_WORKTREE_ON: A8 delete marker>>"' 0)"
    run_workflow_mark "$payload" "$wfdir"
    if [ ! -f "$wfdir/$sid.worktree-off" ]; then
        pass "A8: ON sentinel deleted the existing marker"
    else
        fail "A8: marker still present after ON sentinel (out: $MARK_OUT)"
    fi
}

test_A9_on_sentinel_no_marker_idempotent() {
    require_files "A9" || return
    # ON sentinel with no existing marker must be a silent no-op (idempotent).
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="abc123"
    local payload; payload="$(build_mark_payload "$sid" 'echo "<<WORKFLOW_ENFORCE_WORKTREE_ON: A9 idempotent on>>"' 0)"
    local rc=0
    run_workflow_mark "$payload" "$wfdir" || rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "A9: ON sentinel with no marker crashed rc=$rc (out: $MARK_OUT)"
        return
    fi
    if [ -f "$wfdir/$sid.worktree-off" ]; then
        fail "A9: ON sentinel created a marker (should be no-op, out: $MARK_OUT)"
        return
    fi
    pass "A9: ON sentinel with no existing marker — silent no-op"
}

test_A10_on_sentinel_no_session_id() {
    require_files "A10" || return
    # No session_id, no CLAUDE_ENV_FILE → must hard-block (rc=2), preserve any
    # pre-existing unrelated marker (cross-session isolation), and emit a
    # diagnostic mentioning session resolution failure.
    local wfdir; wfdir="$(fresh_workflow_dir)"
    write_marker_file "$wfdir" "someone-else"
    local payload
    payload='{"tool_name":"Bash","tool_input":{"command":"echo \"<<WORKFLOW_ENFORCE_WORKTREE_ON: A10 no session id>>\""}, "tool_response":{"exit_code":0}}'
    local rc=0
    run_workflow_mark "$payload" "$wfdir" || rc=$?
    if [ "$rc" -ne 2 ]; then
        fail "A10: expected hard-block rc=2 but got rc=$rc (out: $MARK_OUT)"
        return
    fi
    # Other-session marker MUST still exist (no cross-session deletion).
    if [ ! -f "$wfdir/someone-else.worktree-off" ]; then
        fail "A10: ON sentinel without session_id deleted unrelated marker (out: $MARK_OUT)"
        return
    fi
    if ! echo "$MARK_OUT" | grep -qiE "session(_id)?|resolve"; then
        fail "A10: stderr missing 'session'/'resolve' diagnostic (out: $MARK_OUT)"
        return
    fi
    pass "A10: no session_id → ON sentinel hard-blocks rc=2, cross-session isolation preserved"
}

test_A11_on_sentinel_session_isolation() {
    require_files "A11" || return
    # ON sentinel must only delete the calling session's marker, not others'.
    local wfdir; wfdir="$(fresh_workflow_dir)"
    write_marker_file "$wfdir" "session-A"
    write_marker_file "$wfdir" "session-B"
    local payload; payload="$(build_mark_payload "session-A" 'echo "<<WORKFLOW_ENFORCE_WORKTREE_ON: A11 isolation>>"' 0)"
    run_workflow_mark "$payload" "$wfdir"
    if [ -f "$wfdir/session-A.worktree-off" ]; then
        fail "A11: session-A marker NOT deleted (out: $MARK_OUT)"
        return
    fi
    if [ ! -f "$wfdir/session-B.worktree-off" ]; then
        fail "A11: session-B marker incorrectly deleted (cross-session leak, out: $MARK_OUT)"
        return
    fi
    pass "A11: ON sentinel deletes only the calling session's marker"
}

# ----------------------------------------------------------------------------
# A12-A13: Bare-form rejection (#404 contract change).
# Bare WORKFLOW_ENFORCE_WORKTREE_OFF / _ON must be rejected as malformed by the
# LOOKSLIKE handler — no marker mutation, error surfaced.
# ----------------------------------------------------------------------------

test_A12_bare_off_malformed() {
    require_files "A12" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="abc123"
    local payload; payload="$(build_mark_payload "$sid" 'echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF>>"' 0)"
    run_workflow_mark "$payload" "$wfdir"
    if [ -f "$wfdir/$sid.worktree-off" ]; then
        fail "A12: bare OFF was accepted — marker created (expected rejection) (out: $MARK_OUT)"
        return
    fi
    if ! echo "$MARK_OUT" | grep -qi "malformed"; then
        fail "A12: bare OFF — expected 'malformed' in output (out: $MARK_OUT)"
        return
    fi
    pass "A12: bare ENFORCE_WORKTREE_OFF rejected as malformed — no marker"
}

test_A13_bare_on_malformed() {
    require_files "A13" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="abc123"
    # Pre-existing marker — bare ON must NOT delete it.
    write_marker_file "$wfdir" "$sid"
    [ -f "$wfdir/$sid.worktree-off" ] || { fail "A13 setup: marker not written"; return; }
    local payload; payload="$(build_mark_payload "$sid" 'echo "<<WORKFLOW_ENFORCE_WORKTREE_ON>>"' 0)"
    run_workflow_mark "$payload" "$wfdir"
    if [ ! -f "$wfdir/$sid.worktree-off" ]; then
        fail "A13: bare ON was accepted — marker deleted (expected preservation) (out: $MARK_OUT)"
        return
    fi
    if ! echo "$MARK_OUT" | grep -qi "malformed"; then
        fail "A13: bare ON — expected 'malformed' in output (out: $MARK_OUT)"
        return
    fi
    pass "A13: bare ENFORCE_WORKTREE_ON rejected as malformed — marker preserved"
}

# ----------------------------------------------------------------------------
# A14-A15: transcript_path fallback (#461)
# When session_id is absent from input AND CLAUDE_ENV_FILE is unset,
# workflow-mark.js must fall back to deriving the session ID from
# transcript_path (basename without .jsonl). Path must be validated.
# ----------------------------------------------------------------------------

test_A14_transcript_path_fallback() {
    require_files "A14" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    # Fixed UUID-like filename so the expected marker name is predictable.
    # The file does NOT need to exist — only the path basename matters.
    local sid="a1b2c3d4-e5f6-7890-abcd-ef1234567890"
    local tp="$TMPDIR_BASE/projects/foo/${sid}.jsonl"
    local payload; payload="$(build_mark_payload_with_transcript 'echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF: A14 transcript fallback>>"' 0 "$tp")"
    local rc=0
    MARK_OUT="$(printf '%s' "$payload" | run_with_timeout 30 \
        env -u CLAUDE_ENV_FILE \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        node "$MARK_JS" 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "A14: hook crashed with rc=$rc on transcript fallback (out: $MARK_OUT)"
        return
    fi
    if [ ! -f "$wfdir/$sid.worktree-off" ]; then
        fail "A14: transcript fallback did not create marker for sid='$sid' (out: $MARK_OUT)"
        return
    fi
    pass "A14: transcript_path fallback → session ID derived → marker created"
}

test_A15_transcript_path_invalid_chars() {
    require_files "A15" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    # transcript_path basename contains an invalid char (@) — must be rejected, no marker, hard-block.
    local tp="$TMPDIR_BASE/abc@def.jsonl"
    local payload; payload="$(build_mark_payload_with_transcript 'echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF: A15 invalid chars>>"' 0 "$tp")"
    local rc=0
    MARK_OUT="$(printf '%s' "$payload" | run_with_timeout 30 \
        env -u CLAUDE_ENV_FILE \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        node "$MARK_JS" 2>&1)" || rc=$?
    if [ "$rc" -ne 2 ]; then
        fail "A15: expected hard-block rc=2 but got rc=$rc (out: $MARK_OUT)"
        return
    fi
    local count
    count="$(ls -1 "$wfdir" 2>/dev/null | grep -c '\.worktree-off$' || true)"
    if [ "$count" -ne 0 ]; then
        fail "A15: marker created from invalid transcript_path (count=$count, out: $MARK_OUT)"
        return
    fi
    pass "A15: transcript_path with invalid basename chars rejected — hard-block, no marker"
}

# ============================================================================
# B. enforce-worktree.js consumption
# ============================================================================

# assert_guard_allow <label> — pass if rc=0 (allow); fail on rc=1 (block) or rc=2 (crash).
assert_guard_allow() {
    local label="$1" rc="$2"
    case "$rc" in
        0) pass "$label" ;;
        1) fail "$label: guard blocked despite expected allow (out: $GUARD_OUT)" ;;
        2) fail "$label: guard hook crashed rc=$GUARD_RC (out: $GUARD_OUT)" ;;
        *) fail "$label: unexpected rc=$rc (out: $GUARD_OUT)" ;;
    esac
}

# assert_guard_block <label> — pass only on rc=1 (block); fail on allow OR crash.
assert_guard_block() {
    local label="$1" rc="$2"
    case "$rc" in
        0) fail "$label: guard allowed despite expected block (out: $GUARD_OUT)" ;;
        1) pass "$label" ;;
        2) fail "$label: guard hook crashed rc=$GUARD_RC (out: $GUARD_OUT)" ;;
        *) fail "$label: unexpected rc=$rc (out: $GUARD_OUT)" ;;
    esac
}

test_B1_marker_allows_write() {
    require_files "B1" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="abc123"
    local repo; repo="$(setup_main_checkout "b1-main")"
    write_marker_file "$wfdir" "$sid"
    local payload; payload="$(build_guard_payload_write "$sid" "Write" "$repo/foo.txt")"
    local rc=0; run_enforce_worktree "$payload" "$wfdir" "$repo" || rc=$?
    assert_guard_allow "B1: Write allowed with matching session marker" "$rc"
}

test_B1b_marker_allows_edit() {
    require_files "B1b" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="abc123"
    local repo; repo="$(setup_main_checkout "b1b-main")"
    write_marker_file "$wfdir" "$sid"
    local payload; payload="$(build_guard_payload_write "$sid" "Edit" "$repo/foo.txt")"
    # Edit tool requires the file to exist for the hook's findRepoRoot to walk;
    # create it so we exercise the post-marker branch realistically.
    printf 'hello\n' > "$repo/foo.txt"
    local rc=0; run_enforce_worktree "$payload" "$wfdir" "$repo" || rc=$?
    assert_guard_allow "B1b: Edit allowed with matching session marker" "$rc"
}

test_B2_no_marker_blocks() {
    require_files "B2" || return
    # No marker → baseline regression: main-worktree write must block.
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="abc123"
    local repo; repo="$(setup_main_checkout "b2-main")"
    local payload; payload="$(build_guard_payload_write "$sid" "Write" "$repo/foo.txt")"
    local rc=0; run_enforce_worktree "$payload" "$wfdir" "$repo" || rc=$?
    assert_guard_block "B2: no marker → Write blocked (baseline)" "$rc"
}

test_B3_session_isolation() {
    require_files "B3" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local repo; repo="$(setup_main_checkout "b3-main")"
    # Marker exists for a DIFFERENT session.
    write_marker_file "$wfdir" "other-session"
    local payload; payload="$(build_guard_payload_write "abc123" "Write" "$repo/foo.txt")"
    local rc=0; run_enforce_worktree "$payload" "$wfdir" "$repo" || rc=$?
    assert_guard_block "B3: session isolation — other session's marker does NOT grant bypass" "$rc"
}

test_B4_no_session_id_blocks() {
    require_files "B4" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local repo; repo="$(setup_main_checkout "b4-main")"
    # No marker, no session_id, no CLAUDE_ENV_FILE → fail-closed.
    local payload; payload="$(build_guard_payload_write_no_sid "Write" "$repo/foo.txt")"
    local rc=0; run_enforce_worktree "$payload" "$wfdir" "$repo" || rc=$?
    assert_guard_block "B4: no session_id + no marker → blocked (fail-closed)" "$rc"
}

test_B5_input_session_id_wins_over_env_file() {
    require_files "B5" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local repo; repo="$(setup_main_checkout "b5-main")"
    local envfile; envfile="$(setup_fake_env_file "different-session")"
    # Marker for input.session_id only — NOT for the env-file session.
    write_marker_file "$wfdir" "abc123"
    local payload; payload="$(build_guard_payload_write "abc123" "Write" "$repo/foo.txt")"
    GUARD_OUT="$(printf '%s' "$payload" | run_with_timeout 30 \
        env -u CLAUDE_ENV_FILE \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "ENFORCE_WORKTREE=on" \
        "ENFORCE_WORKTREE_EXTRA_REPOS=$repo" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        "CLAUDE_ENV_FILE=$envfile" \
        node "$GUARD_JS" 2>&1)" || true
    if echo "$GUARD_OUT" | grep -q '"decision":"block"'; then
        fail "B5: input.session_id should take precedence over env-file (out: $GUARD_OUT)"
    else
        pass "B5: input.session_id wins over CLAUDE_ENV_FILE"
    fi
}

# ============================================================================
# C. Round-trip
# ============================================================================

test_C1_round_trip_creates_and_allows() {
    require_files "C1" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="abc123"
    local repo; repo="$(setup_main_checkout "c1-main")"
    local mark_payload; mark_payload="$(build_mark_payload "$sid" 'echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF: C1 round trip>>"' 0)"
    run_workflow_mark "$mark_payload" "$wfdir"
    if [ ! -f "$wfdir/$sid.worktree-off" ]; then
        fail "C1: marker NOT created in round trip (out: $MARK_OUT)"
        return
    fi
    local guard_payload; guard_payload="$(build_guard_payload_write "$sid" "Write" "$repo/foo.txt")"
    local rc=0; run_enforce_worktree "$guard_payload" "$wfdir" "$repo" || rc=$?
    assert_guard_allow "C1: round trip — sentinel → marker → enforce-worktree allows" "$rc"
}

test_C2_marker_deletion_restores_block() {
    require_files "C2" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="abc123"
    local repo; repo="$(setup_main_checkout "c2-main")"
    write_marker_file "$wfdir" "$sid"
    rm -f "$wfdir/$sid.worktree-off"
    local guard_payload; guard_payload="$(build_guard_payload_write "$sid" "Write" "$repo/foo.txt")"
    local rc=0; run_enforce_worktree "$guard_payload" "$wfdir" "$repo" || rc=$?
    assert_guard_block "C2: marker rm → guard blocks again" "$rc"
}

test_C3_off_on_round_trip_via_sentinels() {
    require_files "C3" || return
    # Full lifecycle via sentinels alone (no manual marker manipulation):
    # OFF sentinel → guard allows → ON sentinel → guard blocks again.
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="abc123"
    local repo; repo="$(setup_main_checkout "c3-main")"

    # Step 1: OFF sentinel creates marker.
    local off_payload; off_payload="$(build_mark_payload "$sid" 'echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF: C3 step1>>"' 0)"
    run_workflow_mark "$off_payload" "$wfdir"
    if [ ! -f "$wfdir/$sid.worktree-off" ]; then
        fail "C3 step1: OFF sentinel did not create marker (out: $MARK_OUT)"
        return
    fi

    # Step 2: guard allows the write.
    local gpay; gpay="$(build_guard_payload_write "$sid" "Write" "$repo/foo.txt")"
    local rc1=0; run_enforce_worktree "$gpay" "$wfdir" "$repo" || rc1=$?
    if [ "$rc1" -ne 0 ]; then
        fail "C3 step2: guard did not allow under marker (rc=$rc1, out: $GUARD_OUT)"
        return
    fi

    # Step 3: ON sentinel deletes the marker.
    local on_payload; on_payload="$(build_mark_payload "$sid" 'echo "<<WORKFLOW_ENFORCE_WORKTREE_ON: C3 step3>>"' 0)"
    run_workflow_mark "$on_payload" "$wfdir"
    if [ -f "$wfdir/$sid.worktree-off" ]; then
        fail "C3 step3: ON sentinel did not delete marker (out: $MARK_OUT)"
        return
    fi

    # Step 4: guard blocks again.
    local rc2=0; run_enforce_worktree "$gpay" "$wfdir" "$repo" || rc2=$?
    assert_guard_block "C3: OFF → ON round trip restores enforcement" "$rc2"
}

# ============================================================================
# SEC. Path traversal / metachar protection
# ============================================================================

# Helper: count *.worktree-off files anywhere under a directory (incl. parent
# escapes). We look for any leftover marker that would prove the guard failed
# to reject a malicious session ID.
count_worktree_off_files() {
    local root="$1"
    # Search ABOVE root too — `../evil.worktree-off` would land in the parent dir.
    local parent; parent="$(dirname "$root")"
    find "$parent" -maxdepth 3 -name '*.worktree-off' 2>/dev/null | wc -l | tr -d ' '
}

test_SEC1_path_traversal_rejected() {
    require_files "SEC1" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local before_count after_count
    before_count="$(count_worktree_off_files "$wfdir")"
    local payload; payload="$(build_mark_payload "../evil" 'echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF: SEC1 traversal>>"' 0)"
    local rc=0
    run_workflow_mark "$payload" "$wfdir" || rc=$?
    after_count="$(count_worktree_off_files "$wfdir")"
    # Hard-block (exit 2) is required for invalid session IDs (#461).
    if [ "$rc" -ne 2 ]; then
        fail "SEC1: expected hard-block rc=2 for traversal session ID, got rc=$rc (out: $MARK_OUT)"
        return
    fi
    if [ "$after_count" != "$before_count" ]; then
        fail "SEC1: traversal session ID produced a marker file (count $before_count -> $after_count, out: $MARK_OUT)"
        return
    fi
    pass "SEC1: ../evil session ID hard-blocked (rc=2) — no marker"
}

test_SEC2_shell_metachars_rejected() {
    require_files "SEC2" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    # Several attempts; each must NOT produce a marker, and the hook must not crash.
    local payloads_sid=( '$(rm)' 'a/b' 'a\\b' 'a b' )
    local sid before_count after_count rc
    local any_failure=0
    for sid in "${payloads_sid[@]}"; do
        before_count="$(count_worktree_off_files "$wfdir")"
        local payload; payload="$(build_mark_payload "$sid" 'echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF: SEC2 metachars>>"' 0)"
        rc=0
        run_workflow_mark "$payload" "$wfdir" || rc=$?
        after_count="$(count_worktree_off_files "$wfdir")"
        # Hard-block (exit 2) is required for invalid session IDs (#461).
        if [ "$rc" -ne 2 ]; then
            fail "SEC2: expected hard-block rc=2 for session ID '$sid', got rc=$rc (out: $MARK_OUT)"
            any_failure=1
            continue
        fi
        if [ "$after_count" != "$before_count" ]; then
            fail "SEC2: marker created for malicious session ID '$sid' (count $before_count -> $after_count)"
            any_failure=1
        fi
    done
    if [ "$any_failure" = "0" ]; then
        pass "SEC2: all shell-metachar session IDs rejected — no markers, no crashes"
    fi
}

test_SEC3_env_file_traversal_blocked() {
    require_files "SEC3" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local repo; repo="$(setup_main_checkout "sec3-main")"
    # CLAUDE_ENV_FILE supplies a malicious session ID. Use a one-level traversal
    # (../passwd) so the resolved plant path lands INSIDE $TMPDIR_BASE (matches
    # the SEC4 pattern). A two-level traversal would resolve outside the test
    # sandbox and risk clobbering an unrelated file in /tmp (codex review HIGH#1).
    local envfile; envfile="$(setup_fake_env_file "../passwd")"
    # Plant a marker at the traversal path so we can detect a faulty bypass.
    local parent; parent="$(dirname "$wfdir")"   # = $TMPDIR_BASE, inside sandbox
    printf '{"set_at":"x"}' > "$parent/passwd.worktree-off"
    local payload; payload="$(build_guard_payload_write_no_sid "Write" "$repo/foo.txt")"
    local rc=0
    local out
    out="$(printf '%s' "$payload" | run_with_timeout 30 \
        env -u CLAUDE_ENV_FILE \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "ENFORCE_WORKTREE=on" \
        "ENFORCE_WORKTREE_EXTRA_REPOS=$repo" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        "CLAUDE_ENV_FILE=$envfile" \
        node "$GUARD_JS" 2>&1)" || rc=$?
    rm -f "$parent/passwd.worktree-off" 2>/dev/null || true
    if [ "$rc" -ne 0 ]; then
        fail "SEC3: guard hook crashed rc=$rc (out: $out)"
    elif echo "$out" | grep -q '"decision":"block"'; then
        pass "SEC3: env-file traversal session ID does NOT grant bypass — blocked"
    else
        fail "SEC3: bypass granted via traversal CLAUDE_SESSION_ID (out: $out)"
    fi
}

test_SEC4_guard_input_traversal_blocked() {
    require_files "SEC4" || return
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local repo; repo="$(setup_main_checkout "sec4-main")"
    # Plant `<wfdir>/../evil.worktree-off`. If the guard naively used
    # `path.join(wfdir, sid + ".worktree-off")` AND fs.existsSync on the
    # resolved path, the marker would be found.
    local parent; parent="$(dirname "$wfdir")"
    printf '{"set_at":"x"}' > "$parent/evil.worktree-off"
    local payload; payload="$(build_guard_payload_write "../evil" "Write" "$repo/foo.txt")"
    local rc=0
    run_enforce_worktree "$payload" "$wfdir" "$repo" || rc=$?
    rm -f "$parent/evil.worktree-off" 2>/dev/null || true
    assert_guard_block "SEC4: ../evil session_id rejected before existsSync — bypass NOT granted" "$rc"
}

test_SEC5_on_sentinel_traversal_blocked() {
    require_files "SEC5" || return
    # ON sentinel with a traversal session ID must NOT delete the planted marker
    # outside <wfdir>. Mirrors SEC1 but for the ON path (unlink instead of write).
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local parent; parent="$(dirname "$wfdir")"   # = $TMPDIR_BASE, inside sandbox
    # Plant a "victim" marker outside wfdir.
    printf '{"set_at":"x"}' > "$parent/victim.worktree-off"
    local payload; payload="$(build_mark_payload "../victim" 'echo "<<WORKFLOW_ENFORCE_WORKTREE_ON: SEC5 traversal>>"' 0)"
    local rc=0
    run_workflow_mark "$payload" "$wfdir" || rc=$?
    local still_there=0
    [ -f "$parent/victim.worktree-off" ] && still_there=1
    rm -f "$parent/victim.worktree-off" 2>/dev/null || true
    # Hard-block (exit 2) is required for invalid session IDs (#461).
    if [ "$rc" -ne 2 ]; then
        fail "SEC5: expected hard-block rc=2 for traversal session ID, got rc=$rc (out: $MARK_OUT)"
        return
    fi
    if [ "$still_there" -eq 0 ]; then
        fail "SEC5: ON sentinel with traversal session ID deleted planted marker (out: $MARK_OUT)"
        return
    fi
    pass "SEC5: ON sentinel with ../victim session ID — hard-blocked (rc=2), planted marker preserved"
}

# ============================================================================
# Run all (wrap in 120s wall-clock timeout if available)
# ============================================================================

run_all() {
    # A: sentinel ingestion
    test_A1_marker_created_on_sentinel
    test_A2_marker_with_reason
    test_A3_non_zero_exit_skips
    test_A4_env_file_fallback
    test_A5_no_session_id_hard_blocks
    test_A6_chained_sentinels_accepted
    test_A7_idempotent_marker_write
    # A8-A11: WORKFLOW_ENFORCE_WORKTREE_ON sentinel
    test_A8_on_sentinel_deletes_marker
    test_A9_on_sentinel_no_marker_idempotent
    test_A10_on_sentinel_no_session_id
    test_A11_on_sentinel_session_isolation
    # A12-A13: bare-form rejection (#404)
    test_A12_bare_off_malformed
    test_A13_bare_on_malformed
    # A14-A15: transcript_path fallback (#461)
    test_A14_transcript_path_fallback
    test_A15_transcript_path_invalid_chars
    # B: enforce-worktree consumption
    test_B1_marker_allows_write
    test_B1b_marker_allows_edit
    test_B2_no_marker_blocks
    test_B3_session_isolation
    test_B4_no_session_id_blocks
    test_B5_input_session_id_wins_over_env_file
    # C: round trip
    test_C1_round_trip_creates_and_allows
    test_C2_marker_deletion_restores_block
    test_C3_off_on_round_trip_via_sentinels
    # SEC
    test_SEC1_path_traversal_rejected
    test_SEC2_shell_metachars_rejected
    test_SEC3_env_file_traversal_blocked
    test_SEC4_guard_input_traversal_blocked
    test_SEC5_on_sentinel_traversal_blocked
}

if command -v timeout >/dev/null 2>&1; then
    if [ -z "${_SESSION_OVERRIDE_TEST_INNER:-}" ]; then
        _SESSION_OVERRIDE_TEST_INNER=1 timeout 120 bash "$0" "$@"
        exit $?
    fi
fi

run_all

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
