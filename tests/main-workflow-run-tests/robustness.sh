# shellcheck shell=bash
# Tests: hooks/workflow-run-tests.js
# Tags: workflow, tests, runner, hook, robustness, security, scope:common
# Case group: fail-open error branches (C3) and security no-leak (C4).
# Sourced by main-workflow-run-tests.sh; relies on helpers from common.sh.
#
# C3 exercises the hook's fail-open contract: malformed stdin, non-Bash tool,
# and empty/missing command must all no-op (stdout `{}`, exit 0, no state write).
# These branches short-circuit before any state helper runs, so they cannot use
# run_run_tests_hook (which always builds a well-formed Bash payload) — instead
# they pipe hand-built stdin directly to the hook.
# C4 proves an injected fake secret never reaches the hook's stdout or the
# written workflow-state file.

# run_raw_stdin_hook <raw_stdin> <session_id>
# Pipes an arbitrary raw string to the hook (bypasses JSON construction so
# malformed input can be tested). Populates LAST_HOOK_STDOUT / LAST_HOOK_EXIT
# so check_state_file_absent can assert a clean no-op.
run_raw_stdin_hook() {
    local raw="$1"
    LAST_HOOK_STDOUT=$(printf '%s' "$raw" | CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node "$RUN_TESTS_HOOK" 2>/dev/null)
    LAST_HOOK_EXIT=$?
    printf '%s' "$LAST_HOOK_STDOUT"
}

run_robustness_tests() {
    # -----------------------------------------------------------------------
    # === C3: fail-open error branches ===
    # Each branch must print exactly `{}`, exit 0, and write NO state file.
    # Behavior below verified against the real hook.
    # -----------------------------------------------------------------------

    echo ""
    echo "=== workflow-run-tests: C3 fail-open error branches ==="

    # C3-1: malformed stdin JSON → {} , exit 0, no state.
    # No valid session_id can be parsed from malformed JSON, so pick a unique sid
    # purely for the state-file-absence assertion (nothing could have written it).
    SID="c3-malformed-$$-$RANDOM"
    run_raw_stdin_hook 'not-json{'
    if [ "$LAST_HOOK_STDOUT" = "{}" ] && [ "$LAST_HOOK_EXIT" -eq 0 ] && check_state_file_absent "$SID"; then
        pass "C3-1. malformed stdin JSON → {} + exit 0 + no state (fail-open)"
    else
        fail "C3-1. malformed stdin JSON → expected {}/exit0/no-state, got stdout='$LAST_HOOK_STDOUT' exit=$LAST_HOOK_EXIT"
    fi

    # C3-2: tool_name=Edit (not Bash) with a test-looking command → {} , exit 0, no state.
    SID="c3-edit-$$-$RANDOM"
    JSON=$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Edit",tool_input:{command:"pytest tests/"},tool_response:{exit_code:0},session_id:process.argv[1]}))' "$SID" 2>/dev/null)
    run_raw_stdin_hook "$JSON"
    if [ "$LAST_HOOK_STDOUT" = "{}" ] && [ "$LAST_HOOK_EXIT" -eq 0 ] && check_state_file_absent "$SID"; then
        pass "C3-2. tool_name=Edit + pytest tests/ → {} + exit 0 + no state (non-Bash ignored)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "C3-2. tool_name=Edit → expected {}/exit0/no-state, got stdout='$LAST_HOOK_STDOUT' exit=$LAST_HOOK_EXIT run_tests=$STATUS"
    fi

    # C3-3: tool_input.command empty string → {} , exit 0, no state.
    SID="c3-empty-$$-$RANDOM"
    JSON=$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:""},tool_response:{exit_code:0},session_id:process.argv[1]}))' "$SID" 2>/dev/null)
    run_raw_stdin_hook "$JSON"
    if [ "$LAST_HOOK_STDOUT" = "{}" ] && [ "$LAST_HOOK_EXIT" -eq 0 ] && check_state_file_absent "$SID"; then
        pass "C3-3. empty command string → {} + exit 0 + no state (fail-open)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "C3-3. empty command → expected {}/exit0/no-state, got stdout='$LAST_HOOK_STDOUT' exit=$LAST_HOOK_EXIT run_tests=$STATUS"
    fi

    # C3-4: tool_input.command missing entirely → {} , exit 0, no state.
    SID="c3-nocmd-$$-$RANDOM"
    JSON=$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{},tool_response:{exit_code:0},session_id:process.argv[1]}))' "$SID" 2>/dev/null)
    run_raw_stdin_hook "$JSON"
    if [ "$LAST_HOOK_STDOUT" = "{}" ] && [ "$LAST_HOOK_EXIT" -eq 0 ] && check_state_file_absent "$SID"; then
        pass "C3-4. missing command → {} + exit 0 + no state (fail-open)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "C3-4. missing command → expected {}/exit0/no-state, got stdout='$LAST_HOOK_STDOUT' exit=$LAST_HOOK_EXIT run_tests=$STATUS"
    fi

    # -----------------------------------------------------------------------
    # === C4: security no-leak ===
    # A fake secret injected into BOTH tool_input.command and tool_response.stdout
    # must NOT appear in (a) the hook's stdout, nor (b) the written state file.
    # The value is a clearly-fake placeholder (never a real-looking secret).
    # write_tests is seeded complete so this is a DETECTED test path (the hook
    # writes state), maximising the leak surface the assertion covers.
    # Behavior below verified against the real hook.
    # -----------------------------------------------------------------------

    echo ""
    echo "=== workflow-run-tests: C4 security no-leak ==="

    # C4-1: fake secret in command + stdout → absent from hook stdout AND state file.
    SID="c4-secret-$$-$RANDOM"
    FAKE_SECRET="sk-FAKE-not-a-real-secret-0000"
    seed_write_tests "$SID" "complete"
    C4_JSON=$(node -e '
const secret = process.argv[2];
process.stdout.write(JSON.stringify({
  tool_name: "Bash",
  tool_input: { command: "pytest tests/ --token=" + secret },
  tool_response: { exit_code: 0, stdout: "test output line with " + secret + " embedded" },
  session_id: process.argv[1]
}));
' "$SID" "$FAKE_SECRET" 2>/dev/null)
    run_raw_stdin_hook "$C4_JSON"
    # grep -c prints its own count AND exits 1 on zero matches. Swallow the exit
    # with `|| true` (NOT `|| echo 0`, which would append a second line and make
    # the count a non-integer "0\n0"). Missing file → grep exits 2 with no stdout,
    # so default the empty capture to 0 afterwards.
    C4_STDOUT_LEAK=$(printf '%s' "$LAST_HOOK_STDOUT" | grep -c "$FAKE_SECRET" || true)
    C4_STATE_LEAK=$(grep -c "$FAKE_SECRET" "$WORKFLOW_DIR/$SID.json" 2>/dev/null || true)
    C4_STDOUT_LEAK=${C4_STDOUT_LEAK:-0}
    C4_STATE_LEAK=${C4_STATE_LEAK:-0}
    if [ "$LAST_HOOK_EXIT" -eq 0 ] && [ "$C4_STDOUT_LEAK" -eq 0 ] && [ "$C4_STATE_LEAK" -eq 0 ]; then
        pass "C4-1. fake secret in command+stdout → absent from hook stdout AND state file (no-leak)"
    else
        fail "C4-1. fake secret leaked → exit=$LAST_HOOK_EXIT stdout_hits=$C4_STDOUT_LEAK state_hits=$C4_STATE_LEAK"
    fi
}
