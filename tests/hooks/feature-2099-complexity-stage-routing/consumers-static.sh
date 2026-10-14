#!/bin/bash
# tests/hooks/feature-2099-complexity-stage-routing/consumers-static.sh
# Tests: skills/make-detail-plan/SKILL.md, skills/write-tests/SKILL.md, skills/write-code/SKILL.md, skills/clarify-intent/SKILL.md, skills/workflow-init/SKILL.md, bin/workflow/read-session-facts
# Tags: complexity, routing, prompt-static, consumers, scope:issue-specific, jev, shared-procedure
# Sourced by ../feature-2099-complexity-stage-routing.sh (helpers: there and skill-section-helpers.sh).
# Consumers name only their own stage and never restate a threshold (detail.md D4/P5).
# Stage-5 call-site checks live in ../feature-2460-jev-call-sites-static.sh.
# lang-check: ignore -- rubric-consistency regex asserts bilingual (English/Japanese) phrasing

# --- consumer stage wiring -----------------------------------------------------
d2099_stage_wiring() {
    local mdp="$SCRIPT_CHECKOUT_ROOT/skills/make-detail-plan/SKILL.md"
    local wt="$SCRIPT_CHECKOUT_ROOT/skills/write-tests/SKILL.md"
    local wcd="$SCRIPT_CHECKOUT_ROOT/skills/write-code/SKILL.md"

    assert_eq "CS-1 MDP-3 reads with --stage detail" "yes" \
        "$(d2099_has_re "$mdp" 'read-complexity-evaluation.*--stage detail')"
    assert_eq "CS-3 make-detail-plan never names another stage" "no" \
        "$(d2099_has_re "$mdp" '--stage (write_tests|write_code)')"

    # WT-0 takes ONE bundled read-session-facts record; the stage is spelled in
    # the COMPLEXITY_LEVEL_<stage> key it is told to read.
    assert_eq "CS-4 WT-0 reads its own stage key out of the bundled session facts" "yes yes" \
        "$(d2099_has "$wt" 'read-session-facts') $(d2099_has "$wt" 'COMPLEXITY_LEVEL_write_tests')"
    assert_eq "CS-6 write-tests never names another stage" "no" \
        "$(d2099_has_re "$wt" '--stage (detail|write_code)')"
    assert_eq "CS-7 WT-6 consumes the signals= line as task_complexity_signals" "yes" \
        "$(d2099_has "$wt" "task_complexity_signals")"

    assert_eq "CS-10 write-code never names another stage" "no" \
        "$(d2099_has_re "$wcd" '--stage (detail|write_tests)')"

    # The direct CLI answers `signals=`, the bundled record `COMPLEXITY_SIGNALS=`.
    assert_eq "CS-11 make-detail-plan parses the signal list its own reader emits" "yes" \
        "$(d2099_has "$mdp" "signals=")"
    assert_eq "CS-11 write-tests parses the signal list its own reader emits" "yes" \
        "$(d2099_has "$wt" "COMPLEXITY_SIGNALS=")"
}

# CS-12..14: no consumer may restate a threshold — the routing table owns them.
d2099_no_thresholds() {
    local f label
    for f in "$SCRIPT_CHECKOUT_ROOT/skills/make-detail-plan/SKILL.md" \
             "$SCRIPT_CHECKOUT_ROOT/skills/write-tests/SKILL.md" \
             "$SCRIPT_CHECKOUT_ROOT/skills/write-code/SKILL.md"; do
        label="$(basename "$(dirname "$f")")"
        assert_eq "CS-12 $label states no file-count threshold" "no" \
            "$(d2099_has_re "$f" '[0-9]+ (or more|\+) *(files|ファイル)')"
        assert_eq "CS-13 $label does not restate the 1-or-more-signals rule" "no" \
            "$(d2099_has_re "$f" '(1|one) or more signals')"
        assert_eq "CS-14 $label does not enumerate escalation signal ids itself" "no" \
            "$(d2099_has_re "$f" 'S1b-wide-change|solo_escalation|legacy_equivalent_escalation')"
    done
}

# CS-15..21: the two producer write points are symmetric 1-line delegations.
d2099_write_points() {
    local ci="$SCRIPT_CHECKOUT_ROOT/skills/clarify-intent/SKILL.md"
    local wi="$SCRIPT_CHECKOUT_ROOT/skills/workflow-init/SKILL.md"
    local row f step sect
    for row in "$ci|CI-C1b" "$wi|A3a"; do
        f="${row%%|*}"; step="${row##*|}"
        sect=$(d2099_skill_section "$f" "$step")
        assert_eq "CS-15 $step is a single line" "1" "$(d2099_nonblank_count "$sect")"
        assert_eq "CS-16 $step delegates to the shared COS procedure" "yes" \
            "$(d2099_step_has "$f" "$step" "complexity-and-outline-skip.md")"
        assert_eq "CS-18 $step carries no --signals <csv> splice slot (PO-INJ)" "no" \
            "$(d2099_step_has "$f" "$step" "--signals <")"
        assert_eq "CS-20 $step no longer passes --verdict" "no" \
            "$(d2099_step_has "$f" "$step" "--verdict")"
        assert_eq "CS-21 $(basename "$(dirname "$f")") no longer expects a LEVEL: verdict line" "no" \
            "$(d2099_has "$f" "LEVEL: high")"
    done
}

# CS-22..23: mutation probe for the two stored reads. Original yes plus both
# mutants (token dropped / foreign stage) no, in ONE assertion, so a pattern
# that matches nothing cannot pass vacuously.
d2099_stage_pattern_teeth() {
    local mdp="$SCRIPT_CHECKOUT_ROOT/skills/make-detail-plan/SKILL.md"
    local wt="$SCRIPT_CHECKOUT_ROOT/skills/write-tests/SKILL.md"
    local n=22 row file anchor foreign pattern dropped swapped rest
    # <file>|<stage-carrying token>|<foreign-stage token>|<pattern>
    for row in "$mdp|--stage detail|--stage write_code|read-complexity-evaluation.*--stage detail" \
               "$wt|COMPLEXITY_LEVEL_write_tests|COMPLEXITY_LEVEL_write_code|COMPLEXITY_LEVEL_write_tests"; do
        file="${row%%|*}"; rest="${row#*|}"
        anchor="${rest%%|*}"; rest="${rest#*|}"
        foreign="${rest%%|*}"; pattern="${rest#*|}"
        dropped="$TMPDIR_BASE/mut-drop-$n.md"; swapped="$TMPDIR_BASE/mut-swap-$n.md"
        sed "s/$anchor//g" "$file" > "$dropped" 2>/dev/null
        sed "s/$anchor/$foreign/g" "$file" > "$swapped" 2>/dev/null
        assert_eq "CS-$n $(basename "$(dirname "$file")") pattern matches the original and BOTH stage mutants break it" \
            "original=yes dropped=no swapped=no" \
            "original=$(d2099_has_re "$file" "$pattern") dropped=$(d2099_has_re "$dropped" "$pattern") swapped=$(d2099_has_re "$swapped" "$pattern")"
        n=$((n + 1))
    done
}

# CS-24: the shared-procedure reference matcher (skill-section-helpers.sh, used by
# the stage-5 call-site suite) has teeth (synthetic lines, green today).
d2099_jj_ref_teeth() {
    local ok='Run `skills/_shared/jev-two-stage-judge.md` with point=complexity-judge, stage=write-tests.'
    assert_eq "CS-24 the shared-procedure reference matcher accepts the right point/stage and rejects each mutation" \
        "match=yes stage=no point=no doc=no" \
        "match=$(d2099_jj_ref_state "$ok" complexity-judge write-tests) stage=$(d2099_jj_ref_state "$ok" complexity-judge write-code) point=$(d2099_jj_ref_state "$ok" outline-skip write-tests) doc=$(d2099_jj_ref_state "${ok/jev-two-stage-judge/other}" complexity-judge write-tests)"
}

case_begin "consumer-stage-wiring" "skills/make-detail-plan/SKILL.md"
d2099_stage_wiring
case_end

case_begin "consumer-no-thresholds" "skills/write-tests/SKILL.md"
d2099_no_thresholds
case_end

case_begin "producer-write-points-one-line" "skills/clarify-intent/SKILL.md"
d2099_write_points
case_end

case_begin "consumer-stage-pattern-teeth" "skills/make-detail-plan/SKILL.md"
d2099_stage_pattern_teeth
d2099_jj_ref_teeth
case_end
