# shellcheck shell=bash
# tests/feature-1665-run-outcome/e-write-tests-guard.sh
# Tests: hooks/workflow-run-tests.js
# Tags: workflow, run-outcome, write-tests-gate, fail-open, atomicity, hook, TL2, scope:issue-specific
#
# TL2 — real hook process, real workflow-state file.
#
# WHY (CPR-WPH): hooks/workflow-run-tests.js keeps the PR #1165 guard — run_tests
# may only reach `complete` when write_tests is already complete or skipped. When
# write_tests is unsatisfied the hook writes NOTHING and falls open.
#
# The outcome axis must inherit that silence rather than carve an exception. If the
# guard branch wrote only run_outcome, the state would hold "status: pending,
# outcome: pass" — two halves of one observation split across different batches,
# which is precisely the atomicity the design forbids. And absence of an outcome is
# "not observed", not "failed": the resume trigger keys on explicit values only, so
# fail-open here cannot cause a spurious resume.
#
# The assertion is on the EVENT COUNT, not on the projected status. `pending` is
# also the projection default for a step nobody wrote, so a status assertion alone
# cannot tell "nothing was written" from "pending was written".

E_GREEN_STDOUT="Running tests/alpha.sh
PASS: alpha

Results: PASS=5  FAIL=0  SKIP=0
RUN_CONTRACT: PASS=5 FAIL=0 SKIP=0 EXECUTED=5"

run_e_write_tests_guard_cases() {
    echo ""
    echo "=== e-write-tests-guard (TL2: neither axis is written) ==="

    # --- E1: write_tests pending, contract perfectly valid ----------------
    local sid="f1665-e1" before after
    seed_step "$sid" write_tests pending
    before="$(event_count "$sid")"
    assert_ne "E1/precondition-state-exists" "0" "$before"

    drive_hook "$RUNALL_CMD" 0 "$sid" "$E_GREEN_STDOUT" >/dev/null
    after="$(event_count "$sid")"

    assert_eq "E1/no-events-appended" "$before" "$after"
    assert_eq "E1/status-not-written" "pending" "$(step_field "$sid" run_tests status)"
    assert_eq "E1/outcome-not-written" "(absent)" "$(step_field "$sid" run_tests run_outcome)"

    # --- E2: same, with write_tests in_progress ---------------------------
    # in_progress is not settled, so the guard is equally unsatisfied. Covering it
    # keeps the guard's boundary at SETTLED_STATUSES rather than at "not pending".
    local sid2="f1665-e2"
    seed_step "$sid2" write_tests in_progress
    before="$(event_count "$sid2")"
    drive_hook "$RUNALL_CMD" 0 "$sid2" "$E_GREEN_STDOUT" >/dev/null
    assert_eq "E2/no-events-appended" "$before" "$(event_count "$sid2")"
    assert_eq "E2/outcome-not-written" "(absent)" "$(step_field "$sid2" run_tests run_outcome)"

    # --- E3: a pre-existing outcome survives the fail-open ----------------
    # Withholding must mean "write nothing", not "clear it": the guard branch never
    # observed this run, so it has no standing to tombstone an earlier observation.
    local sid3="f1665-e3"
    seed_step "$sid3" write_tests pending
    seed_step "$sid3" run_tests pending run_outcome fail
    before="$(event_count "$sid3")"
    drive_hook "$RUNALL_CMD" 0 "$sid3" "$E_GREEN_STDOUT" >/dev/null
    assert_eq "E3/no-events-appended" "$before" "$(event_count "$sid3")"
    assert_eq "E3/prior-outcome-untouched" "fail" "$(step_field "$sid3" run_tests run_outcome)"

    # --- E4: control — write_tests skipped satisfies the guard ------------
    # CPR-ORTH: the guard's other sanctioned verdict. Both axes are written here,
    # which is what proves E1-E3 measured a guard and not a broken fixture.
    local sid4="f1665-e4"
    seed_step "$sid4" write_tests skipped
    before="$(event_count "$sid4")"
    drive_hook "$RUNALL_CMD" 0 "$sid4" "$E_GREEN_STDOUT" >/dev/null
    assert_ne "E4/events-appended" "$before" "$(event_count "$sid4")"
    assert_eq "E4/status-complete" "complete" "$(step_field "$sid4" run_tests status)"
    assert_eq "E4/outcome-pass" "pass" "$(step_field "$sid4" run_tests run_outcome)"

    # --- E5: the guard does NOT suppress the demotion paths ---------------
    # Only the complete path is guarded. A demotion with write_tests unsatisfied
    # still writes — that is pre-existing behaviour the lift must not change.
    local sid5="f1665-e5"
    seed_step "$sid5" write_tests pending
    before="$(event_count "$sid5")"
    drive_hook "$RUNALL_CMD" 1 "$sid5" "$E_GREEN_STDOUT" >/dev/null
    assert_ne "E5/demotion-still-writes" "$before" "$(event_count "$sid5")"
    assert_eq "E5/status-pending" "pending" "$(step_field "$sid5" run_tests status)"
    assert_eq "E5/outcome-recorded" "pass" "$(step_field "$sid5" run_tests run_outcome)"
}
