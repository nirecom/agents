# shellcheck shell=bash
# tests/hooks/feature-1665-run-outcome/m-unrunnable-accept-annotations.sh
# Tests: hooks/workflow-run-tests.js
# Tags: workflow, run-tests, run-outcome, run-contract, unrunnable, escape-hatch, tombstone, hook, TL2, scope:issue-specific
#
# TL2 — the hook's side of the UNRUNNABLE escape hatch (#2501 D5-7). The handler reads the
# runtimes the hook recorded (CPR-SSOT), so a contract-unrunnable pending run writes
# unrunnable_runtimes from `Missing runtimes:`; an accept covers one run, so the next run
# tombstones completion_basis and both accept annotations. EXPECTED RED until D5-4/D5-7 land.

M_UNRUN_STDOUT="Running tests/alpha.sh
PASS: alpha
UNRUNNABLE: tests/p.Tests.ps1 (missing: Pester>=5.0)
UNRUNNABLE: tests/q.Tests.ps1 (missing: Pester>=5.0)
Missing runtimes: Pester>=5.0 (2 files)

Results: PASS=3  FAIL=0  SKIP=0  UNRUNNABLE=2  TIMEOUT=0
RUN_CONTRACT: PASS=3 FAIL=0 SKIP=0 EXECUTED=3 UNRUNNABLE=2 TIMEOUT=0"

M_UNRUN2_STDOUT="Running tests/alpha.sh
PASS: alpha
UNRUNNABLE: tests/p.Tests.ps1 (missing: Pester>=5.0)
UNRUNNABLE: tests/q.Tests.ps1 (missing: Pester>=5.0)
UNRUNNABLE: tests/r_test.py (missing: uv)
Missing runtimes: Pester>=5.0 (2 files), uv (1 file)

Results: PASS=3  FAIL=0  SKIP=0  UNRUNNABLE=3  TIMEOUT=0
RUN_CONTRACT: PASS=3 FAIL=0 SKIP=0 EXECUTED=3 UNRUNNABLE=3 TIMEOUT=0"

M_GREEN6_STDOUT="Running tests/alpha.sh
PASS: alpha

Results: PASS=5  FAIL=0  SKIP=0  UNRUNNABLE=0  TIMEOUT=0
RUN_CONTRACT: PASS=5 FAIL=0 SKIP=0 EXECUTED=5 UNRUNNABLE=0 TIMEOUT=0"

M_FAIL_STDOUT="Running tests/broken.sh
FAIL: tests/broken.sh (exit 1)

Results: PASS=2  FAIL=1  SKIP=0  UNRUNNABLE=0  TIMEOUT=0
RUN_CONTRACT: PASS=2 FAIL=1 SKIP=0 EXECUTED=3 UNRUNNABLE=0 TIMEOUT=0"

# _m_worker_unrunnable — a worker payload whose summary carries the `Missing runtimes:` line,
# as test-runner.js composes it (fix-1378 U1).
_m_worker_unrunnable() {
    printf '%s\n' "RUN_CONTRACT: PASS=3 FAIL=0 SKIP=0 EXECUTED=3 UNRUNNABLE=2 TIMEOUT=0"
    printf 'status: unrunnable\n'
    printf 'exit_code: 0\n'
    printf 'duration_seconds: 4\n'
    printf "summary: 'Missing runtimes: Pester>=5.0 (2 files); PASS=3 FAIL=0 SKIP=0 UNRUNNABLE=2'\n"
    printf 'failing_tests: []\n'
    printf 'log_tail: |\n'
    printf '  PASS: alpha\n'
}

# _m_worker_missing_files <summary> <unrunnable> — a worker payload whose summary leads with the
# `Missing test files: N; ` token test-runner.js prefixes when a selected test file is gone (#2646).
_m_worker_missing_files() {
    printf '%s\n' "RUN_CONTRACT: PASS=3 FAIL=0 SKIP=0 EXECUTED=3 UNRUNNABLE=$2 TIMEOUT=0"
    printf 'status: unrunnable\n'
    printf 'exit_code: 0\n'
    printf 'duration_seconds: 4\n'
    printf "summary: '%s'\n" "$1"
    printf 'failing_tests: []\n'
    printf 'log_tail: |\n'
    printf '  PASS: alpha\n'
}

# _m_seed_accepted <sid> — run_tests as the accept handler leaves it.
_m_seed_accepted() {
    seed_step "$1" write_tests complete
    seed_step "$1" run_tests complete completion_basis unrunnable-accepted
    seed_step "$1" run_tests complete unrunnable_runtimes "Pester>=5.0"
    seed_step "$1" run_tests complete unrunnable_accept_reason "Pester 5 cannot be installed here"
}

run_m_unrunnable_accept_annotations_cases() {
    echo ""
    echo "=== m-unrunnable-accept-annotations (TL2: runtimes recorded, accept cleared by the next run) ==="

    local sid

    # --- M1: a contract-unrunnable pending run records the runtime labels ----
    sid="f1665-m1a"
    seed_step "$sid" write_tests complete
    drive_hook "$RUNALL_CMD" 0 "$sid" "$M_UNRUN_STDOUT" >/dev/null
    assert_eq "M1a/runall-status-pending" "pending" "$(step_field "$sid" run_tests status)"
    assert_eq "M1a/runall-runtimes-one-label" "Pester>=5.0" "$(step_field "$sid" run_tests unrunnable_runtimes)"

    sid="f1665-m1b"
    seed_step "$sid" write_tests complete
    drive_hook "$RUNALL_CMD" 0 "$sid" "$M_UNRUN2_STDOUT" >/dev/null
    assert_eq "M1b/runall-runtimes-two-labels-in-line-order" "Pester>=5.0,uv" \
        "$(step_field "$sid" run_tests unrunnable_runtimes)"

    sid="f1665-m1c"
    seed_step "$sid" write_tests complete
    drive_hook "$DISPATCH_CMD" 0 "$sid" "$(_m_worker_unrunnable)" >/dev/null
    assert_eq "M1c/worker-runtimes-from-summary" "Pester>=5.0" "$(step_field "$sid" run_tests unrunnable_runtimes)"
    assert_eq "M1c/worker-no-token-missing-files-zero" "0" "$(step_field "$sid" run_tests unrunnable_missing_files)"

    # A green run has no runtimes to record.
    sid="f1665-m1d"
    seed_step "$sid" write_tests complete
    drive_hook "$RUNALL_CMD" 0 "$sid" "$M_GREEN6_STDOUT" >/dev/null
    assert_eq "M1d/green-no-runtimes" "(absent)" "$(step_field "$sid" run_tests unrunnable_runtimes)"

    # #2646: the worker summary's leading `Missing test files: N; ` token is recorded as the
    # count, and the runtimes after it are still read through the same capture group.
    sid="f1665-m1e"
    seed_step "$sid" write_tests complete
    drive_hook "$DISPATCH_CMD" 0 "$sid" "$(_m_worker_missing_files \
        'Missing test files: 2; Missing runtimes: Pester>=5.0 (1 file); PASS=3 FAIL=0 SKIP=0 UNRUNNABLE=3' 3)" >/dev/null
    assert_eq "M1e/worker-token-status-pending" "pending" "$(step_field "$sid" run_tests status)"
    assert_eq "M1e/worker-token-missing-files" "2" "$(step_field "$sid" run_tests unrunnable_missing_files)"
    assert_eq "M1e/worker-token-runtimes-kept" "Pester>=5.0" "$(step_field "$sid" run_tests unrunnable_runtimes)"

    # Every UNRUNNABLE is a missing file: the token alone carries the count, no runtimes recorded.
    sid="f1665-m1f"
    seed_step "$sid" write_tests complete
    drive_hook "$DISPATCH_CMD" 0 "$sid" "$(_m_worker_missing_files \
        'Missing test files: 2; PASS=3 FAIL=0 SKIP=0 UNRUNNABLE=2' 2)" >/dev/null
    assert_eq "M1f/token-only-missing-files" "2" "$(step_field "$sid" run_tests unrunnable_missing_files)"
    assert_eq "M1f/token-only-no-runtimes" "(absent)" "$(step_field "$sid" run_tests unrunnable_runtimes)"

    # --- M2: the next run clears an earlier accept, whatever its outcome ------
    sid="f1665-m2-seed"
    _m_seed_accepted "$sid"
    assert_eq "M2/fixture-seed-took" "unrunnable-accepted" "$(step_field "$sid" run_tests completion_basis)"

    local label code out_var stdout want_runtimes
    while IFS='|' read -r label code out_var want_runtimes; do
        [ -n "$label" ] || continue
        sid="f1665-m2-$label"
        _m_seed_accepted "$sid"
        stdout="${!out_var}"
        drive_hook "$RUNALL_CMD" "$code" "$sid" "$stdout" >/dev/null
        assert_eq "M2/$label-completion-basis-cleared" "(absent)" "$(step_field "$sid" run_tests completion_basis)"
        assert_eq "M2/$label-accept-reason-cleared" "(absent)" "$(step_field "$sid" run_tests unrunnable_accept_reason)"
        assert_eq "M2/$label-runtimes" "$want_runtimes" "$(step_field "$sid" run_tests unrunnable_runtimes)"
    done <<'ROWS'
green|0|M_GREEN6_STDOUT|(absent)
fail-exit1|1|M_FAIL_STDOUT|(absent)
unrunnable-again|0|M_UNRUN2_STDOUT|Pester>=5.0,uv
ROWS
}
