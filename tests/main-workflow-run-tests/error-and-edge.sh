# shellcheck shell=bash
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


    # ED16: for f in tests/*.sh; do head -n 10 "$f"; done + exit=0 → run_tests: pending
    SID="ed16-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook 'for f in tests/*.sh; do head -n 10 "$f"; done' 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "ED16. for f in tests/*.sh; do head -n 10 \"\$f\"; done + exit=0 → run_tests=pending (control-structure penetration: for keyword not stripped)"
    else
        fail "ED16. for f in tests/*.sh; do head -n 10 \"\$f\"; done + exit=0 → expected pending, got run_tests=$STATUS"
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

    # ED18: while head tests/; do : ; done + exit=0 → run_tests: pending
    SID="ed18-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook 'while head tests/; do : ; done' 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "ED18. while head tests/; do : ; done + exit=0 → run_tests=pending (condition header: while not stripped, head not at segment start)"
    else
        fail "ED18. while head tests/; do : ; done + exit=0 → expected pending, got run_tests=$STATUS"
    fi

    # ED19: FOO=1 head tests/foo.sh + exit=0 → run_tests: pending
    SID="ed19-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook 'FOO=1 head tests/foo.sh' 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "ED19. FOO=1 head tests/foo.sh + exit=0 → run_tests=pending (env-prefix not stripped: segment starts with FOO=1)"
    else
        fail "ED19. FOO=1 head tests/foo.sh + exit=0 → expected pending, got run_tests=$STATUS"
    fi

    # ED20: do FOO=1 head tests/foo.sh + exit=0 → run_tests: pending
    SID="ed20-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook 'do FOO=1 head tests/foo.sh' 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "ED20. do FOO=1 head tests/foo.sh + exit=0 → run_tests=pending (body keyword + env-prefix: neither stripped)"
    else
        fail "ED20. do FOO=1 head tests/foo.sh + exit=0 → expected pending, got run_tests=$STATUS"
    fi

}
