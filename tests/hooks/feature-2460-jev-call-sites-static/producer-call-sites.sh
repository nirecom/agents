#!/bin/bash
# tests/hooks/feature-2460-jev-call-sites-static/producer-call-sites.sh
# Tests: skills/make-outline-plan/SKILL.md, skills/_shared/complexity-and-outline-skip.md
# Tags: complexity, prompt-static, producers, skip-dispatch, jev, shared-procedure, call-sites, stage-5, scope:issue-specific
# Sourced by ../feature-2460-jev-call-sites-static.sh — helpers come from there.
# Moved with their PO ids kept (PO-10..14, PO-20..23) from the feature-2099
# producer cases: the outline stage's and the COS procedure's stage-5 call sites.

d2460ps_mop_file() { echo "$SCRIPT_CHECKOUT_ROOT/skills/make-outline-plan/SKILL.md"; }
d2460ps_cos_file() { echo "$SCRIPT_CHECKOUT_ROOT/skills/_shared/complexity-and-outline-skip.md"; }

# MOP-1d is item `d.` of MOP-1 (or a line naming MOP-1d once it is relabelled).
d2460ps_mop1d() {
    local f own item
    f=$(d2460ps_mop_file)
    own=$(d2099_raw_section "$f" MOP-1d | grep -m1 '[^[:space:]]')
    item=$(d2099_raw_section "$f" MOP-1 | grep -m1 -E '^[[:space:]]*d\.|MOP-1d')
    printf '%s\n' "${own:-$item}"
}

# PO-10..PO-14: the outline stage's three call sites of the shared judge.
d2460ps_outline_call_sites() {
    local mop d1 m2 c1 jj_ln adv_ln
    mop=$(d2460ps_mop_file)
    d1=$(d2460ps_mop1d)
    assert_eq "PO-10 MOP-1d runs the shared procedure (point=outline-skip, stage=outline)" "yes" \
        "$(d2099_jj_ref_state "$d1" outline-skip outline)"
    assert_contains "PO-10a ... and goes to Completion when SKIP=true" "SKIP=true" "$d1"
    assert_eq "PO-10b ... with no zero-signal script and no direct skip record" "no no" \
        "$(printf '%s' "$d1" | grep -qF check-outline-skip.sh && echo yes || echo no) $(printf '%s' "$d1" | grep -qF record-skip-judgment && echo yes || echo no)"

    m2=$(d2099_skill_section "$mop" MOP-2)
    assert_eq "PO-11 MOP-2's NONE branch is the shared procedure (point=complexity-judge, stage=outline)" "yes" \
        "$(d2099_jj_ref_state "$m2" complexity-judge outline)"
    assert_not_contains "PO-11a ... with no normalize step of its own" "normalize-judge-signals" "$m2"

    c1=$(d2099_raw_section "$mop" MOP-C1)
    assert_eq "PO-12 MOP-C1 runs the shared procedure (point=detail-skip, stage=outline)" "yes" \
        "$(d2099_jj_ref_state "$c1" detail-skip outline)"
    assert_contains "PO-13 ... then completes outline with next-step --advance" \
        'next-step" --advance --step outline --complete --next' "$c1"
    jj_ln=$(printf '%s\n' "$c1" | grep -nF 'jev-two-stage-judge.md' | head -1 | cut -d: -f1)
    adv_ln=$(printf '%s\n' "$c1" | grep -nF -- '--advance --step outline --complete' | head -1 | cut -d: -f1)
    assert_eq "PO-13a ... and the judge reference comes before the advance" "yes" \
        "$( [ -n "$jj_ln" ] && [ -n "$adv_ln" ] && [ "$jj_ln" -le "$adv_ln" ] && echo yes || echo no )"
    assert_eq "PO-14 MOP-C1 keeps no skip-verifier, zero-signal script or direct skip record" "no no no" \
        "$(printf '%s' "$c1" | grep -qF skip-verifier && echo yes || echo no) $(printf '%s' "$c1" | grep -qF check-detail-skip.sh && echo yes || echo no) $(printf '%s' "$c1" | grep -qF record-skip-judgment && echo yes || echo no)"
}

# PO-20..PO-22: each COS step names its point/stage, and COS-3 reads SKIP=true
# as "outline is already settled".
d2460ps_cos_steps() {
    local cos s1 s2 s3
    cos=$(d2460ps_cos_file)
    s1=$(d2099_raw_section "$cos" COS-1)
    s2=$(d2099_raw_section "$cos" COS-2)
    s3=$(d2099_raw_section "$cos" COS-3)
    assert_eq "PO-20 COS-1 runs the shared procedure (point=complexity-judge, stage=complexity)" "yes" \
        "$(d2099_jj_ref_state "$s1" complexity-judge complexity)"
    assert_eq "PO-21 COS-2 runs the shared procedure (point=outline-skip, stage=complexity)" "yes" \
        "$(d2099_jj_ref_state "$s2" outline-skip complexity)"
    assert_contains "PO-22 COS-3 branches on SKIP=true" "SKIP=true" "$s3"
    assert_eq "PO-22a ... where SKIP=true means outline is already settled" "yes" \
        "$(printf '%s\n' "$s3" | grep -F 'SKIP=true' | grep -qiE 'settle' && echo yes || echo no)"
    assert_eq "PO-22b COS-4 is gone (the old dispatch branch)" "no" \
        "$(d2099_has_re "$cos" '^## COS-4')"
}

# PO-23: the retired chain names nothing in the shared doc any more. The doc must
# exist, or every absence below would pass on a missing file.
d2460ps_cos_retired_names() {
    local cos name
    cos=$(d2460ps_cos_file)
    assert_eq "PO-23a the COS procedure file exists" "present" "$([ -f "$cos" ] && echo present || echo absent)"
    for name in record-complexity-and-skip normalize-judge-signals skip-verifier \
        check-complexity-skip.sh SKIP_DISPATCH complexity-judge-raw.txt; do
        assert_eq "PO-23 the COS procedure no longer names $name" "no" "$(d2099_has "$cos" "$name")"
    done
}

case_begin "outline-stage-call-sites" "skills/make-outline-plan/SKILL.md"
d2460ps_outline_call_sites
case_end

case_begin "cos-steps-reference-shared-judge" "skills/_shared/complexity-and-outline-skip.md"
d2460ps_cos_steps
case_end

case_begin "cos-retired-chain-absent" "skills/_shared/complexity-and-outline-skip.md"
d2460ps_cos_retired_names
case_end
