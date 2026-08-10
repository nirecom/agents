# shellcheck shell=bash
# tests/feature-1665-run-outcome/g-outcome-tombstone.sh
# Tests: hooks/workflow-state/record-step-verdict.js, hooks/workflow-state/state-io/events.js
# Tags: workflow, run-outcome, record-step-verdict, tombstone, symmetry, TL1, scope:issue-specific
#
# TL1 — the state layer called directly, no hook subprocess.
#
# WHY (CPR-WPH): hooks/workflow-run-tests.js is not the only writer of run_tests.
# A human or a skill can settle the step through recordStepVerdict() — /run-tests
# advancing it, a skip judgment waiving it. If only the hook maintained the outcome
# axis, a declared `complete` would leave a stale run_outcome:"fail" behind it and
# the resume cascade would keep firing against a step the user has already settled.
#
# The rule (R4) is a symmetry, not a special case: a SETTLED transition must settle
# the outcome too, and an UNSETTLED one must leave it strictly alone.
#
#   complete    -> run_outcome "pass", provenance "declared" (a claim, not an
#                  observation — the distinction is why provenance exists)
#   skipped     -> run_outcome tombstoned to null (there is no outcome to have)
#   pending     -> untouched: the step is being re-opened, and the last observed
#   in_progress    outcome is exactly the evidence the re-open is based on
#
# `declared` vs `observed` matters downstream: a consumer that trusts only measured
# evidence can filter on provenance, which it cannot do if every writer claims
# "observed".

# _verdict <sid> <step> <status> — drive recordStepVerdict with gate "mark".
# gate "mark" is deliberate: it is not a DECLARING_GATE, so checkSkippableConstraint
# does not run and the `skipped` row below is reachable without staging a skip
# judgment. run_tests is absent from MANUAL_MARK_FORBIDDEN, so the call is legal.
_verdict() {
    run_with_timeout 30 node -e '
const m = require(process.argv[1] + "/hooks/workflow-state/record-step-verdict");
const fn = typeof m === "function" ? m : m.recordStepVerdict;
if (typeof fn !== "function") { process.stdout.write("ERR:no-recordStepVerdict"); process.exit(0); }
try { fn(process.argv[2], process.argv[3], process.argv[4], { gate: "mark" }); process.stdout.write("ok"); }
catch (e) { process.stdout.write("ERR:" + e.message); }
' "$AGENTS_WIN" "$1" "$2" "$3" 2>/dev/null || echo "ERR:crashed"
}

run_g_outcome_tombstone_cases() {
    echo ""
    echo "=== g-outcome-tombstone (TL1: settled transitions settle the outcome) ==="

    local rc

    # --- G0: run_outcome must be a sanctioned annotation key ---------------
    # validateEvent() rejects any step_annotation key outside STEP_ANNOTATION_KEYS,
    # so without this registration every write below fails at the storage layer.
    # Asserting it separately keeps a G1 failure readable: "not registered" and
    # "registered but not written" are different bugs (CPR-SC).
    local keys
    keys="$(run_with_timeout 30 node -e '
const { STEP_ANNOTATION_KEYS } = require(process.argv[1] + "/hooks/workflow-state/state-io/events");
process.stdout.write(Array.isArray(STEP_ANNOTATION_KEYS) ? STEP_ANNOTATION_KEYS.join(",") : "(absent)");
' "$AGENTS_WIN" 2>/dev/null || echo "(absent)")"
    assert_contains "G0/run_outcome-is-a-registered-annotation" "run_outcome" "$keys"

    # --- G1: complete -> declared pass -------------------------------------
    local sid="f1665-g1"
    seed_step "$sid" write_tests complete
    rc="$(_verdict "$sid" run_tests complete)"
    assert_eq "G1/call-succeeded" "ok" "$rc"
    assert_eq "G1/status-complete" "complete" "$(step_field "$sid" run_tests status)"
    assert_eq "G1/outcome-pass" "pass" "$(step_field "$sid" run_tests run_outcome)"
    assert_eq "G1/provenance-declared" "declared" \
        "$(annotation_provenance "$sid" run_tests run_outcome)"

    # --- G2: complete OVERWRITES a stale fail ------------------------------
    # The interesting direction: the user declaring the step done must win over an
    # older observation, otherwise the declaration cannot clear the cascade.
    local sid2="f1665-g2"
    seed_step "$sid2" write_tests complete
    seed_step "$sid2" run_tests pending run_outcome fail
    _verdict "$sid2" run_tests complete >/dev/null
    assert_eq "G2/stale-fail-overwritten" "pass" "$(step_field "$sid2" run_tests run_outcome)"

    # --- G3: skipped -> tombstoned to null ---------------------------------
    # A skipped step has no outcome at all — "pass" would be a lie and "fail" would
    # keep the cascade alive. Null is the only honest value.
    local sid3="f1665-g3"
    seed_step "$sid3" write_tests complete
    seed_step "$sid3" run_tests pending run_outcome fail
    assert_eq "G3/precondition-seeded" "fail" "$(step_field "$sid3" run_tests run_outcome)"
    _verdict "$sid3" run_tests skipped >/dev/null
    assert_eq "G3/status-skipped" "skipped" "$(step_field "$sid3" run_tests status)"
    assert_eq "G3/outcome-tombstoned" "(absent)" "$(step_field "$sid3" run_tests run_outcome)"

    # --- G4/G5: unsettled transitions PRESERVE the outcome ------------------
    # CPR-ORTH: both unsettled statuses, not just the one the plan names first.
    local st sid4
    for st in pending in_progress; do
        sid4="f1665-g4-$st"
        seed_step "$sid4" write_tests complete
        seed_step "$sid4" run_tests complete run_outcome fail
        _verdict "$sid4" run_tests "$st" >/dev/null
        assert_eq "G4/$st-status" "$st" "$(step_field "$sid4" run_tests status)"
        assert_eq "G4/$st-outcome-preserved" "fail" "$(step_field "$sid4" run_tests run_outcome)"
    done

    # --- G6: the axis is run_tests-specific --------------------------------
    # Settling ANOTHER step must not mint an outcome on it. run_outcome describes a
    # test run; no other step has one, and a blanket write would be a silent
    # widening of the annotation's meaning (CPR-NRS).
    local sid5="f1665-g6"
    _verdict "$sid5" write_tests complete >/dev/null
    assert_eq "G6/other-step-has-no-outcome" "(absent)" \
        "$(step_field "$sid5" write_tests run_outcome)"

    # --- G7: settling with no prior outcome is not an error -----------------
    # The tombstone path must be idempotent — skipping a never-run step writes a
    # null over nothing and must still leave the projection clean.
    local sid6="f1665-g7"
    seed_step "$sid6" write_tests complete
    _verdict "$sid6" run_tests skipped >/dev/null
    assert_eq "G7/no-prior-outcome-still-absent" "(absent)" \
        "$(step_field "$sid6" run_tests run_outcome)"
    assert_eq "G7/status-skipped" "skipped" "$(step_field "$sid6" run_tests status)"
}
