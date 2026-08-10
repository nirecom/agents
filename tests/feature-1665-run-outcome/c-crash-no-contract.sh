# shellcheck shell=bash
# tests/feature-1665-run-outcome/c-crash-no-contract.sh
# Tests: hooks/workflow-run-tests.js, hooks/workflow-run-tests/outcome.js
# Tags: workflow, run-outcome, tombstone, fail-safe, hook, TL2, scope:issue-specific
#
# TL2 — real hook process, real workflow-state file.
#
# SCOPE PIN (read before changing b-direct-run-failure.sh): the approved outline's
# rule (3) — "a non-zero exit fail-safe writes NO outcome" — applies to THIS case
# and ONLY this case: a non-zero exit with NO contract at all (crash, interrupt,
# shell error, forced kill). It does NOT apply to a run that emitted a valid
# FAIL>0 contract and then exited 1; that run reported itself as failed and the
# report is kept (see b-direct-run-failure.sh B1). The clause's purpose is "do not
# fabricate an outcome for a failure nobody observed", not "discard an observed
# failure". This comment is the boundary between the two cases; if a future change
# makes B1 and C1 agree, one of them has been misread.
#
# The second half of this file pins the TOMBSTONE: null is not "leave the old value
# alone", it is "clear it". A stale run_outcome:"fail" surviving a later, silent run
# would keep the resume cascade firing forever on evidence that no longer exists.

C_CRASH_STDOUT="Running tests/alpha.sh
bash: line 1: node: command not found
tests/run-all.sh: line 40: syntax error near unexpected token"

run_c_crash_no_contract_cases() {
    echo ""
    echo "=== c-crash-no-contract (TL2: withhold + tombstone) ==="

    # --- C1: crash with no contract → no outcome --------------------------
    local sid="f1665-c1"
    seed_step "$sid" write_tests complete
    drive_hook "$RUNALL_CMD" 2 "$sid" "$C_CRASH_STDOUT" >/dev/null
    assert_eq "C1/status-pending" "pending" "$(step_field "$sid" run_tests status)"
    assert_eq "C1/last_exit_code-recorded" "2" "$(step_field "$sid" run_tests last_exit_code)"
    assert_eq "C1/run_outcome-withheld" "(absent)" "$(step_field "$sid" run_tests run_outcome)"

    # --- C2: an earlier outcome is TOMBSTONED, not inherited --------------
    local sid2="f1665-c2"
    seed_step "$sid2" write_tests complete
    seed_step "$sid2" run_tests pending run_outcome fail
    assert_eq "C2/precondition-outcome-seeded" "fail" "$(step_field "$sid2" run_tests run_outcome)"
    drive_hook "$RUNALL_CMD" 2 "$sid2" "$C_CRASH_STDOUT" >/dev/null
    assert_eq "C2/status-pending" "pending" "$(step_field "$sid2" run_tests status)"
    assert_eq "C2/stale-outcome-cleared" "(absent)" "$(step_field "$sid2" run_tests run_outcome)"

    # --- C3: the same clearing happens on the ACTIVE-DEMOTION path --------
    # Exit code 0 but no trusted contract (ad-hoc command / piped run-all). This is
    # the other route into "no trusted observation" and must clear symmetrically
    # (CPR-ORTH) — otherwise a green-exiting untrusted run preserves a stale fail.
    local sid3="f1665-c3"
    seed_step "$sid3" write_tests complete
    seed_step "$sid3" run_tests pending run_outcome fail
    drive_hook "$RUNALL_CMD" 0 "$sid3" "no contract in this output at all" >/dev/null
    assert_eq "C3/status-pending" "pending" "$(step_field "$sid3" run_tests status)"
    assert_eq "C3/contract_absent-flagged" "true" "$(step_field "$sid3" run_tests contract_absent)"
    assert_eq "C3/stale-outcome-cleared" "(absent)" "$(step_field "$sid3" run_tests run_outcome)"

    # --- C4: ambiguous contract (two lines) also clears -------------------
    # >=2 well-formed contract lines is the forged-append / fixture-collision case.
    # "Which one is the run's verdict?" has no answer, so neither may be recorded.
    local sid4="f1665-c4"
    seed_step "$sid4" write_tests complete
    seed_step "$sid4" run_tests pending run_outcome pass
    drive_hook "$RUNALL_CMD" 0 "$sid4" "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1
RUN_CONTRACT: PASS=3 FAIL=2 SKIP=0 EXECUTED=5" >/dev/null
    assert_eq "C4/status-pending" "pending" "$(step_field "$sid4" run_tests status)"
    assert_eq "C4/ambiguous-outcome-cleared" "(absent)" "$(step_field "$sid4" run_tests run_outcome)"

    # --- C5: the demotion diagnostic still reaches the human --------------
    # The systemMessage channel is the only place a silent demotion becomes
    # visible; the outcome axis must not have quietly replaced it.
    local msg
    msg="$(drive_hook "$RUNALL_CMD" 0 "f1665-c5" "no contract here")"
    assert_contains "C5/systemMessage-preserved" "run_tests demoted to pending" "$msg"
}
