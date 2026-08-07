# helpers.sh - env/payload builders and hook drivers for the workflow-off
# session-override suite. Sourced by tests/feature-workflow-off-session-override.sh.
# Expects AGENTS_DIR, _AGENTS_DIR_NODE, TMPDIR_BASE, and the pass/fail counters.

MARK_JS="${_AGENTS_DIR_NODE}/hooks/workflow-mark.js"
SESSION_MARKERS_JS="${_AGENTS_DIR_NODE}/hooks/lib/session-markers.js"

# Portable timeout: prefers `timeout`, falls back to perl alarm (macOS-safe).
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

require_mark_js() {
    if [ ! -f "$MARK_JS" ]; then
        fail "$1 (workflow-mark.js not present)"
        return 1
    fi
    return 0
}

require_session_markers_js() {
    if [ ! -f "$SESSION_MARKERS_JS" ]; then
        fail "$1 (hooks/lib/session-markers.js not present)"
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
        env -u CLAUDE_ENV_FILE -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        "WORKFLOW_PLANS_DIR=$FIXTURE_PLANS_DIR" \
        "$@" \
        node "$MARK_JS" 2>&1)" || rc=$?
    return $rc
}

# run_workflow_mark_isolated <stdin-json> <workflow-dir> [extra env var ...]
# Same contract as run_workflow_mark, but used where the test needs to prove
# that NO fallback tier in resolveSessionId() can resolve a usable session id
# (see rules/test/fixture-isolation.md "Unset inherited session IDs" / "Neutral
# CWD"). Plain run_workflow_mark only unsets CLAUDE_ENV_FILE and runs from the
# repo's own working directory — inside a live Claude Code session (or any
# worktree carrying a WORKTREE_NOTES.md `Session-ID:` line) that leaves THREE
# fallback tiers live: the CLAUDE_CODE_SESSION_ID / CLAUDE_SESSION_ID env vars
# (tiers 2 and 4 in hooks/workflow-state/session-id.js resolveSessionId()) and
# the own-worktree WORKTREE_NOTES.md scan (tier 6), any of which can resolve
# the REAL ambient session id and mask the "no session id resolvable" case
# under test. This variant additionally unsets both session-id env vars and
# runs node from a neutral temp directory outside any git worktree, so tiers
# 2, 4, 6, 6b, 6c and 7 (JSONL transcript mtime scan) all fail to resolve —
# only tier 1 (the session_id supplied in the payload itself) remains live.
run_workflow_mark_isolated() {
    local payload="$1"; shift
    local wfdir="$1"; shift
    local rc=0
    MARK_OUT="$(cd "$TMPDIR_BASE" && printf '%s' "$payload" | run_with_timeout 30 \
        env -u CLAUDE_ENV_FILE -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        "WORKFLOW_PLANS_DIR=$FIXTURE_PLANS_DIR" \
        "$@" \
        node "$MARK_JS" 2>&1)" || rc=$?
    return $rc
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

# Write a marker file directly (simulating a previous workflow-mark.js run).
# Args: workflow-dir session-id [reason]
write_marker_file() {
    local wfdir="$1" sid="$2" reason="${3:-}"
    if [ -n "$reason" ]; then
        printf '{"set_at":"2026-01-01T00:00:00Z","reason":"%s"}\n' "$reason" \
            > "$wfdir/$sid.workflow-off"
    else
        printf '{"set_at":"2026-01-01T00:00:00Z"}\n' \
            > "$wfdir/$sid.workflow-off"
    fi
}

# Invoke node with isWorkflowOff(sid) and echo the result ("true"/"false"/<error>).
# Args: <workflow-dir> <session-id-arg-as-js-literal>
# Note: <session-id-arg-as-js-literal> must be a node-syntax-valid expression
# (e.g. '"abc"' or '""' or '"../foo"'). When unset workflow dir is needed
# (for B6), pass empty string for wfdir.
run_is_workflow_off() {
    local wfdir="$1" sid_js="$2"
    local out rc=0
    if [ -n "$wfdir" ]; then
        out="$(run_with_timeout 30 \
            env -u CLAUDE_ENV_FILE -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
            "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
            "CLAUDE_WORKFLOW_DIR=$wfdir" \
            "WORKFLOW_PLANS_DIR=$FIXTURE_PLANS_DIR" \
            node -e "const sm=require('$SESSION_MARKERS_JS'); try { console.log(sm.isWorkflowOff($sid_js)); } catch(e) { console.log('THREW:'+e.message); }" 2>&1)" || rc=$?
    else
        # No CLAUDE_WORKFLOW_DIR → getWorkflowDir() resolves a default which
        # may not be writable in CI; the test ensures fail-closed (no throw).
        out="$(run_with_timeout 30 \
            env -u CLAUDE_ENV_FILE -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
            -u CLAUDE_WORKFLOW_DIR -u WORKFLOW_PLANS_DIR -u HOME -u USERPROFILE \
            "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
            node -e "const sm=require('$SESSION_MARKERS_JS'); try { console.log(sm.isWorkflowOff($sid_js)); } catch(e) { console.log('THREW:'+e.message); }" 2>&1)" || rc=$?
    fi
    printf '%s' "$out"
    return $rc
}

# Invoke node with workflowOffNoticeText(hookName, sid).
run_notice_text() {
    local wfdir="$1" hook_js="$2" sid_js="$3"
    local out rc=0
    out="$(run_with_timeout 30 \
        env -u CLAUDE_ENV_FILE -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        "WORKFLOW_PLANS_DIR=$FIXTURE_PLANS_DIR" \
        node -e "const sm=require('$SESSION_MARKERS_JS'); try { const r = sm.workflowOffNoticeText($hook_js, $sid_js); console.log('TYPE:'+typeof r); console.log('VAL:'+r); } catch(e) { console.log('THREW:'+e.message); }" 2>&1)" || rc=$?
    printf '%s' "$out"
    return $rc
}
