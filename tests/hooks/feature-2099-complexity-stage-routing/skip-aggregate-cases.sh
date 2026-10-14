#!/bin/bash
# tests/hooks/feature-2099-complexity-stage-routing/skip-aggregate-cases.sh
# Tests: hooks/workflow-state/skip-signal-resolver.js, hooks/workflow-state/skip-signal-resolver/complexity.js, hooks/workflow-state/skip-signal-resolver/condition-schemas.js, hooks/workflow-state/state-io/projection.js
# Tags: complexity, routing, skip-conditions, back-compat, scope:issue-specific, no-auto-skip
# Sourced by ../feature-2099-complexity-stage-routing.sh — helpers come from there.

# --- SA: no complexity record, whatever its shape, grants an outline/detail skip
# #2460 retires the zero-signal auto-skip: a complexity evaluation only routes
# stages now. Every fixture below is a record that once granted (or once was a
# trap for) the skip, so each must leave outline/detail pending with no judgment.

# The resolver's verdict for one target: NO_SKIP when the complexity-derived skip
# entry point is gone (end state) or declines; ELIGIBLE when it still grants one.
d2099s_resolve() {
    local sid="$1" target="$2"
    RESOLVER="$RESOLVER_N" SID="$sid" TARGET="$target" run_with_timeout node - <<'JS' 2>/dev/null
const r = require(process.env.RESOLVER);
const fn = r.resolveSkipConditionsFromComplexity;
if (typeof fn !== "function") { console.log("NO_SKIP"); process.exit(0); }
const v = fn(process.env.SID, process.env.TARGET);
if (v && typeof v === "object" && Object.keys(v).length > 0 &&
    Object.values(v).every(function (x) { return x === true; })) { console.log("ELIGIBLE"); }
else { console.log("NO_SKIP"); }
JS
}

# "<status> sj=<null|set>" for one step — the observable form of "no skip happened".
d2099s_step() {
    local sid="$1" target="$2"
    BARREL="$BARREL_N" RESOLVER="$RESOLVER_N" SID="$sid" TARGET="$target" run_with_timeout node -e '
const s = require(process.env.BARREL).readState(process.env.SID);
const st = s && s.steps && s.steps[process.env.TARGET];
const sj = require(process.env.RESOLVER).readSkipJudgment(process.env.SID, process.env.TARGET);
process.stdout.write((st && st.status ? st.status : "NO_STEP") + " sj=" + (sj ? "set" : "null"));
' 2>/dev/null
}

# Inject a record, then prove it survived the projection before asserting on it.
d2099s_seed() {
    local sid="$1" raw="$2" projected
    d2099_inject_raw_event "$sid" "$raw" >/dev/null 2>&1
    projected=$(d2099_projected_ce "$sid")
    case "$projected" in
        __NO_STATE__|null|"") echo "SEED_LOST" ;;
        *) echo "SEEDED" ;;
    esac
}

# With no record at all the resolver declines for its own reason, which would make
# every row pass while testing nothing — so each row is conditional on the seed.
d2099s_assert() {
    local desc="$1" seeded="$2" want="$3" got="$4"
    if [ "$seeded" != "SEEDED" ]; then
        fail "$desc — unattributable: the fixture record never reached the projection ($seeded)"
    else
        assert_eq "$desc" "$want" "$got"
    fi
}

# One fixture across both skip targets: the resolver grants nothing and the step
# stays pending with no recorded judgment.
d2099s_no_skip_rows() {
    local id="$1" desc="$2" raw="$3" sid seeded t
    sid=$(new_session "saggr-$id")
    seeded=$(d2099s_seed "$sid" "$raw")
    assert_eq "$id-0 the fixture record survives the projection (else the rows below are vacuous)" \
        "SEEDED" "$seeded"
    for t in outline detail; do
        d2099s_assert "$id [$t] $desc" "$seeded" "NO_SKIP pending sj=null" \
            "$(d2099s_resolve "$sid" "$t") $(d2099s_step "$sid" "$t")"
    done
}

# SA-R: the complexity-derived skip entry point is retired from both the barrel
# and its implementation module (end state of #2460).
d2099s_entry_point_retired() {
    local mod_n out
    mod_n="$(to_node_path "$SCRIPT_CHECKOUT_ROOT/hooks/workflow-state/skip-signal-resolver/complexity.js")"
    out=$(RESOLVER="$RESOLVER_N" MOD="$mod_n" run_with_timeout node -e '
const a = typeof require(process.env.RESOLVER).resolveSkipConditionsFromComplexity;
const b = typeof require(process.env.MOD).resolveSkipConditionsFromComplexity;
process.stdout.write("resolver=" + a + " complexity=" + b);
' 2>/dev/null)
    assert_eq "SA-R resolveSkipConditionsFromComplexity is exported by neither the resolver nor complexity.js" \
        "resolver=undefined complexity=undefined" "$out"
}

case_begin "sa-r-entry-point-retired" "hooks/workflow-state/skip-signal-resolver.js"
d2099s_entry_point_retired
case_end
# SA-1: the record that used to auto-skip — aggregate low, no signals — even with
# every per-stage level high.
case_begin "sa1-zero-signal-low-no-skip" "hooks/workflow-state/skip-signal-resolver/complexity.js"
d2099s_no_skip_rows SA-1 "a zero-signal low record no longer grants a skip" \
    '{"level":"low","signals":[],"levels":{"outline":"high","detail":"high","write_tests":"high","write_code":"high"}}'
case_end
# SA-3: aggregate high, every per-stage level low — a resolver consulting `levels`
# must not grant a skip either.
case_begin "sa3-aggregate-high-stage-low-no-skip" "hooks/workflow-state/skip-signal-resolver/complexity.js"
d2099s_no_skip_rows SA-3 "aggregate high with every stage low grants no skip" \
    '{"level":"high","signals":["S2-architecture"],"levels":{"outline":"low","detail":"low","write_tests":"low","write_code":"low"}}'
case_end
# SA-5: level low with a signal present and every stage low.
case_begin "sa5-low-with-signal-no-skip" "hooks/workflow-state/skip-signal-resolver/complexity.js"
d2099s_no_skip_rows SA-5 "level low with a non-empty signal set grants no skip" \
    '{"level":"low","signals":["S1b-wide-change"],"levels":{"outline":"low","detail":"low","write_tests":"low","write_code":"low"}}'
case_end
# SA-6: a pre-#2099 record with no levels map — the legacy-shaped skip candidate.
case_begin "sa6-absent-levels-map-no-skip" "hooks/workflow-state/state-io/projection.js"
d2099s_no_skip_rows SA-6 "a levels-less zero-signal low record grants no skip" \
    '{"level":"low","signals":[],"levels":null}'
case_end
