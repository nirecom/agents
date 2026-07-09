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

    # ED22: FOO=1 pytest tests/ + exit=0 → run_tests: pending
    # (env-prefix stripped: 'FOO=1' resolved to 'pytest', which is a test runner)
    SID="ed22-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook 'FOO=1 pytest tests/' 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "ED22. FOO=1 pytest tests/ + exit=0 → run_tests=pending (env-prefix stripped: pytest detected)"
    else
        fail "ED22. FOO=1 pytest tests/ + exit=0 → expected pending, got run_tests=$STATUS"
    fi

    # ED23: if false; then pytest tests/; fi + exit=0 → run_tests: pending
    # (then body keyword stripped: pytest in then body IS a test command)
    SID="ed23-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook 'if false; then pytest tests/; fi' 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "ED23. if false; then pytest tests/; fi + exit=0 → run_tests=pending (then-body detection: pytest detected)"
    else
        fail "ED23. if false; then pytest tests/; fi + exit=0 → expected pending, got run_tests=$STATUS"
    fi

    # ED24: until pytest tests/; do : ; done + exit=0 → run_tests: pending
    # (until condition header stripped: pytest in condition IS a test command)
    SID="ed24-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook 'until pytest tests/; do : ; done' 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "ED24. until pytest tests/; do : ; done + exit=0 → run_tests=pending (until condition: pytest detected)"
    else
        fail "ED24. until pytest tests/; do : ; done + exit=0 → expected pending, got run_tests=$STATUS"
    fi

    # ED25: elif pytest tests/; then : ; fi + exit=0 → run_tests: pending
    # (elif condition header stripped: pytest in condition IS a test command)
    SID="ed25-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook 'elif pytest tests/; then : ; fi' 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "ED25. elif pytest tests/; then : ; fi + exit=0 → run_tests=pending (elif condition: pytest detected)"
    else
        fail "ED25. elif pytest tests/; then : ; fi + exit=0 → expected pending, got run_tests=$STATUS"
    fi

    # ED26: case "$f" in tests/*) head -n 1 "$f" ;; esac + exit=0 → state absent
    # (case is non-exec header, esac is terminator: head is read-only)
    SID="ed26-$$-$RANDOM"
    run_run_tests_hook 'case "$f" in tests/*) head -n 1 "$f" ;; esac' 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED26. case \"\$f\" in tests/*) head -n 1 \"\$f\" ;; esac + exit=0 → state absent (case/esac: head is read-only)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED26. case \"\$f\" in tests/*) head -n 1 \"\$f\" ;; esac + exit=0 → expected absent, got run_tests=$STATUS"
    fi

    # ED27: case "$f" in *) pytest tests/ ;; esac + exit=0 → run_tests: pending
    # (pytest in case body IS a test command)
    SID="ed27-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook 'case "$f" in *) pytest tests/ ;; esac' 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "ED27. case \"\$f\" in *) pytest tests/ ;; esac + exit=0 → run_tests=pending (case body: pytest detected)"
    else
        fail "ED27. case \"\$f\" in *) pytest tests/ ;; esac + exit=0 → expected pending, got run_tests=$STATUS"
    fi

    # ED28: pytest "unterminated + exit=0 → state absent (parseFailure: unclosed quote)
    # No seed: parseFailure makes isTestCommand return false, so the hook never
    # touches state. Seeding via markStep would default run_tests=pending and
    # defeat check_state_file_absent (matches sibling state-absent cases ED16/ED26).
    SID="ed28-$$-$RANDOM"
    run_run_tests_hook 'pytest "unterminated' 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED28. pytest \"unterminated + exit=0 → state absent (parseFailure: unclosed quote)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED28. pytest \"unterminated + exit=0 → expected absent (parseFailure), got run_tests=$STATUS"
    fi

    # ED29: seeded run_tests=complete + unclosed-quote test-looking command → complete preserved
    # (parseFailure → isTestCommand=false → hook early-returns before reading/writing state;
    #  proves a malformed test-looking command does NOT demote an existing complete. Sibling of
    #  ED28: ED28 proves the fresh-state no-op, ED29 proves the no-demotion property.)
    SID="ed29-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    seed_run_tests "$SID" "complete"
    run_run_tests_hook 'pytest "tests/' 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "complete" ]; then
        pass "ED29. pytest \"tests/ (unclosed quote) + seeded run_tests=complete → complete preserved (parseFailure early-return, no demotion)"
    else
        fail "ED29. pytest \"tests/ (unclosed quote) + seeded run_tests=complete → expected complete (no demotion), got run_tests=$STATUS"
    fi

    # ED30: if false; then :; else cat tests/foo.sh; fi + exit=0 → state absent
    # (else body keyword stripped: effective cmd0=cat is read-only)
    SID="ed30-$$-$RANDOM"
    run_run_tests_hook 'if false; then :; else cat tests/foo.sh; fi' 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED30. if false; then :; else cat tests/foo.sh; fi + exit=0 → state absent (else body keyword: cat is read-only)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED30. if false; then :; else cat tests/foo.sh; fi + exit=0 → expected absent, got run_tests=$STATUS"
    fi

    # ED31: if false; then :; else pytest tests/; fi + exit=0 → run_tests: pending
    # (else body keyword stripped: effective cmd0=pytest is a test runner → detected)
    SID="ed31-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook 'if false; then :; else pytest tests/; fi' 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "ED31. if false; then :; else pytest tests/; fi + exit=0 → run_tests=pending (else body: pytest detected)"
    else
        fail "ED31. if false; then :; else pytest tests/; fi + exit=0 → expected pending, got run_tests=$STATUS"
    fi

    # ED32: select f in tests/*.sh; do head -n 1 "$f"; done + exit=0 → state absent
    # (select is a non-exec header → null; do head is read-only)
    SID="ed32-$$-$RANDOM"
    run_run_tests_hook 'select f in tests/*.sh; do head -n 1 "$f"; done' 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED32. select f in tests/*.sh; do head -n 1 \"\$f\"; done + exit=0 → state absent (select non-exec header + read-only head)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED32. select f in tests/*.sh; do head -n 1 \"\$f\"; done + exit=0 → expected absent, got run_tests=$STATUS"
    fi

    # ---------------------------------------------------------------------------
    # === C4: special-character / quoted tests/ path coverage ===
    # Quoted paths containing spaces, parens, brackets, and backslashes must be
    # classified correctly for BOTH the read-only exclusion and runner-detection
    # branches. Behavior below verified against the real hook.
    # ---------------------------------------------------------------------------

    # ED33: cat "tests/a b.sh" + exit=0 → state absent (read-only, quoted space path)
    SID="ed33-$$-$RANDOM"
    run_run_tests_hook 'cat "tests/a b.sh"' 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED33. cat \"tests/a b.sh\" + exit=0 → state absent (read-only, quoted space path)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED33. cat \"tests/a b.sh\" + exit=0 → expected absent (read-only quoted space), got run_tests=$STATUS"
    fi

    # ED34: pytest "tests/a b.py" + exit=0 → run_tests: pending (runner, quoted space path)
    SID="ed34-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook 'pytest "tests/a b.py"' 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "ED34. pytest \"tests/a b.py\" + exit=0 → run_tests=pending (runner, quoted space path)"
    else
        fail "ED34. pytest \"tests/a b.py\" + exit=0 → expected pending (runner quoted space), got run_tests=$STATUS"
    fi

    # ED35: bash "tests/a (b).sh" + exit=0 → run_tests: pending (runner + parens in quoted path)
    SID="ed35-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook 'bash "tests/a (b).sh"' 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "ED35. bash \"tests/a (b).sh\" + exit=0 → run_tests=pending (runner + parens in quoted path)"
    else
        fail "ED35. bash \"tests/a (b).sh\" + exit=0 → expected pending (runner quoted parens), got run_tests=$STATUS"
    fi

    # ED36: bash "tests/a [b].sh" + exit=0 → run_tests: pending (runner + brackets in quoted path)
    SID="ed36-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook 'bash "tests/a [b].sh"' 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "ED36. bash \"tests/a [b].sh\" + exit=0 → run_tests=pending (runner + brackets in quoted path)"
    else
        fail "ED36. bash \"tests/a [b].sh\" + exit=0 → expected pending (runner quoted brackets), got run_tests=$STATUS"
    fi

    # ED37: cat "tests/a\b.sh" + exit=0 → state absent (read-only, backslash in quoted path)
    SID="ed37-$$-$RANDOM"
    run_run_tests_hook 'cat "tests/a\b.sh"' 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED37. cat \"tests/a\\b.sh\" + exit=0 → state absent (read-only, backslash in quoted path)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED37. cat \"tests/a\\b.sh\" + exit=0 → expected absent (read-only quoted backslash), got run_tests=$STATUS"
    fi

    # ---------------------------------------------------------------------------
    # === C3: long-string edge coverage ===
    # Very long commands must classify the same as their short equivalents:
    # length does not affect read-only exclusion or runner detection.
    # Behavior below verified against the real hook.
    # ---------------------------------------------------------------------------

    # ED38: very long read-only command referencing tests/ → state absent
    # (grep with a ~500-char pattern; whole command is read-only, tests/ is only a grep target)
    SID="ed38-$$-$RANDOM"
    LONG_PATTERN=$(printf 'x%.0s' {1..500})
    run_run_tests_hook "grep $LONG_PATTERN tests/foo.sh" 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED38. grep <500-char-pattern> tests/foo.sh + exit=0 → state absent (long read-only command)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED38. grep <500-char-pattern> tests/foo.sh + exit=0 → expected absent (long read-only), got run_tests=$STATUS"
    fi

    # ED39: very long valid runner command → run_tests: pending
    # (pytest tests/ followed by many long flags; still a real test runner)
    SID="ed39-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    LONG_FLAGS=""
    for i in $(seq 1 60); do LONG_FLAGS="$LONG_FLAGS --flag-number-$i=valuevaluevalue"; done
    run_run_tests_hook "pytest tests/$LONG_FLAGS" 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "ED39. pytest tests/ <many long flags> + exit=0 → run_tests=pending (long valid runner command)"
    else
        fail "ED39. pytest tests/ <many long flags> + exit=0 → expected pending (long runner), got run_tests=$STATUS"
    fi
}
