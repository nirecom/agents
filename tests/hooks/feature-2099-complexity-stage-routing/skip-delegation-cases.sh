#!/bin/bash
# tests/feature-2099-complexity-stage-routing/skip-delegation-cases.sh
# Tests: hooks/workflow-state/skip-signal-resolver.js, hooks/workflow-state/skip-signal-resolver/complexity.js, hooks/workflow-state/skip-signal-resolver/condition-schemas.js, hooks/workflow-state/complexity-routing.js
# Tags: complexity, routing, skip-conditions, ssot, delegation, scope:issue-specific
# Sourced by ../feature-2099-complexity-stage-routing.sh after skip-aggregate-cases.sh
# (d2099s_resolve is reused here as the un-stubbed control).
# Why: the sibling suites pin isZeroSignalLow's truth table and the resolver's
# outputs separately. Both pass when the resolver carries its OWN copy of the
# predicate — a second source of truth that drifts silently (round-10 C3).

d2099dl_spy() {
    # Replace complexity-routing's isZeroSignalLow with an INVERTED, counting
    # stub before the resolver is loaded, then ask the resolver to decide. Only a
    # resolver that actually calls the export can be flipped by it.
    local sid="$1" target="$2" out
    out=$(CR="$CR_MOD_N" RESOLVER="$RESOLVER_N" SID="$sid" TARGET="$target" \
        run_with_timeout node -e '
const crPath = process.env.CR;
let cr, real;
try { cr = require.resolve(crPath); } catch (e) { console.log("CR_UNRESOLVABLE"); process.exit(0); }
try { real = require(cr); } catch (e) { console.log("CR_UNLOADABLE"); process.exit(0); }
if (typeof real.isZeroSignalLow !== "function") { console.log("NO_isZeroSignalLow_EXPORT"); process.exit(0); }
const realFn = real.isZeroSignalLow;
const calls = [];
const stub = {};
Object.keys(real).forEach(function (k) { stub[k] = real[k]; });
stub.isZeroSignalLow = function (ce) {
  calls.push(ce && typeof ce === "object" ? { level: ce.level, signals: ce.signals } : ce);
  return !realFn(ce);
};
Object.keys(require.cache).forEach(function (k) {
  if (k.indexOf("workflow-state") !== -1) { delete require.cache[k]; }
});
require(cr);
require.cache[cr].exports = stub;
let r, v;
try { r = require(process.env.RESOLVER); } catch (e) { console.log("RESOLVER_UNLOADABLE"); process.exit(0); }
try { v = r.resolveSkipConditionsFromComplexity(process.env.SID, process.env.TARGET); } catch (e) { v = "THREW"; }
let verdict;
if (v === "THREW") { verdict = "THREW"; }
else if (v === null || v === undefined) { verdict = "NOT_ELIGIBLE"; }
else if (typeof v !== "object") { verdict = "BAD_SHAPE:" + typeof v; }
else if (Object.keys(v).length === 0) { verdict = "EMPTY_OBJECT"; }
else if (Object.values(v).every(function (x) { return x === true; })) { verdict = "ELIGIBLE"; }
else { verdict = "PARTIAL:" + JSON.stringify(v); }
console.log("calls=" + calls.length + " verdict=" + verdict +
  " arg=" + (calls.length ? JSON.stringify(calls[0]) : "-"));
' 2>/dev/null)
    [ -n "$out" ] || out="NO_OUTPUT"
    printf '%s' "$out"
}

d2099dl_seed() {
    local sid="$1" csv="$2"
    run_with_timeout node "$BIN_RECORD" --session "$sid" --signals "$csv" >/dev/null 2>&1
    printf '%s' "$sid"
}

d2099dl_eligible_shape() {
    # SD-0/SD-1: an ELIGIBLE record (level=low, no signals). Un-stubbed it must
    # skip; with the predicate inverted it must STOP skipping. A resolver holding
    # its own `level === "low" && signals.length === 0` cannot notice the flip.
    local sid t
    sid=$(d2099dl_seed "$(new_session sdlow)" "")
    for t in outline detail; do
        assert_eq "SD-0 [$t] control: the un-stubbed resolver grants the skip for a zero-signal low record" \
            "ELIGIBLE" "$(d2099s_resolve "$sid" "$t")"
        assert_eq "SD-1 [$t] inverting complexity-routing's isZeroSignalLow flips the verdict, and it is consulted exactly once with the read record" \
            'calls=1 verdict=NOT_ELIGIBLE arg={"level":"low","signals":[]}' \
            "$(d2099dl_spy "$sid" "$t")"
    done
}

d2099dl_ineligible_shape() {
    # SD-2/SD-3: the mirror record (level=high, one signal). Inverting the shared
    # predicate must make an ineligible session skip — proving the resolver never
    # applies a second, independent eligibility test of its own on top.
    local sid t
    sid=$(d2099dl_seed "$(new_session sdhigh)" "S1-multi-file")
    for t in outline detail; do
        assert_eq "SD-2 [$t] control: the un-stubbed resolver refuses the skip for a one-signal record" \
            "NOT_ELIGIBLE" "$(d2099s_resolve "$sid" "$t")"
        assert_eq "SD-3 [$t] the inverted predicate alone turns that refusal into a skip — no second inline test overrides it" \
            'calls=1 verdict=ELIGIBLE arg={"level":"high","signals":["S1-multi-file"]}' \
            "$(d2099dl_spy "$sid" "$t")"
    done
}

d2099dl_target_guard_precedes_the_predicate() {
    # SD-4: targets outside {outline, detail} own no skip conditions, so the
    # record must never be judged at all. calls=0 pins the guard's position;
    # without it a delegating resolver could still call on every step.
    local sid t
    sid=$(d2099dl_seed "$(new_session sdguard)" "")
    for t in research write_tests; do
        assert_eq "SD-4 [$t] a target with no skip conditions is refused before the complexity predicate is consulted" \
            "calls=0 verdict=NOT_ELIGIBLE arg=-" "$(d2099dl_spy "$sid" "$t")"
    done
}

# SKIPPED: proving no COPY of the predicate exists anywhere in the resolver source.
# Because: a text scan for the expression is defeated by any rewording, and the
#   observable behaviour of a copy that happens to agree is identical.
# Closest substitute: SD-1/SD-3 above — the copy stops agreeing the moment the
#   shared export is inverted, which is exactly the drift CPR-SSOT guards against.
# Related: FO-3 (fail-open-cases.sh) shows the resolver returning null when the
#   routing module cannot be loaded at all; that is the absence half of the same
#   dependency, not evidence of the call.

d2099dl_eligible_shape
d2099dl_ineligible_shape
d2099dl_target_guard_precedes_the_predicate
