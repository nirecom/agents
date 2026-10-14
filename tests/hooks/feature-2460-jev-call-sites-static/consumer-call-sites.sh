#!/bin/bash
# tests/hooks/feature-2460-jev-call-sites-static/consumer-call-sites.sh
# Tests: skills/make-detail-plan/SKILL.md, skills/write-tests/SKILL.md, skills/write-code/SKILL.md, skills/clarify-intent/SKILL.md, skills/workflow-init/SKILL.md
# Tags: complexity, prompt-static, consumers, producers, jev, shared-procedure, call-sites, stage-5, scope:issue-specific
# Sourced by ../feature-2460-jev-call-sites-static.sh — helpers come from there.
# Moved from feature-2099-complexity-stage-routing/consumers-static.sh with their
# CS ids kept: these pin the stage-5 end state, which the stage-1 suite must not.

# CS-2/5/8/9: each consumer's NONE branch is a 1-line shared-procedure reference
# naming its own point/stage; WCD-3 judges every time.
d2460cs_consumer_wiring() {
    local mdp="$SCRIPT_CHECKOUT_ROOT/skills/make-detail-plan/SKILL.md"
    local wt="$SCRIPT_CHECKOUT_ROOT/skills/write-tests/SKILL.md"
    local wcd="$SCRIPT_CHECKOUT_ROOT/skills/write-code/SKILL.md"

    assert_eq "CS-2 MDP-3's NONE branch is the shared procedure (point=complexity-judge, stage=detail)" "yes" \
        "$(d2099_jj_ref_state "$(d2099_skill_section "$mdp" MDP-3)" complexity-judge detail)"
    assert_eq "CS-5 WT-6's NONE branch is the shared procedure (point=complexity-judge, stage=write-tests)" "yes" \
        "$(d2099_jj_ref_state "$(d2099_skill_section "$wt" WT-6)" complexity-judge write-tests)"
    # WCD-3 judges every time (S1b/S4 come only from the WCD-2 list), so no
    # stored write_code level or model is consumed anywhere in the skill.
    assert_eq "CS-8 write-code no longer consumes a stored write_code level or model" "no no" \
        "$(d2099_has "$wcd" 'COMPLEXITY_LEVEL_write_code') $(d2099_has "$wcd" 'COMPLEXITY_MODEL_write_code')"
    assert_eq "CS-9 WCD-3 always runs the shared procedure (point=complexity-judge, stage=write-code)" "yes" \
        "$(d2099_jj_ref_state "$(d2099_skill_section "$wcd" WCD-3)" complexity-judge write-code)"
}

# CS-17: the two producer write points keep no trace of the retired wrapper.
d2460cs_producer_wiring() {
    local ci="$SCRIPT_CHECKOUT_ROOT/skills/clarify-intent/SKILL.md"
    local wi="$SCRIPT_CHECKOUT_ROOT/skills/workflow-init/SKILL.md"
    local row f step
    for row in "$ci|CI-C1b" "$wi|A3a"; do
        f="${row%%|*}"; step="${row##*|}"
        assert_eq "CS-17a $step section is found (so the absence below is not vacuous)" "yes" \
            "$([ -n "$(d2099_skill_section "$f" "$step")" ] && echo yes || echo no)"
        assert_eq "CS-17 $step names neither record-complexity-and-skip nor SKIP_DISPATCH" "no no" \
            "$(d2099_step_has "$f" "$step" "record-complexity-and-skip") $(d2099_step_has "$f" "$step" "SKIP_DISPATCH")"
    done
}

# CS-30..32: nothing under skills/ keeps the retired wiring.
d2460cs_skills_retired_refs() {
    local root="$SCRIPT_CHECKOUT_ROOT" needle hits s f
    for needle in record-complexity-and-skip check-complexity-skip.sh check-outline-skip.sh \
                  check-detail-skip.sh skip-verifier; do
        hits=$(grep -rlF -- "$needle" "$root/skills" 2>/dev/null | sed "s#^$root/##" | sort | tr '\n' ' ')
        assert_eq "CS-30 no file under skills/ references $needle" "none" "${hits:-none}"
    done
    for s in clarify-intent/scripts/check-complexity-skip.sh make-outline-plan/scripts/check-outline-skip.sh \
             make-outline-plan/scripts/check-detail-skip.sh; do
        assert_eq "CS-31 skills/$s is deleted" "absent" "$([ -e "$root/skills/$s" ] && echo present || echo absent)"
    done
    hits=""
    for f in "$root"/skills/*/SKILL.md "$root"/skills/_shared/*.md "$root"/skills/*/scripts/*; do
        [ -f "$f" ] || continue
        grep -qF -- "normalize-judge-signals" "$f" || continue
        hits="$hits${f#"$root"/} "
    done
    assert_eq "CS-32 no SKILL.md, _shared doc or skill script calls normalize-judge-signals directly" "none" "${hits:-none}"
}

case_begin "consumer-call-sites-reference-shared-judge" "skills/make-detail-plan/SKILL.md"
d2460cs_consumer_wiring
case_end

case_begin "producer-write-points-no-retired-wrapper" "skills/clarify-intent/SKILL.md"
d2460cs_producer_wiring
case_end

case_begin "skills-retired-wiring-absent" "skills/workflow-init/SKILL.md"
d2460cs_skills_retired_refs
case_end
