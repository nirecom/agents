#!/bin/bash
# tests/hooks/feature-2099-complexity-stage-routing/consumer-dispatch-cases.sh
# Tests: skills/make-detail-plan/SKILL.md, skills/write-tests/SKILL.md, skills/write-code/SKILL.md, bin/workflow/read-complexity-evaluation, bin/workflow/derive-complexity-level
# Tags: complexity, routing, consumers, integration, model-selection, scope:issue-specific
# Sourced by ../feature-2099-complexity-stage-routing.sh — helpers come from there.
# consumers-static.sh greps the three SKILL.md files, which proves the text is written,
# not that a RECORDED verdict reaches the Agent tool as the right model. Here the real
# CLI answers and the level maps through the mapping READ OUT OF the skill file; the
# Agent call itself stays the TL3 gap the parent runner already declares.

# d2099_doc_model_for <skill.md> <level> — reads model= from BIN_DERIVE via
# MODEL_PRODUCER_HIGH/LOW. After #2100 skills carry no hardcoded model table.
d2099_doc_model_for() {
    case "$2" in high|low) ;; *) echo "NO_LEVEL"; return ;; esac
    local sigs; [ "$2" = "high" ] && sigs="S2-architecture" || sigs=""
    run_with_timeout node "$BIN_DERIVE" --stage detail --signals "$sigs" 2>/dev/null \
        | grep '^model=' | head -1 | sed 's/^model=//'
}

# d2099_dispatch_model <skill.md> <sid> <stage> — replays the consumer decision:
# reads model= from BIN_READ output; FALLBACK when CLI answered NONE. The skill
# file argument is a label only: this proves the CLI side of the handoff. The
# skill side (the launch line carries that model=) is proved statically — CD-1 /
# CO-9 for detail/write_tests/write_code, CD-22..24 for MOP-2.
d2099_dispatch_model() {
    local f="$1" sid="$2" stage="$3" out first model
    out=$(run_with_timeout node "$BIN_READ" --session "$sid" --stage "$stage" 2>/dev/null)
    first=$(printf '%s\n' "$out" | head -1)
    [ "$first" = "NONE" ] && { echo "FALLBACK"; return; }
    model=$(printf '%s\n' "$out" | grep '^model=' | head -1 | sed 's/^model=//')
    [ -n "$model" ] && { echo "$model"; return; }
    case "$first" in
        level=*) echo "NO_MODEL_LINE_FOR:${first#level=}" ;;
        *) echo "UNPARSEABLE:$first" ;;
    esac
}

# CD-1: after #2100 each consumer must NOT carry a hardcoded model table (→ opus)
# and MUST reference the model= line from read-complexity-evaluation.
d2099_documented_mapping() {
    local f label has_table has_model_ref
    for f in "$AGENTS_DIR/skills/make-detail-plan/SKILL.md" \
             "$AGENTS_DIR/skills/write-tests/SKILL.md" \
             "$AGENTS_DIR/skills/write-code/SKILL.md"; do
        label="$(basename "$(dirname "$f")")"
        has_table=$(grep -qE '→ (opus|sonnet)' "$f" 2>/dev/null && echo yes || echo no)
        has_model_ref=$(grep -q 'model=' "$f" 2>/dev/null && echo yes || echo no)
        assert_eq "CD-1 $label no longer documents a hardcoded model table (→ opus/→ sonnet)" \
            "no" "$has_table"
        assert_eq "CD-1b $label references the model= line from the CLI" \
            "yes" "$has_model_ref"
    done
}

# CD-2..: a recorded verdict must reach the Agent tool as the model that stage's
# routing row implies — including the case #2099 exists for, where ONE signal set
# lands sonnet on two stages and opus on the third.
d2099_recorded_verdict_selects_model() {
    local mdp="$AGENTS_DIR/skills/make-detail-plan/SKILL.md"
    local wt="$AGENTS_DIR/skills/write-tests/SKILL.md"
    local wcd="$AGENTS_DIR/skills/write-code/SKILL.md"

    # detail/write_tests: S1-multi-file escalates neither (D2). write_code has no
    # low-with-signals input at all — every id escalates it — so its low case is
    # the zero-signal record below.
    local sid_lo
    sid_lo=$(new_session cdlow)
    run_with_timeout node "$BIN_RECORD" --session "$sid_lo" --signals "S1-multi-file" >/dev/null 2>&1
    assert_eq "CD-2 MDP-3 dispatches sonnet from a recorded low (S1-multi-file, stage detail)" \
        "sonnet" "$(d2099_dispatch_model "$mdp" "$sid_lo" detail)"
    assert_eq "CD-3 WT-6 dispatches sonnet from the SAME record (stage write_tests)" \
        "sonnet" "$(d2099_dispatch_model "$wt" "$sid_lo" write_tests)"
    assert_eq "CD-4 WCD-3 dispatches opus from that same record (stage write_code) — the #2099 split" \
        "opus" "$(d2099_dispatch_model "$wcd" "$sid_lo" write_code)"

    local sid_zero
    sid_zero=$(new_session cdzero)
    run_with_timeout node "$BIN_RECORD" --session "$sid_zero" --signals "" >/dev/null 2>&1
    assert_eq "CD-5 WCD-3 dispatches sonnet from a recorded zero-signal low" \
        "sonnet" "$(d2099_dispatch_model "$wcd" "$sid_zero" write_code)"

    local sid_arch
    sid_arch=$(new_session cdarch)
    run_with_timeout node "$BIN_RECORD" --session "$sid_arch" --signals "S2-architecture" >/dev/null 2>&1
    assert_eq "CD-6 MDP-3 dispatches opus from a recorded high (S2-architecture)" \
        "opus" "$(d2099_dispatch_model "$mdp" "$sid_arch" detail)"

    local sid_sec
    sid_sec=$(new_session cdsec)
    run_with_timeout node "$BIN_RECORD" --session "$sid_sec" --signals "S3-security" >/dev/null 2>&1
    assert_eq "CD-7 WT-6 dispatches opus from a recorded high (S3-security)" \
        "opus" "$(d2099_dispatch_model "$wt" "$sid_sec" write_tests)"
    assert_eq "CD-8 WCD-3 dispatches opus from the same high record" \
        "opus" "$(d2099_dispatch_model "$wcd" "$sid_sec" write_code)"

    # Cross-check against the stateless CLI the fallback branch uses: the two paths
    # must never disagree, or the model depends on which branch ran. The expected
    # level is spelled out per stage so "both answered nothing" cannot read as
    # agreement (bin/check-false-green.sh pattern 2).
    local row st lvl recorded derived
    for row in "detail|low" "write_tests|low" "write_code|high"; do
        st="${row%|*}"; lvl="${row#*|}"
        recorded=$(run_with_timeout node "$BIN_READ" --session "$sid_lo" --stage "$st" 2>/dev/null | head -1)
        derived=$(run_with_timeout node "$BIN_DERIVE" --stage "$st" --signals "S1-multi-file" 2>/dev/null | head -1)
        assert_eq "CD-9 $st: the recorded read and the fallback derivation agree, on the D2 level" \
            "level=$lvl|level=$lvl" "$recorded|$derived"
    done
}

# CD-10..: the NONE branch. With nothing recorded the CLI must say NONE (exit 0),
# which is the ONLY thing that routes a consumer into its inline-evaluation
# fallback. A CLI that guessed a level here would silently retire that branch.
d2099_none_selects_fallback() {
    local mdp="$AGENTS_DIR/skills/make-detail-plan/SKILL.md"
    local wt="$AGENTS_DIR/skills/write-tests/SKILL.md"
    local wcd="$AGENTS_DIR/skills/write-code/SKILL.md"

    local sid rc out row f stage label
    sid=$(new_session cdnone)   # created, never recorded into

    for row in "$mdp|detail" "$wt|write_tests" "$wcd|write_code"; do
        f="${row%|*}"; stage="${row#*|}"
        label="$(basename "$(dirname "$f")")"

        rc=0; out=$(run_with_timeout node "$BIN_READ" --session "$sid" --stage "$stage" 2>/dev/null) || rc=$?
        assert_eq "CD-10 $label: an unrecorded session reads NONE on exit 0" "NONE:0" "$out:$rc"
        assert_eq "CD-11 $label: ... so the decision procedure lands in the fallback, not a model" \
            "FALLBACK" "$(d2099_dispatch_model "$f" "$sid" "$stage")"

        # The branch it lands in must be the documented one: read the rubric, then
        # derive for THIS stage. Both are what MDP-3/WT-6/WCD-3 spell out.
        assert_eq "CD-12 $label: the fallback branch it lands in reads the rubric" "yes" \
            "$(d2099_has "$f" "judge-task-complexity.md")"
        assert_eq "CD-13 $label: ... and derives for its own stage" "yes" \
            "$(d2099_has_re "$f" "derive-complexity-level.*--stage $stage")"

        # And that fallback still yields a usable model, from the same mapping.
        out=$(run_with_timeout node "$BIN_DERIVE" --stage "$stage" --signals "" 2>/dev/null | head -1)
        assert_eq "CD-14 $label: the fallback derivation answers with a level" "level=low" "$out"
        assert_eq "CD-15 $label: ... which maps to a real model through the documented rule" \
            "sonnet" "$(d2099_doc_model_for "$f" "${out#level=}")"
    done

    # Negative control for CD-11: the SAME procedure on a session that DOES have a
    # record must not report FALLBACK. Without this, "FALLBACK" everywhere (e.g. a
    # CLI that always prints NONE) would look like a pass.
    local sid2
    sid2=$(new_session cdnonectl)
    run_with_timeout node "$BIN_RECORD" --session "$sid2" --signals "S3-security" >/dev/null 2>&1
    assert_eq "CD-16 control: a recorded session takes the recorded path, never the fallback" \
        "opus" "$(d2099_dispatch_model "$wcd" "$sid2" write_code)"
}

# CD-17: MODEL_PRODUCER_LOW override. With the env var set to a non-default alias,
# a low-level dispatch must resolve to that alias, not the hard-coded default.
d2099_env_override_selects_model() {
    local mdp sid
    mdp="$AGENTS_DIR/skills/make-detail-plan/SKILL.md"
    sid=$(new_session cdhaiku)
    run_with_timeout node "$BIN_RECORD" --session "$sid" --signals "" >/dev/null 2>&1
    assert_eq "CD-17 MODEL_PRODUCER_LOW=haiku routes low dispatch to haiku" \
        "haiku" \
        "$(MODEL_PRODUCER_LOW=haiku d2099_dispatch_model "$mdp" "$sid" detail)"
}

# CD-18..24 (#2100 Step 3/5 MOP-2): the outline stage is routed like detail and
# its model= follows MODEL_PRODUCER_LOW / MODEL_PRODUCER_HIGH, recorded or derived
# (CD-18..21, CLI side), and MOP-2 hands that model= to outline-planner (CD-22..24).
d2099_outline_stage_selects_model() {
    local mop sid_lo sid_hi
    mop="$AGENTS_DIR/skills/make-outline-plan/SKILL.md"
    sid_lo=$(new_session cdoutlo)
    run_with_timeout node "$BIN_RECORD" --session "$sid_lo" --signals "S1-multi-file" >/dev/null 2>&1
    assert_eq "CD-18 MOP-2's read (stage outline) answers model=haiku for a recorded low (MODEL_PRODUCER_LOW=haiku)" \
        "haiku" "$(MODEL_PRODUCER_LOW=haiku d2099_dispatch_model "$mop" "$sid_lo" outline)"
    assert_eq "CD-19 the same outline record keeps the sonnet default without the override" \
        "sonnet" "$(d2099_dispatch_model "$mop" "$sid_lo" outline)"

    sid_hi=$(new_session cdouthi)
    run_with_timeout node "$BIN_RECORD" --session "$sid_hi" --signals "S2-architecture" >/dev/null 2>&1
    assert_eq "CD-20 MOP-2's read (stage outline) answers model=haiku for a recorded high (MODEL_PRODUCER_HIGH=haiku)" \
        "haiku" "$(MODEL_PRODUCER_HIGH=haiku d2099_dispatch_model "$mop" "$sid_hi" outline)"

    local derived
    derived=$(MODEL_PRODUCER_LOW=haiku run_with_timeout node "$BIN_DERIVE" --stage outline --signals "" 2>/dev/null \
        | tr -d '\r' | grep -E '^(level|model)=' | paste -sd'|' -)
    assert_eq "CD-21 the NONE fallback derives level=low and model=haiku for stage outline" \
        "level=low|model=haiku" "$derived"

    # CD-22..24: the skill half of the handoff, mirroring CO-9/CO-10 — bounded to
    # the MOP-2 section (MOP-2. up to the next MOP-<n>.), where the value is both
    # read and dispatched. Planned text: `subagent_type: outline-planner`,
    # `model: <model= from MOP-2>` (detail.md Step 5).
    local slot='model: *<[^>]*(MOP-2|model=)[^>]*>'
    assert_eq "CD-22 MOP-2's outline-planner dispatch passes a model: slot bound to MOP-2's model= on the same line" "yes" \
        "$(d2099_section_has_re "$mop" MOP-2 "subagent_type: *\`?outline-planner.*$slot|$slot.*subagent_type: *\`?outline-planner")"
    assert_eq "CD-23 MOP-2 reads the model= line of read-complexity-evaluation --stage outline" "yes" \
        "$(d2099_section_has_re "$mop" MOP-2 'read-complexity-evaluation.*--stage outline')"
    assert_eq "CD-23b MOP-2 names the model= line it hands to the dispatch" "yes" \
        "$(d2099_section_has_re "$mop" MOP-2 'model=')"
    assert_eq "CD-24 MOP-2 never hardcodes a model literal instead" "no" \
        "$(d2099_section_has_re "$mop" MOP-2 'model: *"?(opus|sonnet|haiku)"?[ ,)`]')"
}

d2099_documented_mapping
d2099_recorded_verdict_selects_model
d2099_none_selects_fallback
d2099_env_override_selects_model
d2099_outline_stage_selects_model
