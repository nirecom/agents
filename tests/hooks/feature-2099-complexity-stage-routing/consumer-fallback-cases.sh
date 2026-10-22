#!/bin/bash
# tests/hooks/feature-2099-complexity-stage-routing/consumer-fallback-cases.sh
# Tests: skills/make-detail-plan/SKILL.md, skills/write-tests/SKILL.md, skills/write-code/SKILL.md, skills/_shared/judge-task-complexity.md, bin/workflow/derive-complexity-level
# Tags: complexity, routing, consumers, fallback, judgment-parsing, scope:issue-specific
# Sourced by the feature-2099-complexity-stage-routing-*.sh entrypoints AFTER
# consumer-orchestration-cases.sh. #2460: the consumer fallback is the shared
# judge procedure (skills/_shared/jev-two-stage-judge.md), statically pinned by
# consumers-static.sh; the CLI-level contracts the procedure relies on stay here.

# The judge's output label, read from the rubric so this test never becomes the
# format's second owner (CPR-SSOT).
d2099cf_label() {
    grep -oE 'SIGNALS:' "$RUBRIC" 2>/dev/null | head -1
}

# CF-1: the rubric still states the label the judge emits.
d2099cf_extraction_is_real() {
    local label
    label=$(d2099cf_label)
    if [ -z "$label" ]; then
        fail "CF-1 the rubric states no 'SIGNALS:' output label, so the judge has no format to emit"
        return
    fi
    pass "CF-1 the rubric states the judge's output label ($label)"
}

# --- CF-9: the zero-signal marker -> CLI argument translation -----------------
# `SIGNALS: none` is the judge's "nothing matched" MARKER; the CLIs' zero-signal
# value is the empty csv. The orchestration paths call the runner's
# d2099_csv_for_cli, so its truth table is pinned once here.
d2099cf_translation_table() {
    local input want got
    while IFS='|' read -r input want; do
        [ -n "$input" ] || continue
        got=$(d2099_csv_for_cli "$(printf '%s' "$input" | sed 's/^__EMPTY__$//')")
        assert_eq "CF-9 [$input] the shared marker translation yields [$want]" \
            "$(printf '%s' "$want" | sed 's/^__EMPTY__$//')" "$got"
    done <<'EOF'
none|__EMPTY__
NONE|__EMPTY__
None|__EMPTY__
__EMPTY__|__EMPTY__
S0-undecidable|S0-undecidable
S1b-wide-change|S1b-wide-change
S1b-wide-change,S2-architecture|S1b-wide-change,S2-architecture
nonexistent-signal|nonexistent-signal
EOF
}

# CF-10: the translation is LOAD-BEARING, not cosmetic. Per consumer stage, the
# translated empty csv must route low while the untranslated literal `none`
# routes undecidable-high — otherwise a CLI that answers low to anything it does
# not recognize would pass, the silent-cheap-model failure #2099 is about.
d2099cf_untranslated_marker_is_high() {
    local stage got
    for stage in detail write_tests write_code; do
        got=$(run_with_timeout node "$BIN_DERIVE" --stage "$stage" --signals "none" 2>/dev/null | head -1)
        case "$got" in
            level=high) pass "CF-10 $stage: the UNtranslated literal 'none' routes undecidable-high" ;;
            level=low)  fail "CF-10 $stage: the literal 'none' routed LOW — it is read as a known signal id, so the translation is not load-bearing" ;;
            *)          fail "CF-10 $stage: the literal 'none' produced neither level=high nor level=low: got [$got]" ;;
        esac
        got=$(run_with_timeout node "$BIN_DERIVE" --stage "$stage" --signals "" 2>/dev/null | head -1)
        assert_eq "CF-10a $stage: ... while the translated empty csv routes low" "level=low" "$got"
    done
}

# --- CF-11: exactly one of --signals / --signals-file --------------------------
# The CLI must refuse an AMBIGUOUS call (both flags — which source wins is
# unknowable to the caller) and an ABSENT one (neither — a level derived from
# nothing at all). The rule is stage-independent, so one stage carries it.
d2099cf_signals_flag_arity() {
    local f out rc sid="cf-arity"
    # #2434: derive accepts --signals-file only as the legacy <plans>/<sid>-<stage>-signals.txt.
    f="$WORKFLOW_PLANS_DIR/$sid-detail-signals.txt"
    printf 'S1b-wide-change' > "$f"

    rc=0
    out=$(run_with_timeout node "$BIN_DERIVE" --stage detail --signals "S1b-wide-change" \
        --signals-file "$f" 2>&1) || rc=$?
    assert_eq "CF-11 the derive CLI rejects --signals and --signals-file together (exit 1)" "1" "$rc"
    assert_contains "CF-11a ... with its own documented mutual-exclusion message" \
        "mutually exclusive" "$out"
    assert_not_contains "CF-11b ... and answers no level at all" "level=" "$out"

    rc=0
    out=$(run_with_timeout node "$BIN_DERIVE" --stage detail 2>&1) || rc=$?
    assert_eq "CF-11c the derive CLI rejects neither flag being passed (exit 1)" "1" "$rc"
    assert_contains "CF-11d ... with its own documented required-flag message" "is required" "$out"
    assert_not_contains "CF-11e ... and likewise answers no level" "level=" "$out"

    # Teeth: the SAME file passed alone is accepted and routes (S1b: detail low).
    rc=0
    out=$(run_with_timeout node "$BIN_DERIVE" --stage detail --session "$sid" --signals-file "$f" 2>&1) || rc=$?
    assert_eq "CF-11f ... while that same file passed ALONE is accepted and derives detail's level" \
        "0 level=low" "$rc $(printf '%s\n' "$out" | head -1)"
}

case_begin "fallback-rubric-label" "skills/_shared/judge-task-complexity.md"
d2099cf_extraction_is_real
case_end

case_begin "fallback-marker-translation" "bin/workflow/derive-complexity-level"
d2099cf_translation_table
d2099cf_untranslated_marker_is_high
case_end

case_begin "fallback-signals-flag-arity" "bin/workflow/derive-complexity-level"
d2099cf_signals_flag_arity
case_end
