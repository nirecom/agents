# shellcheck shell=bash
# Tests: hooks/codegraph-context-inject.js
# Tags: hook-injection, codegraph, prompt-hook, env-flag, fail-safe-off, TL2, scope:issue-specific
# M16-M21: the config gate, verbatim forwarding of the CLI's stdout, and every
# failure class the hook must absorb into a silent `{}` (non-zero exit, spawn
# ENOENT, an unresponsive child, unusable stdin).
# Sourced by tests/feature-2215-codegraph-context-inject.sh after harness.sh.

# ===========================================================================
# M16: CODEGRAPH off / unset / invalid -> {} and stub never called
# ===========================================================================
for variant in off unset invalid; do
    CFG="$TMPDIR_BASE/cfg-m16-$variant"; mkdir -p "$CFG"
    case "$variant" in
        off) printf 'CODEGRAPH=off\n' > "$CFG/.env" ;;
        unset) : ;; # no .env at all
        invalid) printf 'CODEGRAPH=yes\n' > "$CFG/.env" ;;
    esac
    RESET_LOGS
    LOG="$TMPDIR_BASE/log-call-m16-$variant"
    raw=$(
        cd "$ORD_PLAIN" || exit 99
        printf '{"prompt":"hi","cwd":"%s","session_id":"s1","hook_event_name":"UserPromptSubmit"}' "$ORD_PLAIN" | \
            run_with_timeout 15 env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
            AGENTS_CONFIG_DIR="$(to_node_path "$CFG")" \
            PATH="$BIN:$PATH" \
            CLAUDE_WORKFLOW_DIR="$WF_DIR_N" WORKFLOW_PLANS_DIR="$WF_DIR_N" \
            HOME="$FAKE_HOME_N" USERPROFILE="$FAKE_HOME_N" \
            CG_STUB_LOG="$(to_node_path "$LOG")" \
            node "$HOOK" 2>/dev/null
    )
    calls="$([ -f "$LOG" ] && wc -l < "$LOG" | tr -d ' ' || echo 0)"
    if [ "$raw" = "{}" ] && [ "$calls" -eq 0 ]; then
        pass "M16 ($variant): stdout is strictly {}, stub never called"
    else
        fail "M16 ($variant): expected {} + 0 calls, got raw='$raw' calls=$calls"
    fi
done

# ===========================================================================
# M17: CODEGRAPH=on, stub returns plain text -> forwarded verbatim
# ===========================================================================
PLAIN_TEXT=$'<codegraph_context note="test">\n  line one\n  line two\n</codegraph_context>\n'
RESET_LOGS
raw17=$(run_hook "{\"prompt\":\"hi\",\"cwd\":\"$ORD_PLAIN\",\"session_id\":\"s1\",\"hook_event_name\":\"UserPromptSubmit\"}" "$ORD_PLAIN" CG_STUB_OUT="$PLAIN_TEXT")
event17=$(json_field "$raw17" "hookSpecificOutput.hookEventName")
# additionalContext is compared via files, not `ctx17=$(json_field ...)`: the
# stub's stdout deliberately ends in a trailing newline (leading/trailing
# whitespace and internal newlines must all survive verbatim forwarding), and
# `$()` command substitution unconditionally strips trailing newlines from its
# own output. Capturing through `$()` here would make the trailing-newline
# case unpassable regardless of how faithfully the hook forwards the text.
CTX17_ACTUAL="$TMPDIR_BASE/ctx17.actual"
CTX17_EXPECTED="$TMPDIR_BASE/ctx17.expected"
json_field_to_file "$raw17" "hookSpecificOutput.additionalContext" "$CTX17_ACTUAL"
printf '%s' "$PLAIN_TEXT" > "$CTX17_EXPECTED"
argv17="$(last_call_argv)"
if [ "$event17" = "UserPromptSubmit" ] && cmp -s "$CTX17_ACTUAL" "$CTX17_EXPECTED" && [ "$argv17" = "prompt-hook" ]; then
    pass "M17: hookEventName=UserPromptSubmit, additionalContext byte-identical to stub stdout (leading/trailing whitespace and internal newlines preserved), codegraph invoked with argv 'prompt-hook'"
else
    fail "M17: event='$event17' ctx=$(printf '%q' "$(cat "$CTX17_ACTUAL" 2>/dev/null)") expected=$(printf '%q' "$PLAIN_TEXT") argv='$argv17' raw='$raw17'"
fi

# ===========================================================================
# M18: stub returns empty string -> {}
# ===========================================================================
RESET_LOGS
raw18=$(run_hook "{\"prompt\":\"hi\",\"cwd\":\"$ORD_PLAIN\",\"session_id\":\"s1\",\"hook_event_name\":\"UserPromptSubmit\"}" "$ORD_PLAIN" CG_STUB_OUT="")
if [ "$raw18" = "{}" ]; then
    pass "M18: empty stdout -> {}"
else
    fail "M18: expected {}, got '$raw18'"
fi

# ===========================================================================
# M19: stub exits 1 -> {} and hook itself exits 0
# ===========================================================================
RESET_LOGS
raw19=$(run_hook "{\"prompt\":\"hi\",\"cwd\":\"$ORD_PLAIN\",\"session_id\":\"s1\",\"hook_event_name\":\"UserPromptSubmit\"}" "$ORD_PLAIN" CG_STUB_EXIT=1 CG_STUB_OUT="should not appear")
rc19=$?
if [ "$raw19" = "{}" ] && [ "$rc19" -eq 0 ]; then
    pass "M19: stub exit 1 -> {} and hook exit 0"
else
    fail "M19: raw='$raw19' rc=$rc19"
fi

# ===========================================================================
# M19b: codegraph absent from PATH (spawn ENOENT) -> {} and hook exits 0.
# Sibling to M19 (exit-1) but a different failure class: spawnSync's own
# result.error branch (S5-1 step 5), never reached by an exit-1 stub. PATH is
# pinned to node's own directory ONLY (never $BIN, never the inherited
# $PATH) so a real codegraph on the host's PATH cannot leak this pass.
# ===========================================================================
# Kept in POSIX form (not to_node_path()'s "C:/..."): a drive-letter colon
# collides with PATH's ':' separator on MSYS bash and breaks node's own
# resolution too, failing this case for the wrong reason.
NODE_ONLY_DIR_N="$(dirname "$(command -v node)")"
RESET_LOGS
# Its own log name, not the shared $LOG: this case builds its command line by
# hand, so it must not disturb the trio run_hook() and call_count() share.
LOG19B="$TMPDIR_BASE/log-call-m19b"
raw19b=$(
    cd "$ORD_PLAIN" || exit 99
    printf '{"prompt":"hi","cwd":"%s","session_id":"s1","hook_event_name":"UserPromptSubmit"}' "$ORD_PLAIN" | \
        run_with_timeout 15 env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        AGENTS_CONFIG_DIR="$CFG_ON_N" \
        PATH="$NODE_ONLY_DIR_N" \
        CLAUDE_WORKFLOW_DIR="$WF_DIR_N" WORKFLOW_PLANS_DIR="$WF_DIR_N" \
        HOME="$FAKE_HOME_N" USERPROFILE="$FAKE_HOME_N" \
        CG_STUB_LOG="$(to_node_path "$LOG19B")" \
        node "$HOOK" 2>/dev/null
)
rc19b=$?
calls19b="$([ -f "$LOG19B" ] && wc -l < "$LOG19B" | tr -d ' ' || echo 0)"
if [ "$raw19b" = "{}" ] && [ "$rc19b" -eq 0 ] && [ "$calls19b" -eq 0 ]; then
    pass "M19b: codegraph absent from PATH -> {} , hook exits 0, stub never invoked (spawn ENOENT)"
else
    fail "M19b: raw='$raw19b' rc=$rc19b calls=$calls19b"
fi

# ===========================================================================
# M20: stub hangs -> hook self-times-out (~4s) and returns {}
# ===========================================================================
RESET_LOGS
_t0=$(date +%s)
raw20=$(run_hook "{\"prompt\":\"hi\",\"cwd\":\"$ORD_PLAIN\",\"session_id\":\"s1\",\"hook_event_name\":\"UserPromptSubmit\"}" "$ORD_PLAIN" CG_STUB_HANG=1)
rc20=$?
_t1=$(date +%s)
_elapsed=$((_t1 - _t0))
if [ "$raw20" = "{}" ] && [ "$rc20" -eq 0 ] && [ "$_elapsed" -ge 3 ] && [ "$_elapsed" -le 8 ]; then
    pass "M20: unresponsive stub -> {} within the hook's own ~4s budget (elapsed=${_elapsed}s)"
else
    fail "M20: raw='$raw20' rc=$rc20 elapsed=${_elapsed}s (expected {} , rc 0, ~4s)"
fi

# ===========================================================================
# M21: empty / malformed stdin -> exit 0, {}, stub never invoked
# ===========================================================================
for stdin_variant in "" "not-json{{{"; do
    RESET_LOGS
    # Own log name for the same reason as M19b — this case bypasses run_hook().
    LOG21="$TMPDIR_BASE/log-call-m21"
    raw21=$(
        cd "$ORD_PLAIN" || exit 99
        printf '%s' "$stdin_variant" | run_with_timeout 15 env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
            AGENTS_CONFIG_DIR="$CFG_ON_N" PATH="$BIN:$PATH" \
            CLAUDE_WORKFLOW_DIR="$WF_DIR_N" WORKFLOW_PLANS_DIR="$WF_DIR_N" \
            HOME="$FAKE_HOME_N" USERPROFILE="$FAKE_HOME_N" \
            CG_STUB_LOG="$(to_node_path "$LOG21")" \
            node "$HOOK" 2>/dev/null
    )
    rc21=$?
    calls21="$([ -f "$LOG21" ] && wc -l < "$LOG21" | tr -d ' ' || echo 0)"
    if [ "$raw21" = "{}" ] && [ "$rc21" -eq 0 ] && [ "$calls21" -eq 0 ]; then
        pass "M21 (stdin='$stdin_variant'): exit 0, {}, stub not invoked"
    else
        fail "M21 (stdin='$stdin_variant'): raw='$raw21' rc=$rc21 calls=$calls21"
    fi
done
