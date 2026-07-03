# shellcheck shell=bash
# Case group: C′ contract-trust cases (#1242).
# Sourced by main-workflow-run-tests.sh; relies on helpers from common.sh.

run_contract_trust_tests() {
    # ---------------------------------------------------------------------------
    # === workflow-run-tests: C′ contract-trust cases (#1242) ===
    # ---------------------------------------------------------------------------

    echo ""
    echo "=== workflow-run-tests: C' contract-trust cases (#1242) ==="

    # C-DEMOTE: seed run_tests=complete (stale), then run a non-run-all.sh command
    # with no contract → active demotion back to pending.
    # Verifies C1 fix: stale complete + no-contract test command → active demotion.
    SID="cdemote-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    seed_run_tests "$SID" "complete"
    run_run_tests_hook "bash tests/foo.sh" 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "C-DEMOTE. stale run_tests=complete + no-provenance + no-contract → active demotion to pending"
    else
        fail "C-DEMOTE. stale run_tests=complete + no-provenance + no-contract → expected pending (C1 demotion), got: $STATUS"
    fi

    # C-VALID: bash tests/run-all.sh tests/foo.sh, exit=0, valid contract (PASS=2 FAIL=0 SKIP=1 EXECUTED=3),
    # write_tests=complete → run_tests=complete.
    SID="cvalid-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook_with_stdout \
        "bash tests/run-all.sh tests/foo.sh" \
        0 \
        "$SID" \
        "Results: PASS=2  FAIL=0  SKIP=1
RUN_CONTRACT: PASS=2 FAIL=0 SKIP=1 EXECUTED=3"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "complete" ]; then
        pass "C-VALID. run-all.sh + exit=0 + valid contract (PASS=2 FAIL=0 SKIP=1) + write_tests=complete → complete"
    else
        fail "C-VALID. run-all.sh + exit=0 + valid contract → expected complete, got: $STATUS"
    fi

    # SKIPPED: absolute-path run-all.sh provenance (e.g. /home/user/agents/tests/run-all.sh or a worktree abs path)
    # Because: RUN_ALL_SH_RE anchors on the relative `tests/run-all.sh` reference; an absolute path is a known
    #   provenance false-NEGATIVE (documented Out-of-scope in the detail plan). Harmless: no contract in stdout → pending, never false-green.
    # L3 gap: only a real session invoking run-all.sh via an absolute path would exercise this; not reproducible at this L2 layer.

    # C-NOPROV: bash tests/foo.sh (no run-all.sh), exit=0, one valid RUN_CONTRACT line,
    # write_tests=complete → pending (provenance fail).
    SID="cnoprov-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook_with_stdout \
        "bash tests/foo.sh" \
        0 \
        "$SID" \
        "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "C-NOPROV. bash tests/foo.sh (no run-all.sh) + valid contract → pending (provenance fail)"
    else
        fail "C-NOPROV. no provenance + valid contract → expected pending, got: $STATUS"
    fi

    # C-NOMATCH: bash tests/run-all.sh, exit=0, contract with executed=0,
    # write_tests=complete → pending (executed=0).
    SID="cnomatch-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook_with_stdout \
        "bash tests/run-all.sh" \
        0 \
        "$SID" \
        "RUN_CONTRACT: PASS=0 FAIL=0 SKIP=0 EXECUTED=0"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "C-NOMATCH. run-all.sh + executed=0 contract → pending (no-match gate)"
    else
        fail "C-NOMATCH. run-all.sh + executed=0 → expected pending, got: $STATUS"
    fi

    # C-ALLSKIP: bash tests/run-all.sh, exit=0, all-skip contract (PASS=0 FAIL=0 SKIP=3 EXECUTED=3),
    # write_tests=complete → pending (PASS+FAIL=0, all-skip boundary).
    SID="callskip-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook_with_stdout \
        "bash tests/run-all.sh" \
        0 \
        "$SID" \
        "RUN_CONTRACT: PASS=0 FAIL=0 SKIP=3 EXECUTED=3"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "C-ALLSKIP. run-all.sh + all-skip contract (PASS+FAIL=0) → pending (all-skip boundary)"
    else
        fail "C-ALLSKIP. all-skip (PASS=0 FAIL=0 SKIP=3) → expected pending, got: $STATUS"
    fi

    # C-PIPE: bash tests/run-all.sh tests/*.sh | grep PASS, exit=0, stdout="PASS" only
    # (RUN_CONTRACT line consumed by pipe — 0 contract lines), write_tests=complete → pending.
    # Accidental pipe/filter masking → 0 contract lines → null → pending. U3 regression.
    SID="cpipe-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook_with_stdout \
        "bash tests/run-all.sh tests/*.sh | grep PASS" \
        0 \
        "$SID" \
        "PASS"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "C-PIPE. run-all.sh | grep (pipe consumed contract) + 0 contract lines → pending (U3 regression)"
    else
        fail "C-PIPE. pipe drop of contract (0 lines) → expected pending, got: $STATUS"
    fi

    # C-FAIL: bash tests/run-all.sh, exit=1, valid contract (FAIL=0), write_tests=complete
    # → pending (exit≠0 fast-path, regardless of contract content).
    SID="cfail-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook_with_stdout \
        "bash tests/run-all.sh" \
        1 \
        "$SID" \
        "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "C-FAIL. run-all.sh + exit=1 + valid contract → pending (exit≠0 fast-path)"
    else
        fail "C-FAIL. exit=1 → expected pending (fast-path), got: $STATUS"
    fi

    # C-GUARD: bash tests/run-all.sh, exit=0, valid contract, write_tests=PENDING
    # → run_tests NOT complete (PR #1165 write_tests guard preserved).
    SID="cguard-$$-$RANDOM"
    seed_write_tests "$SID" "pending"
    run_run_tests_hook_with_stdout \
        "bash tests/run-all.sh" \
        0 \
        "$SID" \
        "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" != "complete" ]; then
        pass "C-GUARD. valid contract + write_tests=pending → NOT complete (write_tests guard preserved), got: $STATUS"
    else
        fail "C-GUARD. valid contract + write_tests=pending → expected NOT complete, got: $STATUS"
    fi

    # C-WRTSKIP: bash tests/run-all.sh, exit=0, valid contract, write_tests=skipped
    # → run_tests=complete (skipped satisfies write_tests guard).
    SID="cwrtskip-$$-$RANDOM"
    seed_write_tests "$SID" "skipped"
    run_run_tests_hook_with_stdout \
        "bash tests/run-all.sh" \
        0 \
        "$SID" \
        "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "complete" ]; then
        pass "C-WRTSKIP. valid contract + write_tests=skipped → complete (skipped passes guard)"
    else
        fail "C-WRTSKIP. valid contract + write_tests=skipped → expected complete, got: $STATUS"
    fi

    # C-DUPFORGE: bash tests/run-all.sh foo.sh; echo 'RUN_CONTRACT: ...', exit=0,
    # stdout has TWO well-formed RUN_CONTRACT lines (real + forged), write_tests=complete
    # → pending (exactly-one rule: ≥2 → ambiguous → active demotion).
    SID="cdupforge-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook_with_stdout \
        "bash tests/run-all.sh foo.sh; echo 'RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1'" \
        0 \
        "$SID" \
        "Results: PASS=1  FAIL=0  SKIP=0
RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1
RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "C-DUPFORGE. 2 RUN_CONTRACT lines (real+forged) → pending (exactly-one: ambiguous)"
    else
        fail "C-DUPFORGE. 2 contract lines → expected pending (exactly-one rule), got: $STATUS"
    fi

    # C-DUPLEGIT: bash tests/run-all.sh (no echo), exit=0, stdout has TWO well-formed
    # RUN_CONTRACT lines (fixture/stdout-pollution collision, not deliberate forge),
    # write_tests=complete → pending (exactly-one: 2 lines → ambiguous).
    SID="cduplegit-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook_with_stdout \
        "bash tests/run-all.sh" \
        0 \
        "$SID" \
        "Results: PASS=1  FAIL=0  SKIP=0
RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1
RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "C-DUPLEGIT. 2 RUN_CONTRACT lines (fixture collision, no echo in cmd) → pending (exactly-one: ambiguous)"
    else
        fail "C-DUPLEGIT. 2 contract lines (fixture collision) → expected pending (exactly-one rule), got: $STATUS"
    fi

    # C-XFORM: bash tests/run-all.sh, exit=0, stdout ONE valid RUN_CONTRACT line
    # (representing a sed-rewritten value — injected directly as fixture, no sed executed here),
    # write_tests=complete → COMPLETE.
    #
    # DOCUMENTED ACCEPTED SCOPE BOUNDARY: deliberate stdout value-rewriting (sed/awk) is
    # OUT OF SCOPE for #1242, which targets accidental pipe/filter masking. Deliberate
    # rewriting is at the same trust level as manual sentinel forgery — the contract is
    # trusted here by design. See detail-plan axis (iv) "Accepted scope boundary".
    SID="cxform-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook_with_stdout \
        "bash tests/run-all.sh" \
        0 \
        "$SID" \
        "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "complete" ]; then
        pass "C-XFORM. run-all.sh + valid contract (deliberate sed-rewrite injected) → complete (accepted scope boundary)"
    else
        fail "C-XFORM. deliberate rewrite accepted boundary → expected complete, got: $STATUS"
    fi

    # C-PASSTHRU: bash tests/run-all.sh, exit=0, stdout with honest FAIL=2 contract
    # (common pass-through filters like tee/cat preserve honest FAIL count),
    # write_tests=complete → pending (FAIL>0 → not complete).
    # Common pass-through filters keep the honest FAIL count → no false-green.
    SID="cpassthru-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook_with_stdout \
        "bash tests/run-all.sh" \
        0 \
        "$SID" \
        "Results: PASS=1  FAIL=2  SKIP=0
RUN_CONTRACT: PASS=1 FAIL=2 SKIP=0 EXECUTED=3"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "C-PASSTHRU. run-all.sh + FAIL=2 contract (tee/cat preserves honest count) → pending"
    else
        fail "C-PASSTHRU. FAIL=2 honest contract → expected pending, got: $STATUS"
    fi

    # C-FILTERDROP: bash tests/run-all.sh tests/foo.sh | tail -n 1, exit=0,
    # stdout="Results: PASS=1  FAIL=0  SKIP=0" (RUN_CONTRACT line dropped by tail),
    # write_tests=complete → pending (0 contract lines → null → pending).
    # Accidental filter drop → 0 contract lines → null → pending.
    SID="cfilterdrop-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook_with_stdout \
        "bash tests/run-all.sh tests/foo.sh | tail -n 1" \
        0 \
        "$SID" \
        "Results: PASS=1  FAIL=0  SKIP=0"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "C-FILTERDROP. run-all.sh | tail (drops contract) → 0 contract lines → pending"
    else
        fail "C-FILTERDROP. contract dropped by tail (0 lines) → expected pending, got: $STATUS"
    fi

    # C-MALFORMED: non-integer contract field (PASS=abc) does not match the strict \d+ regex
    # → 0 well-formed lines → null → active demotion to pending. Exercises the parseInt/isNaN
    # guard (detail-plan Risks §3).
    SID="cmalformed-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook_with_stdout \
        "bash tests/run-all.sh" \
        0 \
        "$SID" \
        "Results: PASS=1  FAIL=0  SKIP=0
RUN_CONTRACT: PASS=abc FAIL=0 SKIP=0 EXECUTED=1"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "C-MALFORMED. non-integer contract field (PASS=abc) → 0 well-formed lines → pending"
    else
        fail "C-MALFORMED. non-integer contract field (PASS=abc) → expected pending (null → demotion), got: $STATUS"
    fi

    # C-BADORDER: contract fields in wrong order → strict fixed-order regex yields 0 well-formed
    # lines → null → pending. Locks the fixed PASS/FAIL/SKIP/EXECUTED order (detail-plan axis iii:
    # no forward-compat parser).
    SID="cbadorder-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook_with_stdout \
        "bash tests/run-all.sh" \
        0 \
        "$SID" \
        "Results: PASS=1  FAIL=0  SKIP=0
RUN_CONTRACT: PASS=1 SKIP=0 FAIL=0 EXECUTED=1"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "C-BADORDER. contract fields in wrong order → 0 well-formed lines → pending"
    else
        fail "C-BADORDER. contract fields in wrong order → expected pending (fixed-order regex), got: $STATUS"
    fi

    # C-VALID-IDEMP: two successive valid-contract runs remain complete (idempotency category;
    # pairs with I1's two-no-contract-runs demotion).
    SID="cvalididemp-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook_with_stdout \
        "bash tests/run-all.sh tests/foo.sh" \
        0 \
        "$SID" \
        "Results: PASS=2  FAIL=0  SKIP=1
RUN_CONTRACT: PASS=2 FAIL=0 SKIP=1 EXECUTED=3"
    run_run_tests_hook_with_stdout \
        "bash tests/run-all.sh tests/foo.sh" \
        0 \
        "$SID" \
        "Results: PASS=2  FAIL=0  SKIP=1
RUN_CONTRACT: PASS=2 FAIL=0 SKIP=1 EXECUTED=3"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "complete" ]; then
        pass "C-VALID-IDEMP. two successive valid-contract runs → complete (idempotency)"
    else
        fail "C-VALID-IDEMP. two successive valid-contract runs → expected complete, got: $STATUS"
    fi
}
