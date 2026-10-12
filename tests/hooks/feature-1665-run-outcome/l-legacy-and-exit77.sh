# shellcheck shell=bash
# tests/hooks/feature-1665-run-outcome/l-legacy-and-exit77.sh
# Tests: hooks/workflow-run-tests.js
# Tags: workflow, run-tests, run-outcome, run-contract, legacy-shape, exit-77, unrunnable, hook, TL2, scope:issue-specific
#
# TL2 — the hook against the legacy 4-field contract (#2501 C3) and run-all exit 77 (C1).
# WHY: 4 fields cannot prove UNRUNNABLE=0, so a legacy green run must pend on both routes and
# point at a rebase; a legacy FAIL>0 still records the failure. Exit 77 is "nothing ran", not a
# failure: pending, last_run_failed false, last_exit_code 77. EXPECTED RED until D5-3 lands.

L_LEGACY_GREEN_STDOUT="Running tests/alpha.sh
PASS: alpha

Results: PASS=5  FAIL=0  SKIP=0
RUN_CONTRACT: PASS=5 FAIL=0 SKIP=0 EXECUTED=5"

L_LEGACY_FAIL_STDOUT="Running tests/broken.sh
FAIL: tests/broken.sh (exit 1)

Results: PASS=2  FAIL=1  SKIP=0
RUN_CONTRACT: PASS=2 FAIL=1 SKIP=0 EXECUTED=3"

L_ALLSKIP_STDOUT="Running tests/alpha.sh
SKIP: alpha

Results: PASS=0  FAIL=0  SKIP=2  UNRUNNABLE=0  TIMEOUT=0
RUN_CONTRACT: PASS=0 FAIL=0 SKIP=2 EXECUTED=2 UNRUNNABLE=0 TIMEOUT=0"

L_UNRUN_STDOUT="Running tests/alpha.sh
PASS: alpha
UNRUNNABLE: tests/p.Tests.ps1 (missing: Pester>=5.0)
UNRUNNABLE: tests/q.Tests.ps1 (missing: Pester>=5.0)
Missing runtimes: Pester>=5.0 (2 files)

Results: PASS=3  FAIL=0  SKIP=0  UNRUNNABLE=2  TIMEOUT=0
RUN_CONTRACT: PASS=3 FAIL=0 SKIP=0 EXECUTED=3 UNRUNNABLE=2 TIMEOUT=0"

L_FAIL_UNRUN_STDOUT="Running tests/broken.sh
FAIL: tests/broken.sh (exit 1)
UNRUNNABLE: tests/p.Tests.ps1 (missing: Pester>=5.0)
Missing runtimes: Pester>=5.0 (1 files)

Results: PASS=2  FAIL=1  SKIP=0  UNRUNNABLE=1  TIMEOUT=0
RUN_CONTRACT: PASS=2 FAIL=1 SKIP=0 EXECUTED=3 UNRUNNABLE=1 TIMEOUT=0"

L_GREEN6_STDOUT="Running tests/alpha.sh
PASS: alpha

Results: PASS=5  FAIL=0  SKIP=0  UNRUNNABLE=0  TIMEOUT=0
RUN_CONTRACT: PASS=5 FAIL=0 SKIP=0 EXECUTED=5 UNRUNNABLE=0 TIMEOUT=0"

# _l_sysmsg <hook-stdout-json> -> the systemMessage string, or (none).
_l_sysmsg() {
    run_with_timeout 30 node -e '
let o = null;
try { o = JSON.parse(process.argv[1]); } catch (e) {}
process.stdout.write(o && typeof o.systemMessage === "string" ? o.systemMessage : "(none)");
' "$1" 2>/dev/null || echo "(none)"
}

# _l_expect_legacy_pending <label> <sid> <hook-stdout-json>
_l_expect_legacy_pending() {
    local msg
    msg="$(_l_sysmsg "$3")"
    assert_eq "$1/status-pending" "pending" "$(step_field "$2" run_tests status)"
    assert_contains "$1/reason-contract-legacy-shape" "(contract-legacy-shape)" "$msg"
    assert_contains "$1/message-asks-for-rebase" "rebase" "$msg"
    assert_eq "$1/outcome-withheld" "(absent)" "$(step_field "$2" run_tests run_outcome)"
    assert_eq "$1/unrunnable-count-null-for-legacy" "(absent)" "$(step_field "$2" run_tests unrunnable_count)"
}

run_l_legacy_and_exit77_cases() {
    echo ""
    echo "=== l-legacy-and-exit77 (TL2: legacy contract shape and run-all exit 77) ==="

    local sid out

    # --- L1/L2: legacy fail=0 pends on both routes --------------------------
    sid="f1665-l1"
    seed_step "$sid" write_tests complete
    out="$(drive_hook "$RUNALL_CMD" 0 "$sid" "$L_LEGACY_GREEN_STDOUT")"
    _l_expect_legacy_pending "L1/runall-legacy-green" "$sid" "$out"

    sid="f1665-l2"
    seed_step "$sid" write_tests complete
    out="$(drive_hook "$DISPATCH_CMD" 0 "$sid" \
        "$(_wd_payload "RUN_CONTRACT: PASS=5 FAIL=0 SKIP=0 EXECUTED=5" pass 0)")"
    _l_expect_legacy_pending "L2/worker-legacy-green" "$sid" "$out"

    # --- L3: worker status skip on a legacy contract names the legacy shape ---
    # The pass-only allowlist vetoes `skip`; the rebase guidance must still win.
    sid="f1665-l3"
    seed_step "$sid" write_tests complete
    out="$(drive_hook "$DISPATCH_CMD" 0 "$sid" \
        "$(_wd_payload "RUN_CONTRACT: PASS=0 FAIL=0 SKIP=2 EXECUTED=2" skip 77)")"
    _l_expect_legacy_pending "L3/worker-legacy-skip" "$sid" "$out"

    # --- L4: worker status skip on a current contract stays a status veto -----
    sid="f1665-l4"
    seed_step "$sid" write_tests complete
    out="$(drive_hook "$DISPATCH_CMD" 0 "$sid" \
        "$(_wd_payload "RUN_CONTRACT: PASS=0 FAIL=0 SKIP=2 EXECUTED=2 UNRUNNABLE=0 TIMEOUT=0" skip 77)")"
    assert_eq "L4/worker-current-skip-status-pending" "pending" "$(step_field "$sid" run_tests status)"
    assert_contains "L4/worker-current-skip-reason-worker-status-veto" "(worker-status-veto)" "$(_l_sysmsg "$out")"

    # --- L5: legacy FAIL>0 still records the failure ---------------------------
    sid="f1665-l5a"
    seed_step "$sid" write_tests complete
    drive_hook "$RUNALL_CMD" 1 "$sid" "$L_LEGACY_FAIL_STDOUT" >/dev/null
    assert_eq "L5a/runall-legacy-fail-status-pending" "pending" "$(step_field "$sid" run_tests status)"
    assert_eq "L5a/runall-legacy-fail-outcome-fail" "fail" "$(step_field "$sid" run_tests run_outcome)"
    assert_eq "L5a/runall-legacy-fail-last-run-failed" "true" "$(step_field "$sid" run_tests last_run_failed)"

    sid="f1665-l5b"
    seed_step "$sid" write_tests complete
    drive_hook "$DISPATCH_CMD" 0 "$sid" \
        "$(_wd_payload "RUN_CONTRACT: PASS=2 FAIL=1 SKIP=0 EXECUTED=3" fail 1)" >/dev/null
    assert_eq "L5b/worker-legacy-fail-outcome-fail" "fail" "$(step_field "$sid" run_tests run_outcome)"

    # --- L6: run-all exit 77 is "nothing ran", not a failed run ---------------
    sid="f1665-l6a"
    seed_step "$sid" write_tests complete
    out="$(drive_hook "$RUNALL_CMD" 77 "$sid" "$L_ALLSKIP_STDOUT")"
    assert_eq "L6a/exit77-status-pending" "pending" "$(step_field "$sid" run_tests status)"
    assert_eq "L6a/exit77-last-run-failed-false" "false" "$(step_field "$sid" run_tests last_run_failed)"
    assert_eq "L6a/exit77-last-exit-code-77" "77" "$(step_field "$sid" run_tests last_exit_code)"
    assert_ne "L6a/exit77-demotion-message-present" "(none)" "$(_l_sysmsg "$out")"

    # Control: exit 1 keeps the failed-run annotations.
    sid="f1665-l6b"
    seed_step "$sid" write_tests complete
    drive_hook "$RUNALL_CMD" 1 "$sid" "$L_LEGACY_FAIL_STDOUT" >/dev/null
    assert_eq "L6b/exit1-last-run-failed-true" "true" "$(step_field "$sid" run_tests last_run_failed)"
    assert_eq "L6b/exit1-last-exit-code-1" "1" "$(step_field "$sid" run_tests last_exit_code)"

    # --- L7: unrunnable_count annotation (decision 3) --------------------------
    sid="f1665-l7a"
    seed_step "$sid" write_tests complete
    drive_hook "$RUNALL_CMD" 0 "$sid" "$L_UNRUN_STDOUT" >/dev/null
    assert_eq "L7a/runall-pending-unrunnable-count-2" "2" "$(step_field "$sid" run_tests unrunnable_count)"

    sid="f1665-l7b"
    seed_step "$sid" write_tests complete
    drive_hook "$DISPATCH_CMD" 0 "$sid" \
        "$(_wd_payload "RUN_CONTRACT: PASS=3 FAIL=0 SKIP=0 EXECUTED=3 UNRUNNABLE=2 TIMEOUT=0" unrunnable 0)" >/dev/null
    assert_eq "L7b/worker-pending-unrunnable-count-2" "2" "$(step_field "$sid" run_tests unrunnable_count)"

    # A readable contract on the exit!=0 path still carries the count.
    sid="f1665-l7c"
    seed_step "$sid" write_tests complete
    drive_hook "$RUNALL_CMD" 1 "$sid" "$L_FAIL_UNRUN_STDOUT" >/dev/null
    assert_eq "L7c/runall-exit1-unrunnable-count-1" "1" "$(step_field "$sid" run_tests unrunnable_count)"

    # Complete tombstones the count left by an earlier pending run.
    sid="f1665-l7d"
    seed_step "$sid" write_tests complete
    drive_hook "$RUNALL_CMD" 0 "$sid" "$L_UNRUN_STDOUT" >/dev/null
    drive_hook "$RUNALL_CMD" 0 "$sid" "$L_GREEN6_STDOUT" >/dev/null
    assert_eq "L7d/complete-status" "complete" "$(step_field "$sid" run_tests status)"
    assert_eq "L7d/complete-unrunnable-count-null" "(absent)" "$(step_field "$sid" run_tests unrunnable_count)"
}
