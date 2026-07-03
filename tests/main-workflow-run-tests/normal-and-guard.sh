# shellcheck shell=bash
# Case group: Normal cases (N-group) and write_tests guard cases (G-group).
# Sourced by main-workflow-run-tests.sh; relies on helpers from common.sh.

run_normal_and_guard_tests() {
    # ---------------------------------------------------------------------------
    # === Normal cases ===
    # ---------------------------------------------------------------------------

    echo "=== workflow-run-tests: Normal cases ==="

    # N1: pytest tests/ + exit=0 → run_tests: pending
    # C′: complete now requires a run-all.sh invocation + exactly one RUN_CONTRACT line;
    # a bare runner with no contract → active demotion to pending.
    SID="n1-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook "pytest tests/" 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "N1. pytest tests/ + exit=0 → run_tests=pending (C′: no contract → active demotion)"
    else
        fail "N1. pytest tests/ + exit=0 → expected run_tests=pending (C′: no contract), got: $STATUS"
    fi

    # N2: bash tests/feature-foo.sh + exit=0 → run_tests: pending
    # C′: complete now requires a run-all.sh invocation + exactly one RUN_CONTRACT line;
    # a bare runner with no contract → active demotion to pending.
    SID="n2-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook "bash tests/feature-foo.sh" 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "N2. bash tests/feature-foo.sh + exit=0 → run_tests=pending (C′: no contract → active demotion)"
    else
        fail "N2. bash tests/feature-foo.sh + exit=0 → expected run_tests=pending (C′: no contract), got: $STATUS"
    fi

    # N3: timeout 120 bash tests/bar.sh + exit=0 → run_tests: pending
    # C′: complete now requires a run-all.sh invocation + exactly one RUN_CONTRACT line;
    # a bare runner with no contract → active demotion to pending.
    SID="n3-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook "timeout 120 bash tests/bar.sh" 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "N3. timeout 120 bash tests/bar.sh + exit=0 → run_tests=pending (C′: no contract → active demotion)"
    else
        fail "N3. timeout 120 bash tests/bar.sh + exit=0 → expected run_tests=pending (C′: no contract), got: $STATUS"
    fi

    # ---------------------------------------------------------------------------
    # === write_tests guard cases (#1139) ===
    # The hook must only mark run_tests=complete when write_tests is complete or
    # skipped. If write_tests is pending/absent, the exit=0 mark is suppressed so a
    # write-tests subagent running the suite cannot prematurely satisfy run_tests.
    # Fail-open: the exit≠0 (pending) branch is unaffected by the guard.
    # ---------------------------------------------------------------------------

    echo ""
    echo "=== workflow-run-tests: write_tests guard cases (#1139) ==="

    # G1: write_tests=complete + bash tests/foo.sh exit=0 → run_tests=pending
    # C′: complete now requires a run-all.sh invocation + exactly one RUN_CONTRACT line;
    # a bare runner with no contract → active demotion to pending (guard no longer the binding constraint here).
    SID="g1-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook "bash tests/foo.sh" 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "G1. write_tests=complete + exit=0 + no contract → run_tests=pending (C′: contract absent → active demotion)"
    else
        fail "G1. write_tests=complete + exit=0 + no contract → expected run_tests=pending (C′), got: $STATUS"
    fi

    # G2: write_tests=skipped + pytest tests/ exit=0 → run_tests=pending
    # C′: complete now requires a run-all.sh invocation + exactly one RUN_CONTRACT line;
    # a bare runner with no contract → active demotion to pending.
    SID="g2-$$-$RANDOM"
    seed_write_tests "$SID" "skipped"
    run_run_tests_hook "pytest tests/" 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "G2. write_tests=skipped + exit=0 + no contract → run_tests=pending (C′: contract absent → active demotion)"
    else
        fail "G2. write_tests=skipped + exit=0 + no contract → expected run_tests=pending (C′), got: $STATUS"
    fi

    # G3: write_tests=pending + bash tests/foo.sh exit=0 → run_tests NOT complete (guard blocks)
    SID="g3-$$-$RANDOM"
    seed_write_tests "$SID" "pending"
    run_run_tests_hook "bash tests/foo.sh" 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" != "complete" ]; then
        pass "G3. write_tests=pending + exit=0 → run_tests NOT complete (guard blocks), got: $STATUS"
    else
        fail "G3. write_tests=pending + exit=0 → expected NOT complete (guard blocks), got: $STATUS"
    fi

    # G4: no state file at all + pytest tests/ exit=0 → run_tests NOT complete
    # (write_tests absent = not complete/skipped → guard blocks; readState fail-open)
    SID="g4-$$-$RANDOM"
    # Intentionally no seed — no state file exists for this sid.
    run_run_tests_hook "pytest tests/" 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" != "complete" ]; then
        pass "G4. no state file + exit=0 → run_tests NOT complete (write_tests absent), got: $STATUS"
    else
        fail "G4. no state file + exit=0 → expected NOT complete (write_tests absent), got: $STATUS"
    fi

    # G5: write_tests=pending + bash tests/foo.sh exit=1 → run_tests=pending + last_run_failed
    # (exit≠0 branch is unaffected by the guard — failures must still be recorded)
    SID="g5-$$-$RANDOM"
    seed_write_tests "$SID" "pending"
    run_run_tests_hook "bash tests/foo.sh" 1 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "G5. write_tests=pending + exit=1 → run_tests=pending (guard does not affect failure branch)"
    else
        fail "G5. write_tests=pending + exit=1 → expected run_tests=pending, got: $STATUS"
    fi
    G5_FAILED=$(node -e "
try {
  const s = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
  const rt = s.steps && s.steps.run_tests;
  console.log(rt && rt.last_run_failed === true ? 'yes' : 'no');
} catch(e) { console.log('no'); }
" "$WORKFLOW_DIR/$SID.json" 2>/dev/null || echo "no")
    if [ "$G5_FAILED" = "yes" ]; then
        pass "G5b. write_tests=pending + exit=1 → last_run_failed=true (failure branch intact)"
    else
        fail "G5b. write_tests=pending + exit=1 → expected last_run_failed=true, got: $G5_FAILED"
    fi
}
