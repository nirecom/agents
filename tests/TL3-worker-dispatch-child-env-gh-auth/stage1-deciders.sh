# Part of tests/TL3-worker-dispatch-child-env-gh-auth.sh — sourced, not run.
# Tests: bin/worker-dispatch/spawn.js, hooks/lib/worker-dispatch-registry.js
# Tags: worker-dispatch, child-env, config-path, gh-cli, auth-resolution, real-environment, TL3, scope:common
#
# stage1_deciders(): the two DECIDERS, checked against synthetic inputs.
#
# Everything outside this file is a real-environment measurement that can
# legally come out "we could not tell". What must never be
# environment-dependent is what the file DOES with such an answer — and that is
# decided entirely by classify() and exit_verdict(). Both are checked here on
# fabricated inputs, so the checks hold identically on a host where gh cannot
# authenticate at all and never depend on inducing a real timeout or a real
# spawn failure on demand.

stage1_deciders() {
    local _c _n _f _i _p _r _want
    local _sc_pass _sc_proven _sc_incon _sc_dpass _sc_dproven _sc_flag
    local _incon_cases _def_cases

    # Named once, used by all three branches below, so a case can never be
    # checked on one path and silently dropped on another.
    _incon_cases="timeout spawn-failure unrecognized-nonzero timeout-outranks-status-zero"
    _def_cases="authenticated not-logged-in no-accounts"

    # ===========================================================================
    # Stage 1 — the DECIDERS, checked deterministically before any gh runs.
    #
    # Everything below this block is a real-environment measurement that can legally
    # come out "we could not tell". What must never be environment-dependent is what
    # the file DOES with such an answer. Two mechanisms decide that, and both are
    # checked here against synthetic inputs so they hold on a host where gh cannot
    # authenticate at all:
    #   classify()     an unrecognized gh outcome must be `inconclusive`
    #   exit_verdict() an inconclusive required arm must be 77, never 0
    #
    # This block runs BEFORE every gate on purpose, and outranks all of them: a
    # host that will exit 77 at the RUN_TL3 gate, at a missing binary or at the
    # auth gate still gets its classifier and its exit arithmetic checked, and a
    # FAIL here exits the file 1 rather than 77.
    #
    # classify() lives inside the node probe, so node — and only node — is a real
    # precondition for that first group. Its absence SKIPS those rows; it never
    # passes them, and it never suppresses the two pure-shell groups after it.
    # ===========================================================================
    if [ "$HAVE_NODE" != "1" ]; then
        for _c in $_incon_cases; do
            skip "classify/$_c-is-inconclusive — node is not on PATH, the selftest probe cannot run"
        done
        for _c in $_def_cases; do
            skip "classify/$_c-is-definite — node is not on PATH, the selftest probe cannot run"
        done
        skip "classify/selftest-inconclusive-table-non-vacuous — node is not on PATH"
        skip "classify/selftest-definite-table-non-vacuous — node is not on PATH"
    elif run_probe classify-selftest synthetic; then
        # The three shapes that carry no verdict, plus the precedence case.
        for _c in $_incon_cases; do
            assert_eq "classify/$_c-is-inconclusive" "ok" "$(pv "SELF__$_c")"
        done
        # …and the definite classifications, so the rows above cannot pass merely
        # because classify() answers "inconclusive" to everything it is shown.
        for _c in $_def_cases; do
            assert_eq "classify/$_c-is-definite" "ok" "$(pv "SELF__$_c")"
        done
        assert_eq "classify/selftest-inconclusive-table-non-vacuous" "4" "$(pv selftest_inconclusive_count)"
        assert_eq "classify/selftest-definite-table-non-vacuous" "3" "$(pv selftest_definite_count)"
    else
        # node exists and the probe still did not complete — a real defect, not an
        # unready host.
        for _c in $_incon_cases; do
            fail "classify/$_c-is-inconclusive — selftest probe failed: $PROBE_OUT"
        done
        for _c in $_def_cases; do
            fail "classify/$_c-is-definite — selftest probe failed: $PROBE_OUT"
        done
        fail "classify/selftest-inconclusive-table-non-vacuous — selftest probe failed"
        fail "classify/selftest-definite-table-non-vacuous — selftest probe failed"
    fi

    # The exit arithmetic, on synthetic counters. Columns: name | FAIL | INCONCLUSIVE
    # | PROVEN | REQUIRED | expected exit code.
    while IFS='|' read -r _n _f _i _p _r _want; do
        _n="$(trim "$_n")"
        [ -z "$_n" ] && continue
        assert_eq "exitcode/$_n" "$(trim "$_want")" \
            "$(exit_verdict "$(trim "$_f")" "$(trim "$_i")" "$(trim "$_p")" "$(trim "$_r")")"
    done <<'TABLE'
    all-required-arms-proven        | 0 | 0 | 5 | 5 |  0
    required-arm-inconclusive       | 0 | 1 | 4 | 5 | 77
    proven-short-of-required        | 0 | 0 | 3 | 5 | 77
    nothing-proven-at-all           | 0 | 1 | 0 | 5 | 77
    a-fail-outranks-inconclusive    | 1 | 1 | 0 | 5 |  1
    a-fail-outranks-a-full-proof    | 2 | 0 | 5 | 5 |  1
TABLE

    # The same claim one level up: expect_class must not turn an inconclusive
    # observation into a pass or into a silent proof. Fed a synthetic probe output,
    # with the counters restored afterwards so the self-check leaves no residue in
    # the real run. (The SKIP line it prints is left counted — it really was
    # printed, and SKIP plays no part in the exit contract.)
    _sc_pass="$PASS"; _sc_proven="$PROVEN"; _sc_incon="$INCONCLUSIVE"
    PROBE_OUT="class=inconclusive
    status=7
    timedout=0"
    expect_class "selfcheck/synthetic-inconclusive-required-arm" "authenticated" 1
    # Deltas are captured, and the counters restored, BEFORE the asserts run —
    # otherwise the restore would discard the asserts' own PASS increments.
    _sc_dpass="$((PASS - _sc_pass))"
    _sc_dproven="$((PROVEN - _sc_proven))"
    _sc_flag="$INCONCLUSIVE"
    PASS="$_sc_pass"; PROVEN="$_sc_proven"; INCONCLUSIVE="$_sc_incon"
    assert_eq "expect-class/inconclusive-required-arm-never-passes" "0" "$_sc_dpass"
    assert_eq "expect-class/inconclusive-required-arm-is-not-proof" "0" "$_sc_dproven"
    assert_eq "expect-class/inconclusive-required-arm-sets-the-flag" "1" "$_sc_flag"
}
