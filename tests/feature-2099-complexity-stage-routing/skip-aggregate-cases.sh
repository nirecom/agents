#!/bin/bash
# tests/feature-2099-complexity-stage-routing/skip-aggregate-cases.sh
# Tests: hooks/workflow-state/skip-signal-resolver.js, hooks/workflow-state/skip-signal-resolver/complexity.js, hooks/workflow-state/skip-signal-resolver/condition-schemas.js, hooks/workflow-state/state-io/projection.js
# Tags: complexity, routing, skip-conditions, back-compat, scope:issue-specific
# Sourced by ../feature-2099-complexity-stage-routing.sh — helpers come from there.

# --- SA: skip resolution reads the AGGREGATE, never a per-stage level --------
# #2099 adds `levels`, but skip eligibility keeps its legacy meaning:
# level === "low" AND signals is empty (detail.md D3). A resolver that reaches
# into `levels` instead would change which sessions skip — invisible to every
# case where the two agree, so every fixture below makes them DISAGREE.
d2099s_resolve() {
    local sid="$1" target="$2"
    RESOLVER="$RESOLVER_N" SID="$sid" TARGET="$target" run_with_timeout node -e '
const r = require(process.env.RESOLVER);
const v = r.resolveSkipConditionsFromComplexity(process.env.SID, process.env.TARGET);
if (v === null || v === undefined) { console.log("NOT_ELIGIBLE"); }
else if (typeof v !== "object") { console.log("BAD_SHAPE:" + typeof v); }
else if (Object.keys(v).length === 0) { console.log("EMPTY_OBJECT"); }
else if (Object.values(v).every(function (x) { return x === true; })) { console.log("ELIGIBLE"); }
else { console.log("PARTIAL:" + JSON.stringify(v)); }
' 2>/dev/null
}

# Inject a record whose aggregate and per-stage fields point opposite ways, then
# prove the injection survived the projection before asserting on it.
d2099s_seed() {
    local sid="$1" raw="$2" projected
    d2099_inject_raw_event "$sid" "$raw" >/dev/null 2>&1
    projected=$(d2099_projected_ce "$sid")
    case "$projected" in
        __NO_STATE__|null|"") echo "SEED_LOST" ;;
        *) echo "SEEDED" ;;
    esac
}

# Every expectation below is conditional on the fixture existing: with no record
# at all the resolver answers NOT_ELIGIBLE for its own reason, which would make
# the negative cases pass while testing nothing.
d2099s_assert() {
    local desc="$1" seeded="$2" want="$3" got="$4"
    if [ "$seeded" != "SEEDED" ]; then
        fail "$desc — unattributable: the fixture record never reached the projection ($seeded)"
    else
        assert_eq "$desc" "$want" "$got"
    fi
}

# SA-1/SA-2: aggregate says skip-eligible, every per-stage level says high. The
# legacy rule owns this decision, so both targets must still be eligible.
d2099s_aggregate_low_beats_stage_high() {
    local sid t seeded
    sid=$(new_session saggr1)
    seeded=$(d2099s_seed "$sid" \
        '{"level":"low","signals":[],"levels":{"detail":"high","write_tests":"high","write_code":"high"}}')
    assert_eq "SA-0 the disagreeing record survives the projection (else the cases below are vacuous)" \
        "SEEDED" "$seeded"

    for t in outline detail; do
        d2099s_assert "SA-1 [$t] aggregate level=low + no signals stays skip-eligible even with every stage high" \
            "$seeded" "ELIGIBLE" "$(d2099s_resolve "$sid" "$t")"
    done
}

# SA-3/SA-4: the inverse. Aggregate says not eligible while every per-stage level
# reads low — a resolver consulting `levels` would wrongly grant the skip.
d2099s_aggregate_high_beats_stage_low() {
    local sid t seeded
    sid=$(new_session saggr2)
    seeded=$(d2099s_seed "$sid" \
        '{"level":"high","signals":["S2-architecture"],"levels":{"detail":"low","write_tests":"low","write_code":"low"}}')
    assert_eq "SA-2 the inverse record survives the projection" "SEEDED" "$seeded"

    for t in outline detail; do
        d2099s_assert "SA-3 [$t] aggregate level=high is NOT skip-eligible even with every stage low" \
            "$seeded" "NOT_ELIGIBLE" "$(d2099s_resolve "$sid" "$t")"
    done
}

# SA-5: the signals half of the legacy rule, isolated. level=low alone must not
# grant a skip while signals remain — and `levels` all-low must not rescue it.
d2099s_signals_half_of_the_rule() {
    local sid t seeded
    sid=$(new_session saggr3)
    seeded=$(d2099s_seed "$sid" \
        '{"level":"low","signals":["S1-multi-file"],"levels":{"detail":"low","write_tests":"low","write_code":"low"}}')
    assert_eq "SA-4 the level-low-with-signals record survives the projection" "SEEDED" "$seeded"

    for t in outline detail; do
        d2099s_assert "SA-5 [$t] level=low with a non-empty signal set is not skip-eligible" \
            "$seeded" "NOT_ELIGIBLE" "$(d2099s_resolve "$sid" "$t")"
    done
}

# SA-6: pre-#2099 records carry no `levels` map at all. The aggregate rule alone
# must still decide, or every legacy session loses its skip.
d2099s_absent_levels_map() {
    local sid t seeded
    sid=$(new_session saggr4)
    seeded=$(d2099s_seed "$sid" '{"level":"low","signals":[],"levels":null}')
    assert_eq "SA-6a the levels-less record survives the projection" "SEEDED" "$seeded"

    for t in outline detail; do
        d2099s_assert "SA-6 [$t] a record with no levels map is still resolved from the aggregate" \
            "$seeded" "ELIGIBLE" "$(d2099s_resolve "$sid" "$t")"
    done
}

d2099s_aggregate_low_beats_stage_high
d2099s_aggregate_high_beats_stage_low
d2099s_signals_half_of_the_rule
d2099s_absent_levels_map
