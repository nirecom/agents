# shellcheck shell=bash
# tests/feature-1665-run-outcome/b-direct-run-failure.sh
# Tests: hooks/workflow-run-tests.js, hooks/workflow-run-tests/outcome.js
# Tags: workflow, run-outcome, run-all, contract-priority, hook, TL2, scope:issue-specific
#
# TL2 — real hook process, real workflow-state file. THE MANDATORY C1 CASE.
#
# WHY (CPR-WPH): tests/run-all.sh:65-66 emits a well-formed RUN_CONTRACT line and
# THEN exits 1 whenever FAIL>0. That is not an edge case — it is what an ordinary
# failing `bash tests/run-all.sh` looks like, i.e. the primary path of this whole
# feature. hooks/workflow-run-tests.js:276-283 currently takes a fast path on
# `exitCode !== 0` and returns before the contract is ever parsed. If the outcome
# axis is written from that fast path as "no trusted observation" (null), a normal
# test failure NEVER triggers the write_code resume and the feature is dead where
# it matters most.
#
# So the decision order is CONTRACT-PRIORITY, EXIT-CODE-SUBORDINATE:
#   outcome axis — decided by the trust conditions, exit code not consulted
#   status  axis — unchanged: non-zero exit ALWAYS reverts run_tests to pending
# This file pins both halves at once, because the risk of the lift (R2) is that
# fixing the outcome axis silently regresses the status axis.

# The exact stdout tests/run-all.sh produces on a failing run: the Results:
# summary, then the contract as the LAST non-empty line (which is what
# stdoutAttributed() requires of the run-all route).
B_FAILING_RUNALL_STDOUT="Running tests/alpha.sh
PASS: alpha
Running tests/broken.sh
FAIL: tests/broken.sh (exit 1)

Results: PASS=3  FAIL=2  SKIP=0
RUN_CONTRACT: PASS=3 FAIL=2 SKIP=0 EXECUTED=5"

B_GREEN_RUNALL_STDOUT="Running tests/alpha.sh
PASS: alpha

Results: PASS=5  FAIL=0  SKIP=0
RUN_CONTRACT: PASS=5 FAIL=0 SKIP=0 EXECUTED=5"

run_b_direct_run_failure_cases() {
    echo ""
    echo "=== b-direct-run-failure (TL2: C1 contract-priority) ==="

    # --- B1: the C1 primary path ------------------------------------------
    local sid="f1665-b1"
    seed_step "$sid" write_tests complete
    drive_hook "$RUNALL_CMD" 1 "$sid" "$B_FAILING_RUNALL_STDOUT" >/dev/null

    # status axis — UNCHANGED behaviour. A non-zero exit is a fail-safe and must
    # keep demoting, lift or no lift.
    assert_eq "B1/status-still-pending" "pending" "$(step_field "$sid" run_tests status)"
    assert_eq "B1/last_run_failed-recorded" "true" "$(step_field "$sid" run_tests last_run_failed)"
    assert_eq "B1/last_exit_code-recorded" "1" "$(step_field "$sid" run_tests last_exit_code)"

    # outcome axis — the run reported FAIL=2 about ITSELF. Recording that is the
    # whole point; discarding it because the process also exited 1 would throw away
    # the one observation the resume cascade triggers on.
    assert_eq "B1/run_outcome-is-fail" "fail" "$(step_field "$sid" run_tests run_outcome)"

    # Both axes must land in ONE markStep batch — status and outcome describing two
    # different observations is exactly the split the plan forbids.
    assert_eq "B1/single-batch-provenance" "observed" \
        "$(annotation_provenance "$sid" run_tests run_outcome)"

    # --- B2: the trigger command is still attributable ---------------------
    # #1378's diagnosis cost was a silent demotion; the lift must not drop it.
    assert_contains "B2/trigger_command-recorded" "run-all.sh" \
        "$(step_field "$sid" run_tests trigger_command)"

    # --- B3: symmetric counterpart — green contract, zero exit -------------
    # CPR-ORTH: cover the non-targeted verdict of the same classifier. A change
    # that makes every run "fail" would pass B1 alone.
    local sid2="f1665-b3"
    seed_step "$sid2" write_tests complete
    drive_hook "$RUNALL_CMD" 0 "$sid2" "$B_GREEN_RUNALL_STDOUT" >/dev/null
    assert_eq "B3/status-complete" "complete" "$(step_field "$sid2" run_tests status)"
    assert_eq "B3/run_outcome-is-pass" "pass" "$(step_field "$sid2" run_tests run_outcome)"
    assert_eq "B3/last_run_failed-tombstoned" "(absent)" \
        "$(step_field "$sid2" run_tests last_run_failed)"

    # --- B4: green contract but non-zero exit ------------------------------
    # The two axes disagree on purpose: the suite reported FAIL=0, the process
    # still died. Status must fail-safe to pending; outcome reports what the run
    # said. This row is what proves the two axes are genuinely independent rather
    # than one derived from the other.
    local sid3="f1665-b4"
    seed_step "$sid3" write_tests complete
    drive_hook "$RUNALL_CMD" 1 "$sid3" "$B_GREEN_RUNALL_STDOUT" >/dev/null
    assert_eq "B4/status-pending" "pending" "$(step_field "$sid3" run_tests status)"
    assert_eq "B4/run_outcome-is-pass" "pass" "$(step_field "$sid3" run_tests run_outcome)"
    assert_eq "B4/last_exit_code-recorded" "1" "$(step_field "$sid3" run_tests last_exit_code)"

    # --- B5: a stale complete is still actively demoted ---------------------
    local sid4="f1665-b5"
    seed_step "$sid4" write_tests complete
    seed_step "$sid4" run_tests complete
    drive_hook "$RUNALL_CMD" 1 "$sid4" "$B_FAILING_RUNALL_STDOUT" >/dev/null
    assert_eq "B5/stale-complete-demoted" "pending" "$(step_field "$sid4" run_tests status)"
    assert_eq "B5/run_outcome-is-fail" "fail" "$(step_field "$sid4" run_tests run_outcome)"
}
