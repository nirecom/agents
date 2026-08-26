#!/bin/bash
# tests/feature-2099-complexity-stage-routing/consumer-fallback-cases.sh
# Tests: skills/make-detail-plan/SKILL.md, skills/write-tests/SKILL.md, skills/write-code/SKILL.md, skills/_shared/judge-task-complexity.md, bin/workflow/derive-complexity-level
# Tags: complexity, routing, consumers, fallback, judgment-parsing, scope:issue-specific
# Sourced by ../feature-2099-complexity-stage-routing.sh AFTER
# consumer-orchestration-cases.sh — its command-extraction helpers are reused.

# The judge's output label, read from the rubric so this test never becomes the
# format's second owner (CPR-SSOT).
d2099cf_label() {
    grep -oE 'SIGNALS:' "$RUBRIC" 2>/dev/null | head -1
}

# The text step itself: a judgment's LAST label line, reduced to a csv.
d2099cf_extract() {
    local label="$1"
    grep -E "^[[:space:]]*$label" | tail -1 | sed -E "s/^[[:space:]]*$label[[:space:]]*//" | tr -d ' '
}

# What the skill says to do when no label line parses out of its own judgment.
# Documenting nothing means malformed judgment output has no defined behaviour.
d2099cf_unparseable_token() {
    grep -oE 'S0-undecidable' "$1" 2>/dev/null | head -1
}

# One consumer's whole fallback, driven by the documents under test:
#   judgment prose -> extraction -> the skill's own derive command -> level
# The sibling suites hand signal ids straight to each documented command, so the
# half of MDP-3 / WT-5 / WCD-3 that runs when nothing was persisted stays untested:
# the ids the skill wrote as PROSE must become a `--signals` argument. Running
# that text step for real is what stops an unparseable judgment from reading as
# "zero signals" — which routes LOW, the cheap model on a job nobody sized.
d2099cf_level() {
    local f="$1" sid="$2" judgment="$3" label csv cmd out
    label=$(d2099cf_label)
    [ -n "$label" ] || { echo "NO_OUTPUT_LABEL_IN_RUBRIC"; return; }
    csv=$(printf '%s\n' "$judgment" | d2099cf_extract "$label")
    if [ -z "$csv" ]; then
        # Nothing parseable: falling through with an empty csv would mean "zero
        # signals" = low, so the skill must document an answer for this. The
        # reserved token is a real signal id, so it is NOT translated below.
        csv=$(d2099cf_unparseable_token "$f")
        [ -n "$csv" ] || { echo "NO_UNPARSEABLE_RULE_IN_SKILL"; return; }
    else
        # The judge's zero-signal MARKER becomes the CLI's zero-signal VALUE.
        # Handing `none` through verbatim would route undecidable-high — see
        # d2099_csv_for_cli in the runner (round-9 C1).
        csv=$(d2099_csv_for_cli "$csv")
    fi
    cmd=$(d2099_extract_cmd "$f" "derive-complexity-level")
    [ -n "$cmd" ] || { echo "NO_DERIVE_COMMAND_IN_SKILL"; return; }
    out=$(d2099_run_skill_cmd "$cmd" "$sid" "$csv" | head -1)
    case "$out" in
        level=*) printf '%s' "${out#level=}" ;;
        *) printf 'UNPARSEABLE:%s' "$out" ;;
    esac
}

# A judgment as a skill actually writes one: prose first, the label line last.
d2099cf_judgment() {
    printf 'I read skills/_shared/judge-task-complexity.md and evaluated every signal\n'
    printf 'against the task and the outline artifacts. Three helper modules change,\n'
    printf 'no security boundary is involved, and the plan is short.\n'
    printf '%s\n' "$1"
}

# CF-1: the extraction must have teeth before anything downstream means much.
d2099cf_extraction_is_real() {
    local label got
    label=$(d2099cf_label)
    if [ -z "$label" ]; then
        fail "CF-1 the rubric states no 'SIGNALS:' output label, so the fallback has no format to parse and every case below is unattributable"
        return
    fi
    pass "CF-1 the rubric states the judge's output label ($label)"

    got=$(d2099cf_judgment "SIGNALS: S1-multi-file, S2-architecture" | d2099cf_extract "$label")
    assert_eq "CF-1a the text step pulls the ids out of judgment prose, whitespace and all" \
        "S1-multi-file,S2-architecture" "$got"
    got=$(d2099cf_judgment "SIGNALS: none" | d2099cf_extract "$label")
    assert_eq "CF-1b ... and reports a zero-signal judgment as the rubric spells it" "none" "$got"
    got=$(d2099cf_judgment "The signals are listed above." | d2099cf_extract "$label")
    assert_eq "CF-1c ... and yields nothing at all when there is no label line" "" "$got"
}

# --- CF-9: the zero-signal marker -> CLI argument translation -----------------
# `SIGNALS: none` is the judge's "nothing matched" MARKER; the CLIs' zero-signal
# value is the empty csv. Three orchestration paths perform this translation
# (this file, producer-orchestration-cases.sh, live-e2e-cases.sh) and all three
# call the runner's d2099_csv_for_cli — so its truth table is pinned once here,
# and each site's use is asserted in its own suite (round-9 C1).
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
S1-multi-file|S1-multi-file
S1-multi-file,S2-architecture|S1-multi-file,S2-architecture
nonexistent-signal|nonexistent-signal
EOF
}

# CF-10: the translation is LOAD-BEARING, not cosmetic. The same consumer, the
# same extracted derive command, one argument apart: the translated empty csv
# must route low while the untranslated literal `none` routes undecidable-high.
# Without this contrast CF-4 could be satisfied by a CLI that answers low to
# anything it does not recognize — the silent-cheap-model failure #2099 is about.
d2099cf_untranslated_marker_is_high() {
    local name stage step sid f cmd got
    sid=$(new_session cfmarker)
    while IFS='|' read -r name stage step _; do
        [ -n "$name" ] || continue
        f=$(d2099_skill_file "$name")
        cmd=$(d2099_extract_cmd "$f" "derive-complexity-level")
        if [ -z "$cmd" ]; then
            fail "CF-10 $step: unattributable — no derive command to hand the untranslated marker to"
            continue
        fi
        got=$(d2099_run_skill_cmd "$cmd" "$sid" "none" | head -1)
        case "$got" in
            level=high) pass "CF-10 $step: the UNtranslated literal 'none' routes undecidable-high, so the translation is what produces CF-4's low" ;;
            level=low)  fail "CF-10 $step: the literal 'none' routed LOW — it is being treated as a signal id the routing table knows, so CF-4 would pass with or without the translation" ;;
            *)          fail "CF-10 $step: the literal 'none' produced neither level=high nor level=low: got [$got]" ;;
        esac
    done <<EOF
$D2099_CONSUMERS
EOF
}

# CF-2..CF-4: the well-formed path, per consumer. The csv is the one extraction
# produced — never a literal — and CF-3 requires it to CHANGE the answer, ruling
# out a pipeline that ignores it and decides from somewhere else.
d2099cf_wellformed_reaches_derive() {
    local name stage step sid f got want contrast
    sid=$(new_session cfnone)   # created, never recorded into: NONE -> fallback
    while IFS='|' read -r name stage step _; do
        [ -n "$name" ] || continue
        f=$(d2099_skill_file "$name")

        assert_eq "CF-2 $step: an unrecorded session really is on the fallback path" \
            "FALLBACK" "$(d2099_orch_model "$f" "$sid")"

        # S1-multi-file is the #2099 case: low for detail and write_tests, high
        # for write_code (detail.md D2), from ONE extracted judgment.
        case "$stage" in write_code) want="high" ;; *) want="low" ;; esac
        got=$(d2099cf_level "$f" "$sid" "$(d2099cf_judgment 'SIGNALS: S1-multi-file')")
        assert_eq "CF-2a $step: a well-formed judgment routes its own stage ($stage) via the extracted csv" \
            "$want" "$got"
        assert_eq "CF-2b $step: ... and the file's own mapping turns that into a model" \
            "$(d2099_orch_model_for "$f" "$want")" "$(d2099_orch_model_for "$f" "$got")"

        # Contrast: change ONLY the ids, and demand the answer MOVE for this
        # stage. Which ids do that is per-stage, because no single signal flips
        # all three away from CF-2a's low/low/high (detail.md D2):
        #   detail      S1 low  -> S2-architecture is solo_escalation for detail: high
        #   write_tests S1 low  -> S3-security is solo_escalation for write_tests: high
        #   write_code  S1 high -> `none` is the only way down: zero signals, low
        # A fixed csv here would leave at least one stage asserting the level it
        # already had, which no amount of ignoring the extraction could fail.
        case "$stage" in
            detail)      contrast="S2-architecture"; want="high" ;;
            write_tests) contrast="S3-security";     want="high" ;;
            *)           contrast="none";            want="low" ;;
        esac
        got=$(d2099cf_level "$f" "$sid" "$(d2099cf_judgment "SIGNALS: $contrast")")
        assert_eq "CF-3 $step: swapping S1-multi-file for '$contrast' moves $stage off its CF-2a level — the extracted csv is what the command acted on" \
            "$want" "$got"

        # The rubric's own zero-signal wording must reach the cheap model, or the
        # fallback has no low path at all.
        got=$(d2099cf_level "$f" "$sid" "$(d2099cf_judgment 'SIGNALS: none')")
        assert_eq "CF-4 $step: the rubric's zero-signal wording routes low, not undecidable-high" \
            "low" "$got"
    done <<EOF
$D2099_CONSUMERS
EOF
}

# CF-5: judgments a drifted or pre-#2099 agent plausibly emits; none is parseable
# under the current contract. A quiet `low` is the outcome that must never follow:
# an unreadable judgment is an unknown task, and detail.md D1 step 5 sends unknown
# to the stage's undecidable_level — high on all three stages.
D2099CF_MALFORMED='legacy-level-line|LEVEL: high | S1-multi-file
legacy-level-low|LEVEL: low
legacy-verdict|VERDICT: opus (signals: S1-multi-file)
wrong-case|signals: S1-multi-file
wrong-case-title|Signals: S1-multi-file
no-colon|SIGNALS S1-multi-file
missing-field|Evaluated every signal; nothing further to report.
prose-only|The task touches three files, so it is a multi-file change.'

d2099cf_malformed_fails_high() {
    local name stage step sid f label raw got
    sid=$(new_session cfmal)
    while IFS='|' read -r name stage step _; do
        [ -n "$name" ] || continue
        f=$(d2099_skill_file "$name")
        while IFS='|' read -r label raw; do
            [ -n "$label" ] || continue
            got=$(d2099cf_level "$f" "$sid" "$(d2099cf_judgment "$raw")")
            case "$got" in
                high)
                    pass "CF-5 [$label] $step fails HIGH on a judgment it cannot parse" ;;
                low)
                    fail "CF-5 [$label] $step read an UNPARSEABLE judgment as zero signals and routed LOW — the cheap model gets a task nobody sized. Judgment: [$raw]" ;;
                NO_UNPARSEABLE_RULE_IN_SKILL)
                    fail "CF-5 [$label] $step documents no rule for a judgment with no parseable signal line, so a malformed judgment falls through as zero signals -> low" ;;
                *)
                    fail "CF-5 [$label] $step neither routed high nor low on an unparseable judgment: got [$got]" ;;
            esac
        done <<INNER
$D2099CF_MALFORMED
INNER
    done <<EOF
$D2099_CONSUMERS
EOF
}

# --- CF-6: what the SKILL FILES actually document as the extraction step -------
# The helper above is test code, so on its own it proves only that the test can
# parse a SIGNALS line. Two things make it accountable to the real documents: the
# label comes from the rubric (CF-1), and the corpus below is mutated from the
# rubric's OWN example line rather than hand-written. The third — executing the
# skill's extraction COMMAND — is only possible if a skill documents one, so CF-6
# asserts the premise: MDP-3/WT-5/WCD-3 describe the step in prose. The moment one
# grows a literal grep/sed/cut/awk pipeline over SIGNALS, this suite must execute
# THAT line instead of the mutation substitute, and this case says so out loud.
D2099CF_EXTRACT_CMD_RE='(grep|sed|cut|awk|tr)[^`]*SIGNALS|SIGNALS[^`]*\|[[:space:]]*(grep|sed|cut|awk|tr)'

d2099cf_extraction_step_is_prose() {
    local name stage step f hit
    while IFS='|' read -r name stage step _; do
        [ -n "$name" ] || continue
        f=$(d2099_skill_file "$name")
        hit=$(grep -oE "$D2099CF_EXTRACT_CMD_RE" "$f" 2>/dev/null | head -1)
        if [ -n "$hit" ]; then
            fail "CF-6 $step now documents a literal SIGNALS extraction command [$hit] — this suite's mutation-boundary substitute is no longer the right test: extract and EXECUTE that command line instead (round-6 C3)"
        else
            pass "CF-6 $step documents the SIGNALS extraction as prose, so the boundary mutations below are the accountable substitute"
        fi
    done <<EOF
$D2099_CONSUMERS
EOF
}

# The rubric's own example of the label line — the format the skills tell the
# judge to emit. Read from the file so a rewritten rubric changes this corpus.
d2099cf_rubric_example() {
    grep -oE 'SIGNALS: *[^`<]*' "$RUBRIC" 2>/dev/null \
        | grep -vE 'SIGNALS: *$' | head -1 | sed -E 's/[[:space:]]+$//'
}

# CF-7: MUTATIONS of that real example. Each is a plausible drift in what the
# judge emits or what a skill tells it to emit; none is parseable under the
# contract, and the CLI-facing boundary must answer high for every one. A single
# `low` here is a judgment nobody sized reaching the cheap model.
d2099cf_mutations_fail_high() {
    local example name stage step f label mutated got sid
    sid=$(new_session cfmut)   # created, never recorded into: NONE -> fallback
    example=$(d2099cf_rubric_example)
    if [ -z "$example" ]; then
        fail "CF-7 the rubric carries no concrete 'SIGNALS: <ids>' example, so the mutation corpus cannot be derived from real skill content"
        return
    fi
    pass "CF-7 the mutation corpus is derived from the rubric's own example line ($example)"

    while IFS='|' read -r name stage step _; do
        [ -n "$name" ] || continue
        f=$(d2099_skill_file "$name")
        for label in lowercase-label no-colon renamed-label spaced-colon inline-prefix; do
            case "$label" in
                lowercase-label) mutated=$(printf '%s' "$example" | sed -E 's/^SIGNALS/signals/') ;;
                no-colon)        mutated=$(printf '%s' "$example" | sed -E 's/^SIGNALS:/SIGNALS/') ;;
                renamed-label)   mutated=$(printf '%s' "$example" | sed -E 's/^SIGNALS:/LEVEL:/') ;;
                spaced-colon)    mutated=$(printf '%s' "$example" | sed -E 's/^SIGNALS:/SIGNALS :/') ;;
                inline-prefix)   mutated="The verdict is $example" ;;
            esac
            got=$(d2099cf_level "$f" "$sid" "$(d2099cf_judgment "$mutated")")
            case "$got" in
                high) pass "CF-7 [$label] $step fails high on a mutated label line ($mutated)" ;;
                low)  fail "CF-7 [$label] $step read the mutated line [$mutated] as zero signals and routed LOW" ;;
                *)    fail "CF-7 [$label] $step neither routed high nor low on [$mutated]: got [$got]" ;;
            esac
        done
    done <<EOF
$D2099_CONSUMERS
EOF
}

# --- CF-8: prompt-to-shell injection through each consumer's fallback ----------
# The ids in a judgment are PROSE the orchestrator turns into a `--signals`
# argument, so a judge that was talked round — or one reading a hostile intent.md —
# can put shell syntax where a signal id belongs. Two things must hold on every
# consumer: nothing executes (a canary file stays absent), and the routing lands
# HIGH, because a payload is by definition not a recognized signal id.
# Delimited with `%` — a `|` row would be split by the reader itself.
D2099CF_HOSTILE='cmd-substitution%SIGNALS: S3-security,$(touch @CANARY@)
backticks%SIGNALS: S3-security,`touch @CANARY@`
semicolon%SIGNALS: S3-security; touch @CANARY@
and-chain%SIGNALS: S3-security && touch @CANARY@
pipe-to-shell%SIGNALS: S3-security | touch @CANARY@
zero-signal-lure%SIGNALS: none && touch @CANARY@
redirect%SIGNALS: S1-multi-file > @CANARY@'

d2099cf_injection_is_inert() {
    local name stage step sid f label raw payload canary got i=0
    sid=$(new_session cfinj)
    while IFS='|' read -r name stage step _; do
        [ -n "$name" ] || continue
        f=$(d2099_skill_file "$name")
        while IFS='%' read -r label raw; do
            [ -n "$label" ] || continue
            i=$((i + 1))
            canary="$TMPDIR_BASE/d2099-cf-canary-$i.txt"
            rm -f "$canary"
            payload=$(printf '%s' "$raw" | sed -E "s#@CANARY@#$canary#g")

            got=$(d2099cf_level "$f" "$sid" "$(d2099cf_judgment "$payload")")

            if [ -e "$canary" ]; then
                fail "CF-8 [$label] $step: a hostile judgment EXECUTED through the documented command construction (canary $canary created) — the ids a judge writes reach a shell unquoted"
                rm -f "$canary"
            else
                pass "CF-8 [$label] $step: a hostile judgment executes nothing on the way to the derive command"
            fi

            case "$got" in
                high) pass "CF-8a [$label] $step: ... and the hostile payload routes HIGH, never a silent low" ;;
                low)  fail "CF-8a [$label] $step: a hostile payload routed LOW — injected text was read as a valid zero-signal judgment. Payload: [$payload]" ;;
                *)    fail "CF-8a [$label] $step: a hostile payload routed neither high nor low: got [$got]" ;;
            esac
        done <<INNER
$D2099CF_HOSTILE
INNER
    done <<EOF
$D2099_CONSUMERS
EOF
}

# --- CF-11: exactly one of --signals / --signals-file --------------------------
# The fallback now hands the judged csv over by FILE, so the CLI must refuse an
# AMBIGUOUS call (both flags — which source wins is unknowable to the caller) and
# an ABSENT one (neither — a level derived from nothing at all). Either accepted
# silently would put the fallback back on a csv nobody can account for. The
# producer side pins the same rule at PO-INJ-4/5 (CPR-ORTH); the rule is
# stage-independent, so one representative consumer stage carries it here.
d2099cf_signals_flag_arity() {
    local f out rc
    f="$(d2099_plans_dir)/cf-arity-signals.txt"
    printf 'S1-multi-file' > "$f"

    rc=0
    out=$(run_with_timeout node "$BIN_DERIVE" --stage detail --signals "S1-multi-file" \
        --signals-file "$f" 2>&1) || rc=$?
    assert_eq "CF-11 the derive CLI rejects --signals and --signals-file together (exit 1)" "1" "$rc"
    assert_contains "CF-11a ... with its own documented mutual-exclusion message" \
        "mutually exclusive" "$out"
    assert_not_contains "CF-11b ... and answers no level at all, so no caller reads one out of a rejected call" \
        "level=" "$out"

    rc=0
    out=$(run_with_timeout node "$BIN_DERIVE" --stage detail 2>&1) || rc=$?
    assert_eq "CF-11c the derive CLI rejects neither flag being passed (exit 1)" "1" "$rc"
    assert_contains "CF-11d ... with its own documented required-flag message" "is required" "$out"
    assert_not_contains "CF-11e ... and likewise answers no level" "level=" "$out"

    # Teeth: the SAME file passed alone is accepted and routes. Without this row
    # CF-11/CF-11c would equally pass on a CLI that rejects --signals-file outright.
    rc=0
    out=$(run_with_timeout node "$BIN_DERIVE" --stage detail --signals-file "$f" 2>&1) || rc=$?
    assert_eq "CF-11f ... while that same file passed ALONE is accepted and derives detail's level" \
        "0 level=low" "$rc $(printf '%s\n' "$out" | head -1)"
}

d2099cf_extraction_is_real
d2099cf_translation_table
d2099cf_signals_flag_arity
d2099cf_untranslated_marker_is_high
d2099cf_wellformed_reaches_derive
d2099cf_malformed_fails_high
d2099cf_extraction_step_is_prose
d2099cf_mutations_fail_high
d2099cf_injection_is_inert
