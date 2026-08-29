#!/bin/bash
# tests/feature-2099-complexity-stage-routing/consumer-dispatch-cases.sh
# Tests: skills/make-detail-plan/SKILL.md, skills/write-tests/SKILL.md, skills/write-code/SKILL.md, bin/workflow/read-complexity-evaluation, bin/workflow/derive-complexity-level
# Tags: complexity, routing, consumers, integration, model-selection, scope:issue-specific
# Sourced by ../feature-2099-complexity-stage-routing.sh — helpers come from there.
# consumers-static.sh greps the three SKILL.md files, which proves the text is written,
# not that a RECORDED verdict reaches the Agent tool as the right model. Here the real
# CLI answers and the level maps through the mapping READ OUT OF the skill file; the
# Agent call itself stays the TL3 gap the parent runner already declares.

# d2099_doc_model_for <skill.md> <level> — the model that FILE says the level maps
# to. Never a literal: the expectation is derived from the document under test.
d2099_doc_model_for() {
    # An empty level would make the pattern degenerate to " → opus" and match the
    # FIRST mapping in the file, turning "no level at all" into a plausible answer.
    case "$2" in high|low) ;; *) echo "NO_LEVEL"; return ;; esac
    grep -oE "$2 *(→|->) *(opus|sonnet)" "$1" 2>/dev/null \
        | head -1 | sed -E 's/.*(→|->) *//'
}

# d2099_dispatch_model <skill.md> <sid> <stage> — replays the consumer's MDP-3 /
# WT-5 / WCD-3 decision procedure end to end and prints what it selected:
# a model name, or FALLBACK when the CLI answered NONE.
d2099_dispatch_model() {
    local f="$1" sid="$2" stage="$3" out first lvl model
    out=$(run_with_timeout node "$BIN_READ" --session "$sid" --stage "$stage" 2>/dev/null)
    first=$(printf '%s\n' "$out" | head -1)
    [ "$first" = "NONE" ] && { echo "FALLBACK"; return; }
    case "$first" in
        level=*) lvl="${first#level=}" ;;
        *) echo "UNPARSEABLE:$first"; return ;;
    esac
    model=$(d2099_doc_model_for "$f" "$lvl")
    [ -n "$model" ] || { echo "NO_DOCUMENTED_MAPPING_FOR:$lvl"; return; }
    echo "$model"
}

# CD-1: the mapping each consumer documents must be the same one, in both
# directions. If this row is wrong every assertion below measures the wrong
# thing, so it is asserted first and independently.
d2099_documented_mapping() {
    local f label
    for f in "$AGENTS_DIR/skills/make-detail-plan/SKILL.md" \
             "$AGENTS_DIR/skills/write-tests/SKILL.md" \
             "$AGENTS_DIR/skills/write-code/SKILL.md"; do
        label="$(basename "$(dirname "$f")")"
        assert_eq "CD-1 $label documents high→opus / low→sonnet and nothing else" \
            "high=opus low=sonnet" \
            "high=$(d2099_doc_model_for "$f" high) low=$(d2099_doc_model_for "$f" low)"
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
    assert_eq "CD-3 WT-5 dispatches sonnet from the SAME record (stage write_tests)" \
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
    assert_eq "CD-7 WT-5 dispatches opus from a recorded high (S3-security)" \
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
        # derive for THIS stage. Both are what MDP-3/WT-5/WCD-3 spell out.
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

d2099_documented_mapping
d2099_recorded_verdict_selects_model
d2099_none_selects_fallback
