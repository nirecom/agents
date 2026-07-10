# shellcheck shell=bash
# Tests: hooks/workflow-run-tests.js
# Tags: workflow, tests, runner, hook, error-and-edge, scope:common
# Case group: Error cases (E-group) and Edge cases (ED-group).
# Sourced by main-workflow-run-tests.sh; relies on helpers from common.sh.

run_error_and_edge_tests() {
    # ---------------------------------------------------------------------------
    # === Error cases ===
    # ---------------------------------------------------------------------------

    echo ""
    echo "=== workflow-run-tests: Error cases ==="

    # E1: pytest tests/ + exit=1 → run_tests: pending (with last_run_failed)
    SID="e1-$$-$RANDOM"
    run_run_tests_hook "pytest tests/" 1 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "E1. pytest tests/ + exit=1 → run_tests=pending"
    else
        fail "E1. pytest tests/ + exit=1 → expected run_tests=pending, got: $STATUS"
    fi

    # Also verify last_run_failed is set
    E1_FAILED=$(node -e "
try {
  const s = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
  const rt = s.steps && s.steps.run_tests;
  console.log(rt && rt.last_run_failed === true ? 'yes' : 'no');
} catch(e) { console.log('no'); }
" "$WORKFLOW_DIR/$SID.json" 2>/dev/null || echo "no")
    if [ "$E1_FAILED" = "yes" ]; then
        pass "E1b. pytest tests/ + exit=1 → last_run_failed=true"
    else
        fail "E1b. pytest tests/ + exit=1 → expected last_run_failed=true, got: $E1_FAILED"
    fi

    # E2: bash tests/foo.sh + exit=2 → run_tests: pending
    SID="e2-$$-$RANDOM"
    run_run_tests_hook "bash tests/foo.sh" 2 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "E2. bash tests/foo.sh + exit=2 → run_tests=pending"
    else
        fail "E2. bash tests/foo.sh + exit=2 → expected run_tests=pending, got: $STATUS"
    fi

    # ---------------------------------------------------------------------------
    # === Edge cases — commands that should NOT trigger run_tests marking ===
    # ---------------------------------------------------------------------------

    echo ""
    echo "=== workflow-run-tests: Edge cases (no-op commands) ==="

    # ED1: ls tests/ + exit=0 → state absent/unchanged
    SID="ed1-$$-$RANDOM"
    run_run_tests_hook "ls tests/" 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED1. ls tests/ + exit=0 → state absent/unchanged"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED1. ls tests/ + exit=0 → expected absent, got run_tests=$STATUS"
    fi

    # ED2: cat tests/foo.sh + exit=0 → state absent/unchanged
    SID="ed2-$$-$RANDOM"
    run_run_tests_hook "cat tests/foo.sh" 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED2. cat tests/foo.sh + exit=0 → state absent/unchanged"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED2. cat tests/foo.sh + exit=0 → expected absent, got run_tests=$STATUS"
    fi

    # ED3: grep foo tests/ + exit=0 → state absent/unchanged
    SID="ed3-$$-$RANDOM"
    run_run_tests_hook "grep foo tests/" 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED3. grep foo tests/ + exit=0 → state absent/unchanged"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED3. grep foo tests/ + exit=0 → expected absent, got run_tests=$STATUS"
    fi

    # ED4: git diff tests/ + exit=0 → state absent/unchanged
    SID="ed4-$$-$RANDOM"
    run_run_tests_hook "git diff tests/" 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED4. git diff tests/ + exit=0 → state absent/unchanged"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED4. git diff tests/ + exit=0 → expected absent, got run_tests=$STATUS"
    fi

    # ED5: git add tests/foo.sh + exit=0 → state absent/unchanged
    SID="ed5-$$-$RANDOM"
    run_run_tests_hook "git add tests/foo.sh" 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED5. git add tests/foo.sh + exit=0 → state absent/unchanged"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED5. git add tests/foo.sh + exit=0 → expected absent, got run_tests=$STATUS"
    fi

    # ED6: git commit -m "fix tests/" + exit=0 → state absent/unchanged
    SID="ed6-$$-$RANDOM"
    run_run_tests_hook 'git commit -m "fix tests/"' 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED6. git commit -m \"fix tests/\" + exit=0 → state absent/unchanged"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED6. git commit -m \"fix tests/\" + exit=0 → expected absent, got run_tests=$STATUS"
    fi

    # ED7: echo "<<WORKFLOW_MARK_STEP_foo_complete>>" + exit=0 → state absent/unchanged (sentinel excluded)
    SID="ed7-$$-$RANDOM"
    run_run_tests_hook 'echo "<<WORKFLOW_MARK_STEP_foo_complete>>"' 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED7. sentinel echo + exit=0 → state absent/unchanged"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED7. sentinel echo + exit=0 → expected absent, got run_tests=$STATUS"
    fi

    # ED8: ls tests/ && pytest tests/ + exit=0 → run_tests: pending
    # C′: complete now requires a run-all.sh invocation + exactly one RUN_CONTRACT line;
    # a bare runner with no contract → active demotion to pending.
    SID="ed8-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook "ls tests/ && pytest tests/" 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "ED8. ls tests/ && pytest tests/ + exit=0 → run_tests=pending (C′: no contract → active demotion)"
    else
        fail "ED8. ls tests/ && pytest tests/ + exit=0 → expected pending (C′: no contract), got: $STATUS"
    fi

    # ED9: git -C /some/path add tests/foo.sh + exit=0 → state absent (bare git -C false-positive guard)
    SID="ed9-$$-$RANDOM"
    run_run_tests_hook "git -C /some/path add tests/foo.sh" 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED9. git -C <path> add tests/foo.sh + exit=0 → state absent/unchanged (bare git -C excluded)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED9. git -C <path> add tests/foo.sh + exit=0 → expected absent (bare git -C), got run_tests=$STATUS"
    fi

    # ED10: git -C "path with spaces" add tests/foo.sh + exit=0 → state absent (quoted -C path guard)
    SID="ed10-$$-$RANDOM"
    run_run_tests_hook 'git -C "path with spaces" add tests/foo.sh' 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED10. git -C \"path with spaces\" add tests/foo.sh + exit=0 → state absent/unchanged (quoted -C excluded)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED10. git -C \"path with spaces\" add tests/foo.sh + exit=0 → expected absent (quoted -C), got run_tests=$STATUS"
    fi

    # ED11: node script.js && wc -l tests/foo.sh + exit=0 → state absent
    # (compound: no segment is a test runner; tests/ appears only in a read-only wc segment)
    SID="ed11-$$-$RANDOM"
    run_run_tests_hook "node script.js && wc -l tests/foo.sh" 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED11. node script.js && wc -l tests/foo.sh + exit=0 → state absent (no runner segment)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED11. node script.js && wc -l tests/foo.sh + exit=0 → expected absent (non-runner segment refs tests/), got run_tests=$STATUS"
    fi

    # ED12: cd repo && pytest tests/ + exit=0 → run_tests: pending
    # C′: complete now requires a run-all.sh invocation + exactly one RUN_CONTRACT line;
    # a bare runner with no contract → active demotion to pending.
    SID="ed12-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook "cd repo && pytest tests/" 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "ED12. cd repo && pytest tests/ + exit=0 → run_tests=pending (C′: no contract → active demotion)"
    else
        fail "ED12. cd repo && pytest tests/ + exit=0 → expected pending (C′: no contract), got: $STATUS"
    fi

    # ED13: echo "a && pytest tests/" + exit=0 → state absent (quote-aware split regression)
    # (the && is inside double quotes — must NOT split; whole command is a read-only echo)
    SID="ed13-$$-$RANDOM"
    run_run_tests_hook 'echo "a && pytest tests/"' 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED13. echo \"a && pytest tests/\" + exit=0 → state absent (quote-aware: no split inside quotes)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED13. echo \"a && pytest tests/\" + exit=0 → expected absent (quoted && must not split), got run_tests=$STATUS"
    fi

    # ED14: node x.js || wc -l tests/foo.sh + exit=0 → state absent (|| operator false-positive guard)
    # (segment 1 `node x.js` is not a test runner; segment 2 `wc -l tests/foo.sh` is read-only excluded;
    #  splitting on || must prevent bare tests/ mention from triggering complete)
    SID="ed14-$$-$RANDOM"
    run_run_tests_hook "node x.js || wc -l tests/foo.sh" 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED14. node x.js || wc -l tests/foo.sh + exit=0 → state absent (|| operator: non-runner segment refs tests/)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED14. node x.js || wc -l tests/foo.sh + exit=0 → expected absent (|| split: non-runner + read-only), got run_tests=$STATUS"
    fi

    # ED15: node gen.js | grep tests/foo.sh + exit=0 → state absent (| pipe operator false-positive guard)
    # (segment 1 `node gen.js` has no test indicator; segment 2 `grep tests/foo.sh` is read-only excluded;
    #  splitting on | must prevent false complete)
    SID="ed15-$$-$RANDOM"
    run_run_tests_hook "node gen.js | grep tests/foo.sh" 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED15. node gen.js | grep tests/foo.sh + exit=0 → state absent (| pipe: read-only segment refs tests/)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED15. node gen.js | grep tests/foo.sh + exit=0 → expected absent (| pipe: non-runner + read-only), got run_tests=$STATUS"
    fi

    # ED16: for f in tests/*.sh; do head -n 10 "$f"; done + exit=0 → state absent
    SID="ed16-$$-$RANDOM"
    run_run_tests_hook 'for f in tests/*.sh; do head -n 10 "$f"; done' 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED16. for f in tests/*.sh; do head -n 10 \"\$f\"; done + exit=0 → state absent/unchanged (control-structure penetration)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED16. for f in tests/*.sh; do head -n 10 \"\$f\"; done + exit=0 → expected absent, got run_tests=$STATUS"
    fi

    # ED17: if pytest tests/; then : ; fi + exit=0 → run_tests: pending
    SID="ed17-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook 'if pytest tests/; then : ; fi' 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "ED17. if pytest tests/; then : ; fi + exit=0 → run_tests=pending (condition header penetration: pytest detected)"
    else
        fail "ED17. if pytest tests/; then : ; fi + exit=0 → expected pending, got run_tests=$STATUS"
    fi

    # ED18: while head tests/; do : ; done + exit=0 → state absent
    SID="ed18-$$-$RANDOM"
    run_run_tests_hook 'while head tests/; do : ; done' 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED18. while head tests/; do : ; done + exit=0 → state absent (condition header penetration: head is read-only)"
    else
        fail "ED18. while head tests/; do : ; done + exit=0 → expected absent, got run_tests=$STATUS"
    fi

    # ED19: FOO=1 head tests/foo.sh + exit=0 → state absent
    SID="ed19-$$-$RANDOM"
    run_run_tests_hook 'FOO=1 head tests/foo.sh' 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED19. FOO=1 head tests/foo.sh + exit=0 → state absent (env-prefix stripped: head is read-only)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED19. FOO=1 head tests/foo.sh + exit=0 → expected absent, got run_tests=$STATUS"
    fi

    # ED20: do FOO=1 head tests/foo.sh + exit=0 → state absent
    SID="ed20-$$-$RANDOM"
    run_run_tests_hook 'do FOO=1 head tests/foo.sh' 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED20. do FOO=1 head tests/foo.sh + exit=0 → state absent (body keyword + env-prefix: head is read-only)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED20. do FOO=1 head tests/foo.sh + exit=0 → expected absent, got run_tests=$STATUS"
    fi

    # ED21: for f in tests/*.sh; do pytest tests/; done + exit=0 → run_tests: pending
    # (positive loop-body detection: pytest in do body IS a test command)
    SID="ed21-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook 'for f in tests/*.sh; do pytest tests/; done' 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "ED21. for f in tests/*.sh; do pytest tests/; done + exit=0 → run_tests=pending (loop-body detection: pytest detected)"
    else
        fail "ED21. for f in tests/*.sh; do pytest tests/; done + exit=0 → expected pending, got run_tests=$STATUS"
    fi

    # ---------------------------------------------------------------------------
    # === Exit-code resolution edge cases (Gap C1) ===
    # These cases exercise the exit_code resolution ladder in the hook:
    #   const exitCode = toolResponse.exit_code ?? toolResponse.exitCode
    #                    ?? (toolResponse.success === false ? 1 : 0);
    # All cases use a detected test command ("pytest tests/") so the hook reaches
    # the exit-code branch. Cases with non-zero exit trigger the fast path
    # (run_tests: pending via last_run_failed). The missing-tool_response case
    # resolves to exit 0 but no run-all.sh contract → active demotion → pending.
    # Payloads are built via node JSON.stringify (run_raw_stdin_hook) so we can
    # control tool_response fields precisely without run_run_tests_hook's forced
    # exit_code field.
    # ---------------------------------------------------------------------------

    # ED54: tool_response: {exitCode: 5} (camelCase fallback, no exit_code) → run_tests: pending
    # exit_code is undefined → falls through to exitCode ?? ... → exitCode=5 (non-zero) → pending
    SID="ed54-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    ED54_JSON=$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"pytest tests/"},tool_response:{exitCode:5},session_id:process.argv[1]}))' "$SID" 2>/dev/null)
    run_raw_stdin_hook "$ED54_JSON"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "ED54. tool_response:{exitCode:5} (camelCase, no exit_code) → run_tests=pending (exitCode fallback: non-zero fast path)"
    else
        fail "ED54. tool_response:{exitCode:5} → expected pending (camelCase fallback), got: $STATUS"
    fi

    # ED55: tool_response: {success: false} (no exit_code/exitCode) → run_tests: pending
    # exit_code undefined, exitCode undefined → success===false → exitCode=1 (non-zero) → pending
    SID="ed55-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    ED55_JSON=$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"pytest tests/"},tool_response:{success:false},session_id:process.argv[1]}))' "$SID" 2>/dev/null)
    run_raw_stdin_hook "$ED55_JSON"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "ED55. tool_response:{success:false} (no exit_code/exitCode) → run_tests=pending (success===false coerced to 1: non-zero fast path)"
    else
        fail "ED55. tool_response:{success:false} → expected pending (success coercion), got: $STATUS"
    fi

    # ED56: tool_response MISSING entirely (only tool_name/tool_input/session_id) → run_tests: pending
    # input.tool_response is undefined → toolResponse={} → all three ladder fields absent
    # → exitCode=0 (default) → detected test command, no run-all.sh contract → active demotion
    SID="ed56-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    ED56_JSON=$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"pytest tests/"},session_id:process.argv[1]}))' "$SID" 2>/dev/null)
    run_raw_stdin_hook "$ED56_JSON"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "ED56. tool_response missing entirely → run_tests=pending (exit resolves to 0, no contract → active demotion)"
    else
        fail "ED56. tool_response missing → expected pending (exit=0 active demotion), got: $STATUS"
    fi

    # ED57: tool_response: {exit_code: -1} (negative) → run_tests: pending
    # exit_code=-1 is non-zero → fast path → pending
    SID="ed57-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    ED57_JSON=$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"pytest tests/"},tool_response:{exit_code:-1},session_id:process.argv[1]}))' "$SID" 2>/dev/null)
    run_raw_stdin_hook "$ED57_JSON"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "ED57. tool_response:{exit_code:-1} (negative) → run_tests=pending (non-zero fast path)"
    else
        fail "ED57. tool_response:{exit_code:-1} → expected pending (negative exit non-zero), got: $STATUS"
    fi

    # ED58: tool_response: {exit_code: 999} (very large) → run_tests: pending
    # exit_code=999 is non-zero → fast path → pending
    SID="ed58-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    ED58_JSON=$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"pytest tests/"},tool_response:{exit_code:999},session_id:process.argv[1]}))' "$SID" 2>/dev/null)
    run_raw_stdin_hook "$ED58_JSON"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "ED58. tool_response:{exit_code:999} (very large) → run_tests=pending (non-zero fast path)"
    else
        fail "ED58. tool_response:{exit_code:999} → expected pending (large exit non-zero), got: $STATUS"
    fi

    # ED60: FOO=1 BAR=2 pytest tests/ + write_tests=complete + exit=0 → run_tests: pending
    # stripEnvPrefix strips ALL leading VAR=val assignments (not just one);
    # effective cmd0 resolves past both FOO=1 and BAR=2 to "pytest" → detected → active demotion.
    SID="ed60-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook "FOO=1 BAR=2 pytest tests/" 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "ED60. FOO=1 BAR=2 pytest tests/ + exit=0 → run_tests=pending (multi-env-prefix stripped → pytest detected → active demotion)"
    else
        fail "ED60. FOO=1 BAR=2 pytest tests/ + exit=0 → expected pending (multi-env-prefix → active demotion), got: $STATUS"
    fi

    # ED61: git -C (trailing value-option overshoot) + exit=0 → state absent
    # resolveGitSubcommand: -C is value-taking; with no following token i+=2 overshoots
    # argv length, loop exits, returns "". "" is not a non-exec subcommand and the
    # command has no test path/runner, so NOT detected → state absent (no throw, no misclassification).
    SID="ed61-$$-$RANDOM"
    run_run_tests_hook "git -C" 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED61. git -C (trailing value-option, no path/subcommand) + exit=0 → state absent (overshoot boundary: safe)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED61. git -C + exit=0 → expected absent (overshoot boundary), got run_tests=$STATUS"
    fi

    # ---------------------------------------------------------------------------
    # === C3: idempotency — two runs, same session, stable state ===
    # Invoking the hook twice with the same detected test command and no contract
    # must produce run_tests=pending after both runs with no stale/accumulated
    # metadata. The second run must yield the same status as the first.
    # ---------------------------------------------------------------------------

    # ED62: invoke hook TWICE with the same session id and detected test command
    # (pytest tests/, no run-all.sh contract) → run_tests=pending after both runs,
    # stable state (second run produces identical status, no accumulated metadata).
    SID="ed62-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook "pytest tests/" 0 "$SID" >/dev/null
    STATUS_AFTER_1=$(get_run_tests_status "$SID")
    run_run_tests_hook "pytest tests/" 0 "$SID" >/dev/null
    STATUS_AFTER_2=$(get_run_tests_status "$SID")
    if [ "$STATUS_AFTER_1" = "pending" ] && [ "$STATUS_AFTER_2" = "pending" ]; then
        pass "ED62. pytest tests/ x2 (same SID, no contract) → run_tests=pending after both runs (idempotent: stable state)"
    else
        fail "ED62. pytest tests/ x2 (same SID) → expected pending/pending, got after-run1=$STATUS_AFTER_1 after-run2=$STATUS_AFTER_2"
    fi

    # ---------------------------------------------------------------------------
    # === Control-structure then/else body-keyword penetration cases ===
    # ---------------------------------------------------------------------------

    # ED63: if true; then head tests/foo.sh; fi + exit=0 → state absent
    # then body-keyword penetrated → effective cmd0 is `head` (read-only) → not detected → no state write.
    SID="ed63-$$-$RANDOM"
    run_run_tests_hook 'if true; then head tests/foo.sh; fi' 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED63. if true; then head tests/foo.sh; fi + exit=0 → state absent (then body-keyword penetration + read-only head → not detected)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED63. if true; then head tests/foo.sh; fi + exit=0 → expected absent, got run_tests=$STATUS"
    fi

    # ED64: if true; then pytest tests/; fi + exit=0 → run_tests: pending
    # then body-keyword penetrated → effective cmd0 is `pytest` → runner detected → active demotion.
    SID="ed64-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook 'if true; then pytest tests/; fi' 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "ED64. if true; then pytest tests/; fi + exit=0 → run_tests=pending (then body-keyword penetration + pytest runner → active demotion)"
    else
        fail "ED64. if true; then pytest tests/; fi + exit=0 → expected pending, got run_tests=$STATUS"
    fi

    # ED65: if false; then :; else pytest tests/; fi + exit=0 → run_tests: pending
    # else body-keyword penetrated → effective cmd0 is `pytest` → runner detected → active demotion.
    SID="ed65-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook 'if false; then :; else pytest tests/; fi' 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "ED65. if false; then :; else pytest tests/; fi + exit=0 → run_tests=pending (else body-keyword penetration + pytest → active demotion)"
    else
        fail "ED65. if false; then :; else pytest tests/; fi + exit=0 → expected pending, got run_tests=$STATUS"
    fi

    # ED66: pytest "unterminated + exit=0 → state absent
    # Unbalanced double-quote causes parse() to set parseFailure=true → isTestCommand returns false
    # → hook no-ops cleanly (fail-closed contract).
    SID="ed66-$$-$RANDOM"
    run_run_tests_hook 'pytest "unterminated' 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED66. pytest \"unterminated + exit=0 → state absent (parseFailure fail-closed: hook no-ops on malformed command)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED66. pytest \"unterminated + exit=0 → expected absent (parseFailure fail-closed), got run_tests=$STATUS"
    fi

    # ED67: git archive tests/ + write_tests=complete + exit=0 + no RUN_CONTRACT → run_tests: pending
    # `archive` is NOT in GIT_NON_EXEC_SUBCMDS → resolveGitSubcommand returns "archive" (executable
    # git subcommand); isTestCommand sees a test-path reference in an executable command → detected.
    # With write_tests seeded complete and no run-all.sh contract, the hook actively demotes
    # run_tests to pending (C′ demotion path).
    SID="ed67-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook "git archive tests/" 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "ED67. git archive tests/ + exit=0 + no contract → run_tests=pending (archive not in non-exec allowlist → executable subcommand → active demotion)"
    else
        fail "ED67. git archive tests/ + exit=0 + no contract → expected pending (archive executable subcommand → active demotion), got: $STATUS"
    fi
}
