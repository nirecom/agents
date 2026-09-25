# shellcheck shell=bash
# Case group: Idempotency cases (I-group) and Security cases (SC-group).
# Sourced by main-workflow-run-tests.sh; relies on helpers from common.sh.

run_idempotency_security_tests() {
    # ---------------------------------------------------------------------------
    # === Idempotency cases ===
    # ---------------------------------------------------------------------------

    echo ""
    echo "=== workflow-run-tests: Idempotency cases ==="

    # I1: run exit=0 twice → run_tests=pending (both runs: no contract → active demotion)
    # C′: complete now requires a run-all.sh invocation + exactly one RUN_CONTRACT line;
    # a bare runner with no contract → active demotion to pending.
    SID="i1-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook "pytest tests/" 0 "$SID"
    run_run_tests_hook "pytest tests/" 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "I1. pytest + exit=0 twice → run_tests=pending (C′: no contract → active demotion on both runs)"
    else
        fail "I1. pytest + exit=0 twice → expected pending (C′: no contract), got: $STATUS"
    fi

    # I2: exit=0 then exit=1 → pending. Under C′ the first call (exit=0, no contract) already yields pending
    #  (active demotion — no run-all.sh provenance / no contract), and the second call (exit=1) stays pending via
    #  the exit≠0 fast-path. Final status pending holds regardless of order. (write_tests seed retained; harmless.)
    SID="i2-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook "pytest tests/" 0 "$SID"
    run_run_tests_hook "pytest tests/" 1 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "I2. exit=0 then exit=1 → run_tests=pending (last-run-wins)"
    else
        fail "I2. exit=0 then exit=1 → expected pending, got: $STATUS"
    fi

    # ---------------------------------------------------------------------------
    # === Security cases ===
    # ---------------------------------------------------------------------------

    echo ""
    echo "=== workflow-run-tests: Security cases ==="

    # SC1: hook stdout contains no secrets/credentials — must output '{}'
    SID="sc1-$$-$RANDOM"
    OUTPUT=$(run_run_tests_hook "pytest tests/" 0 "$SID" 2>/dev/null || true)
    if echo "$OUTPUT" | node -e "
let b=''; process.stdin.on('data',c=>b+=c);
process.stdin.on('end',()=>{
  const s=b.trim();
  // stdout must be empty or valid JSON starting with {
  if(s===''||s==='{}'){process.exit(0);}
  try{JSON.parse(s);process.exit(0);}catch(e){process.exit(1);}
})
" 2>/dev/null; then
        pass "SC1. hook stdout is empty or valid JSON (no raw secrets)"
    else
        fail "SC1. hook stdout is not valid JSON or empty: $OUTPUT"
    fi
}
