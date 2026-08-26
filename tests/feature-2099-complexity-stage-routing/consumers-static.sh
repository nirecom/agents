#!/bin/bash
# tests/feature-2099-complexity-stage-routing/consumers-static.sh
# Tests: skills/make-detail-plan/SKILL.md, skills/write-tests/SKILL.md, skills/write-code/SKILL.md, skills/clarify-intent/SKILL.md, skills/workflow-init/SKILL.md
# Tags: complexity, routing, prompt-static, consumers, scope:issue-specific
# Sourced by ../feature-2099-complexity-stage-routing.sh — helpers come from there.
# The four consumers must each name ONLY their own stage and must never restate a
# threshold: the routing table is the single owner (detail.md D4/P5).
# lang-check: ignore -- rubric-consistency regex asserts bilingual (English/Japanese) phrasing

d2099_has() {
    if grep -qF -- "$2" "$1" 2>/dev/null; then echo "yes"; else echo "no"; fi
}

d2099_has_re() {
    if grep -qE -- "$2" "$1" 2>/dev/null; then echo "yes"; else echo "no"; fi
}

# CS-1..: each reader passes --stage with its own stage name and no other.
d2099_stage_wiring() {
    local mdp="$AGENTS_DIR/skills/make-detail-plan/SKILL.md"
    local wt="$AGENTS_DIR/skills/write-tests/SKILL.md"
    local wcd="$AGENTS_DIR/skills/write-code/SKILL.md"

    assert_eq "CS-1 MDP-3 reads with --stage detail" "yes" \
        "$(d2099_has_re "$mdp" 'read-complexity-evaluation.*--stage detail')"
    assert_eq "CS-2 MDP-3 falls back to derive-complexity-level --stage detail" "yes" \
        "$(d2099_has_re "$mdp" 'derive-complexity-level.*--stage detail')"
    assert_eq "CS-3 make-detail-plan never names another stage" "no" \
        "$(d2099_has_re "$mdp" '--stage (write_tests|write_code)')"

    assert_eq "CS-4 WT-5 reads with --stage write_tests" "yes" \
        "$(d2099_has_re "$wt" 'read-complexity-evaluation.*--stage write_tests')"
    assert_eq "CS-5 WT-5 falls back to derive-complexity-level --stage write_tests" "yes" \
        "$(d2099_has_re "$wt" 'derive-complexity-level.*--stage write_tests')"
    assert_eq "CS-6 write-tests never names another stage" "no" \
        "$(d2099_has_re "$wt" '--stage (detail|write_code)')"
    assert_eq "CS-7 WT-5 consumes the signals= line as task_complexity_signals" "yes" \
        "$(d2099_has "$wt" "task_complexity_signals")"

    assert_eq "CS-8 WCD-3 reads with --stage write_code" "yes" \
        "$(d2099_has_re "$wcd" 'read-complexity-evaluation.*--stage write_code')"
    assert_eq "CS-9 WCD-3 falls back to derive-complexity-level --stage write_code" "yes" \
        "$(d2099_has_re "$wcd" 'derive-complexity-level.*--stage write_code')"
    assert_eq "CS-10 write-code never names another stage" "no" \
        "$(d2099_has_re "$wcd" '--stage (detail|write_tests)')"

    local f
    for f in "$mdp" "$wt" "$wcd"; do
        assert_eq "CS-11 $(basename "$(dirname "$f")") parses the signals= line for its selection reason" "yes" \
            "$(d2099_has "$f" "signals=")"
    done
}

# CS-12..: no consumer may restate a threshold — that is what caused the
# four-way reinterpretation #2099 exists to remove.
d2099_no_thresholds() {
    local f label
    for f in "$AGENTS_DIR/skills/make-detail-plan/SKILL.md" \
             "$AGENTS_DIR/skills/write-tests/SKILL.md" \
             "$AGENTS_DIR/skills/write-code/SKILL.md"; do
        label="$(basename "$(dirname "$f")")"
        assert_eq "CS-12 $label states no file-count threshold" "no" \
            "$(d2099_has_re "$f" '[0-9]+ (or more|\+) *(files|ファイル)')"
        assert_eq "CS-13 $label does not restate the 1-or-more-signals rule" "no" \
            "$(d2099_has_re "$f" '(1|one) or more signals')"
        assert_eq "CS-14 $label does not enumerate escalation signal ids itself" "no" \
            "$(d2099_has_re "$f" 'S1b-wide-change|solo_escalation|legacy_equivalent_escalation')"
    done
}

# One step's OWN section, not the whole file: workflow-init's PM3 bullet names an
# unrelated `/issue-create --verdict`, which a whole-file grep reads as A3a still
# passing a verdict. Bounding is what the producer cases already do.
d2099_step_has() {
    if d2099_skill_section "$1" "$2" | grep -qF -- "$3"; then echo "yes"; else echo "no"; fi
}

# CS-15..: the two write points are symmetric — signals only, never a verdict.
d2099_write_points() {
    local ci="$AGENTS_DIR/skills/clarify-intent/SKILL.md"
    local wi="$AGENTS_DIR/skills/workflow-init/SKILL.md"

    assert_eq "CS-15 clarify-intent CI-C1b still drives record-complexity-and-skip" "yes" \
        "$(d2099_step_has "$ci" CI-C1b "record-complexity-and-skip")"
    # --signals-file, not --signals: a bare `--signals <csv>` would be the #2099
    # PO-INJ splice slot back. `--signals` alone would match either, so the
    # negative half is what carries the contract.
    assert_eq "CS-16 CI-C1b passes the judged csv by file" "yes" \
        "$(d2099_step_has "$ci" CI-C1b "--signals-file")"
    assert_eq "CS-16a CI-C1b carries no --signals <csv> splice slot (PO-INJ)" "no" \
        "$(d2099_step_has "$ci" CI-C1b "--signals <")"
    assert_eq "CS-17 CI-C1b no longer passes --verdict" "no" \
        "$(d2099_step_has "$ci" CI-C1b "--verdict")"

    assert_eq "CS-18 workflow-init A3a still drives record-complexity-and-skip" "yes" \
        "$(d2099_step_has "$wi" A3a "record-complexity-and-skip")"
    assert_eq "CS-19 A3a passes the judged csv by file (CPR-ORTH with CI-C1b)" "yes" \
        "$(d2099_step_has "$wi" A3a "--signals-file")"
    assert_eq "CS-19a A3a carries no --signals <csv> splice slot (PO-INJ)" "no" \
        "$(d2099_step_has "$wi" A3a "--signals <")"
    assert_eq "CS-20 A3a no longer passes --verdict (CPR-ORTH with CI-C1b)" "no" \
        "$(d2099_step_has "$wi" A3a "--verdict")"

    # The judging agents emit signals, never a level.
    local f
    for f in "$ci" "$wi"; do
        assert_eq "CS-21 $(basename "$(dirname "$f")") no longer expects a LEVEL: verdict line" "no" \
            "$(d2099_has "$f" "LEVEL: high")"
    done
}

# CS-22..: mutation probe. CS-1/2/4/5/8/9 are grep assertions, and a grep
# assertion that cannot FAIL is worth nothing. Each consumer is copied to a
# mutant with its `--stage <own>` argument (a) deleted and (b) replaced by a
# foreign stage; the SAME pattern must stop matching on both mutants. This is
# what proves the pattern is anchored on the argument and not on some other
# token that happens to sit on the line.
d2099_stage_pattern_teeth() {
    local mdp="$AGENTS_DIR/skills/make-detail-plan/SKILL.md"
    local wt="$AGENTS_DIR/skills/write-tests/SKILL.md"
    local wcd="$AGENTS_DIR/skills/write-code/SKILL.md"

    local n=22
    local row file stage cli
    # <file>|<own stage>|<cli>
    for row in \
        "$mdp|detail|read-complexity-evaluation" \
        "$mdp|detail|derive-complexity-level" \
        "$wt|write_tests|read-complexity-evaluation" \
        "$wt|write_tests|derive-complexity-level" \
        "$wcd|write_code|read-complexity-evaluation" \
        "$wcd|write_code|derive-complexity-level"; do
        file="${row%%|*}"
        stage="${row#*|}"; stage="${stage%%|*}"
        cli="${row##*|}"
        local label; label="$(basename "$(dirname "$file")")/$cli"
        local pattern="$cli.*--stage $stage"

        # Mutant A: the --stage argument is removed entirely.
        # Mutant B: the --stage argument names a different stage.
        # The ORIGINAL result is asserted in the SAME line as the two mutants,
        # so this cannot pass vacuously: "no/no" on the mutants proves nothing
        # while the pattern matches nothing anywhere. Only original=yes with
        # both mutants no means the pattern is anchored on the argument.
        local dropped="$TMPDIR_BASE/mut-drop-$n.md"
        local swapped="$TMPDIR_BASE/mut-swap-$n.md"
        sed "s/--stage $stage//g" "$file" > "$dropped" 2>/dev/null
        sed "s/--stage $stage/--stage bogus_stage/g" "$file" > "$swapped" 2>/dev/null
        assert_eq "CS-$n $label pattern matches the original and BOTH --stage mutants break it" \
            "original=yes dropped=no swapped=no" \
            "original=$(d2099_has_re "$file" "$pattern") dropped=$(d2099_has_re "$dropped" "$pattern") swapped=$(d2099_has_re "$swapped" "$pattern")"
        n=$((n + 1))
    done
}

# CS-28/CS-29: the consumer-side twin of PO-INJ-3/3b. The judged csv now travels
# to the CLI in a FILE, and an EMPTY file reads back as zero signals -> low — so
# the one thing between an unparseable judgment and the cheap model is the
# documented `S0-undecidable` substitution. CF-5 executes that rule; this pins
# that each step still STATES it, and states the Write-tool-not-Bash rule that
# keeps the csv out of command position. Bounded to each step's own section.
d2099_consumer_fallback_rules() {
    local row name step f
    for row in "make-detail-plan|MDP-3" "write-tests|WT-5" "write-code|WCD-3"; do
        name="${row%%|*}"; step="${row##*|}"
        f="$AGENTS_DIR/skills/$name/SKILL.md"
        assert_eq "CS-28 $step substitutes S0-undecidable for an unparseable or unsafe judged csv" "yes" \
            "$(d2099_step_has "$f" "$step" "S0-undecidable")"
        assert_eq "CS-29 $step writes that csv with the Write tool, never Bash" "yes" \
            "$(d2099_step_has "$f" "$step" "Write tool")"
    done
}

d2099_stage_wiring
d2099_no_thresholds
d2099_write_points
d2099_consumer_fallback_rules
d2099_stage_pattern_teeth
