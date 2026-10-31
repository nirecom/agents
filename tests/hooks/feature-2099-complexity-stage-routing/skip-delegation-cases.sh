#!/bin/bash
# tests/hooks/feature-2099-complexity-stage-routing/skip-delegation-cases.sh
# Tests: hooks/workflow-state/skip-signal-resolver.js, hooks/workflow-state/skip-signal-resolver/complexity.js, hooks/workflow-state/skip-signal-resolver/condition-schemas.js, hooks/workflow-state/complexity-routing.js
# Tags: complexity, routing, skip-conditions, ssot, delegation, scope:issue-specific, no-auto-skip
# Sourced by the feature-2099-complexity-stage-routing-*.sh entrypoints after skip-aggregate-cases.sh
# (d2099s_resolve and d2099s_step are reused from there).
# Why: #2460 retires the zero-signal predicate the resolver used to delegate to.
# A record written through the real CLI must now leave every step pending.

d2099dl_seed() {
    local sid="$1" csv="$2"
    run_with_timeout node "$BIN_RECORD" --session "$sid" --signals "$csv" >/dev/null 2>&1
    printf '%s' "$sid"
}

# The aggregate level the real CLI recorded — proves the seed exists, so a
# "pending" row cannot pass merely because nothing was written.
d2099dl_level() {
    run_with_timeout node "$BIN_READ" --session "$1" 2>/dev/null | grep -m1 -oE '^level=[a-z]+'
}

d2099dl_predicate_retired() {
    # SD-0: the single-sourced zero-signal predicate is gone from complexity-routing.
    local out
    out=$(CR="$CR_MOD_N" run_with_timeout node -e '
process.stdout.write(typeof require(process.env.CR).isZeroSignalLow);
' 2>/dev/null)
    assert_eq "SD-0 complexity-routing no longer exports isZeroSignalLow" "undefined" "$out"
}

d2099dl_zero_signal_record_no_skip() {
    # SD-1: the record that used to be the skip trigger (level=low, no signals).
    local sid t
    sid=$(d2099dl_seed "$(new_session sdlow)" "")
    assert_eq "SD-1a the zero-signal record was written (level=low)" "level=low" "$(d2099dl_level "$sid")"
    for t in outline detail; do
        assert_eq "SD-1 [$t] a zero-signal low record grants no skip and the step stays pending" \
            "NO_SKIP pending sj=null" "$(d2099s_resolve "$sid" "$t") $(d2099s_step "$sid" "$t")"
    done
}

d2099dl_signal_record_no_skip() {
    # SD-2: the mirror record (one signal) stays unskipped too.
    local sid t
    sid=$(d2099dl_seed "$(new_session sdhigh)" "S1b-wide-change")
    assert_eq "SD-2a the one-signal record was written (level=high)" "level=high" "$(d2099dl_level "$sid")"
    for t in outline detail; do
        assert_eq "SD-2 [$t] a one-signal record grants no skip and the step stays pending" \
            "NO_SKIP pending sj=null" "$(d2099s_resolve "$sid" "$t") $(d2099s_step "$sid" "$t")"
    done
}

d2099dl_other_targets_unaffected() {
    # SD-4: targets outside {outline, detail} never owned a skip; they stay pending.
    local sid t
    sid=$(d2099dl_seed "$(new_session sdguard)" "")
    for t in research write_tests; do
        assert_eq "SD-4 [$t] a target with no skip conditions is untouched by the zero-signal record" \
            "NO_SKIP pending sj=null" "$(d2099s_resolve "$sid" "$t") $(d2099s_step "$sid" "$t")"
    done
}

case_begin "sd0-predicate-retired" "hooks/workflow-state/complexity-routing.js"
d2099dl_predicate_retired
case_end
case_begin "sd1-zero-signal-record-no-skip" "hooks/workflow-state/skip-signal-resolver.js"
d2099dl_zero_signal_record_no_skip
case_end
case_begin "sd2-signal-record-no-skip" "hooks/workflow-state/skip-signal-resolver/complexity.js"
d2099dl_signal_record_no_skip
case_end
case_begin "sd4-other-targets-unaffected" "hooks/workflow-state/skip-signal-resolver/condition-schemas.js"
d2099dl_other_targets_unaffected
case_end
