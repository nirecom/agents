#!/bin/bash
# tests/hooks/feature-2099-complexity-stage-routing/consumer-normalize-chain.sh
# Tests: skills/make-detail-plan/SKILL.md, skills/write-tests/SKILL.md, skills/write-code/SKILL.md, bin/workflow/normalize-judge-signals, bin/workflow/derive-complexity-level
# Tags: complexity, routing, consumers, helpers, normalize, scope:issue-specific
# Sourced by ../feature-2099-complexity-stage-routing.sh before consumer-orchestration-cases.sh.
# MDP-3 / WT-6 / WCD-3 fall back through a two-command chain (#2434): the judge's raw text
# goes to <PLANS_DIR>/<sid>-<stage>-judge-raw.txt, normalize-judge-signals writes
# <WORKFLOW_STATE_DIR>/<sid>.control/<stage>-signals.txt, derive-complexity-level --session reads it.
# Both lines are EXTRACTED from the skill and run verbatim; nothing re-encodes the chain.

D2099N_NONE="__NO_COMMAND__"

# skill dir | normalize --stage (hyphen) | derive --stage (underscore) | owning step | level for `SIGNALS: S1-multi-file`.
D2099N_ROWS="make-detail-plan|detail|detail|MDP-3|low
write-tests|write-tests|write_tests|WT-6|low
write-code|write-code|write_code|WCD-3|high"

# The model= alias derive prints for a level, taken from the same table the CLI uses.
d2099n_model_for_level() {
    node -e 'process.stdout.write(require(process.argv[1]).modelForLevel(process.argv[2]))' \
        "$SCRIPT_CHECKOUT_ROOT/hooks/lib/role-model.js" "$1" 2>/dev/null
}

D2099_CONSUMER_PLANS=""
d2099_plans_dir() {
    if [ -z "$D2099_CONSUMER_PLANS" ]; then
        D2099_CONSUMER_PLANS="$TMPDIR_BASE/consumer-plans"
        mkdir -p "$D2099_CONSUMER_PLANS"
    fi
    printf '%s' "$D2099_CONSUMER_PLANS"
}

d2099_skill_file() { echo "$SCRIPT_CHECKOUT_ROOT/skills/$1/SKILL.md"; }

# Fill only the two slots a skill marks as fill-in; judge text never enters a command line.
d2099n_fill_slots() {
    local dir
    dir=$(d2099_plans_dir)
    printf '%s' "$1" | sed -E -e "s#<PLANS_DIR>#$dir#g" -e "s#<session-id>#$2#g"
}

# The one `node ".../bin/workflow/<cli>" --flag value ...` command the skill documents for <cli>
# inside its owning step section; $D2099N_NONE when the section holds none or several.
d2099n_extract_node_cmd() {
    local f="$1" cli="$2" line cmd pat root_tok='AGENTS_MAIN_ROOT'
    line=$(d2099_section_cli_line "$f" "$cli")
    pat='node "\$'"$root_tok"'/bin/workflow/'"$cli"'"( --[a-z-]+ ("[^"]*"|[A-Za-z0-9_-]+))*'
    cmd=$(printf '%s' "$line" | grep -oE -- "$pat" | head -1)
    if [ -n "$cmd" ]; then printf '%s' "$cmd"; else printf '%s' "$D2099N_NONE"; fi
}

d2099n_stage_of() {
    printf '%s' "$1" | grep -oE -- '--stage [A-Za-z_-]+' | head -1 | sed 's/^--stage //'
}

# Where normalize writes (and derive --session reads) one stage's csv.
d2099n_control_path() {
    printf '%s/%s.control/%s-signals.txt' "$WORKFLOW_STATE_DIR" "$1" "$2"
}

# Judge raw text -> normalize -> derive, both extracted from the skill. Prints derive's stdout.
d2099n_run_chain() {
    local f="$1" sid="$2" raw="$3" ncmd dcmd rawpath
    ncmd=$(d2099n_extract_node_cmd "$f" "normalize-judge-signals")
    dcmd=$(d2099n_extract_node_cmd "$f" "derive-complexity-level")
    if [ "$ncmd" = "$D2099N_NONE" ] || [ "$dcmd" = "$D2099N_NONE" ]; then echo "$D2099N_NONE"; return; fi
    ncmd=$(d2099n_fill_slots "$ncmd" "$sid")
    dcmd=$(d2099n_fill_slots "$dcmd" "$sid")
    rawpath=$(printf '%s' "$ncmd" | grep -oE -- '--raw-file "[^"]*"' | head -1 | sed -E 's/^--raw-file "//; s/"$//')
    case "$rawpath" in
        ''|*'<'*|*'>'*) echo "__NO_RAW_FILE_PATH__"; return ;;
    esac
    mkdir -p "$(dirname "$rawpath")"
    printf '%s\n' "$raw" > "$rawpath"
    SESSION_ID="$sid" run_with_timeout bash -c "$ncmd" >/dev/null 2>&1
    SESSION_ID="$sid" run_with_timeout bash -c "$dcmd" 2>/dev/null
}

# A signal csv phrased as the judge would: `SIGNALS: <csv>` (`none` for empty).
d2099n_run_chain_csv() {
    local csv
    csv=$(d2099_csv_for_cli "$3")
    d2099n_run_chain "$1" "$2" "SIGNALS: ${csv:-none}"
}

# The skill's derive line with its `--session` slot swapped for a literal `--signals <csv>`:
# reaches the CLI WITHOUT normalize, so a caller sees what normalize's translation owns.
d2099n_run_derive_signals() {
    local f="$1" csv="$2" dcmd slot rep
    dcmd=$(d2099n_extract_node_cmd "$f" "derive-complexity-level")
    [ "$dcmd" = "$D2099N_NONE" ] && { echo "$D2099N_NONE"; return; }
    slot='--session "<session-id>"'
    rep="--signals \"$csv\""
    dcmd="${dcmd/"$slot"/"$rep"}"
    run_with_timeout bash -c "$dcmd" 2>/dev/null
}

# The raw-file path the skill's Write step targets — extracted independently from
# the normalize --raw-file arg so the two can be compared in CN-0b. The skill
# documents the Write step's target as `<path>` (backtick) in Markdown, followed
# immediately by `(Write tool`.
d2099n_write_step_raw_path() {
    local f="$1" step="$2" sec
    sec=$(d2099_skill_section "$f" "$step")
    printf '%s\n' "$sec" \
        | grep -oE '`[^`]+` \(Write tool' \
        | head -1 \
        | grep -oE '`[^`]+`' \
        | sed 's/`//g'
}

# CN-1..CN-4: the chain must be extractable with the right stage spelling per CLI,
# or every fallback case running it would measure a sentinel.
d2099n_chain_is_real() {
    local name nstage dstage step explevel f ncmd dcmd sid out first
    while IFS='|' read -r name nstage dstage step explevel; do
        [ -n "$name" ] || continue
        f=$(d2099_skill_file "$name")
        d2099_assert_section_cli_unique "CN-0" "$step" "$f" "normalize-judge-signals"
        d2099_assert_section_cli_unique "CN-0a" "$step" "$f" "derive-complexity-level"
        ncmd=$(d2099n_extract_node_cmd "$f" "normalize-judge-signals")
        dcmd=$(d2099n_extract_node_cmd "$f" "derive-complexity-level")
        write_rawpath=$(d2099n_write_step_raw_path "$f" "$step")
        ncmd_rawpath=$(printf '%s' "$ncmd" | grep -oE -- '--raw-file "[^"]*"' | head -1 | sed -E 's/^--raw-file "//; s/"$//')
        assert_eq "CN-0b $step: normalize --raw-file path matches the Write step's target path" \
            "$write_rawpath" "$ncmd_rawpath"
        assert_eq "CN-1 $step: normalize takes the HYPHEN stage form" "$nstage" "$(d2099n_stage_of "$ncmd")"
        assert_eq "CN-1a $step: derive takes the UNDERSCORE stage form" "$dstage" "$(d2099n_stage_of "$dcmd")"
        assert_contains "CN-2 $step: normalize reads the judge's raw FILE" '--raw-file "<PLANS_DIR>/<session-id>-' "$ncmd"
        assert_contains "CN-2a $step: normalize is told the session" '--session "<session-id>"' "$ncmd"
        assert_contains "CN-2b $step: derive reads the csv through the session" '--session "<session-id>"' "$dcmd"
        assert_not_contains "CN-2c $step: derive carries no --signals splice slot" "--signals" "$dcmd"

        sid=$(new_session "cn$step")
        out=$(d2099n_run_chain "$f" "$sid" "SIGNALS: S1-multi-file")
        first=$(printf '%s\n' "$out" | sed -n 1p)
        case "$first" in level=*) ;; *) first="UNPARSEABLE:$first" ;; esac
        assert_eq "CN-3 $step: the extracted chain runs end to end and derive answers the exact level for S1-multi-file" \
            "level=$explevel" "$first"
        assert_eq "CN-3d $step: derive's model= line matches the model for that level" \
            "model=$(d2099n_model_for_level "$explevel")" "$(printf '%s\n' "$out" | sed -n 2p)"
        assert_eq "CN-3a $step: normalize wrote the csv where derive reads it (control-dir file)" \
            "S1-multi-file" "$(tr -d '[:space:]' < "$(d2099n_control_path "$sid" "$nstage")" 2>/dev/null)"
        case "$ncmd" in node\ *) pass "CN-3b $step: normalize command starts with 'node '" ;;
            *) fail "CN-3b $step: normalize command does not start with 'node ': [$ncmd]" ;; esac
        case "$dcmd" in node\ *) pass "CN-3c $step: derive command starts with 'node '" ;;
            *) fail "CN-3c $step: derive command does not start with 'node ': [$dcmd]" ;; esac
    done <<EOF
$D2099N_ROWS
EOF
}

case_begin "normalize-chain-is-real" "bin/workflow/normalize-judge-signals"
d2099n_chain_is_real
case_end

# CN-4/CN-5: edge-case inputs to the chain must not crash and must return predictable tokens.
d2099n_run_chain_edge_cases() {
    local name nstage dstage step explevel f sid out cn5_done=0
    while IFS='|' read -r name nstage dstage step explevel; do
        [ -n "$name" ] || continue
        f=$(d2099_skill_file "$name")
        # CN-4: empty raw text — normalize reduces it to S0-undecidable, derive fails high at every stage
        sid=$(new_session "cn-edge-empty-$step")
        out=$(d2099n_run_chain "$f" "$sid" "" 2>/dev/null | sed -n 1p)
        assert_eq "CN-4 $step empty raw text: derive answers level=high (undecidable fails high)" \
            "level=high" "$out"
        assert_eq "CN-4a $step empty raw text: normalize wrote S0-undecidable to the control file" \
            "S0-undecidable" "$(tr -d '[:space:]' < "$(d2099n_control_path "$sid" "$nstage")" 2>/dev/null)"
        # CN-5: nonexistent skill file — chain must return the sentinel, not crash (once; row-independent)
        [ "$cn5_done" -eq 0 ] || continue
        cn5_done=1
        sid=$(new_session "cn-edge-nofile-$step")
        out=$(d2099n_run_chain "/nonexistent/skill.md" "$sid" "SIGNALS: S1-multi-file" 2>/dev/null)
        if [ "$out" = "$D2099N_NONE" ]; then
            pass "CN-5 $step nonexistent skill file: chain returns sentinel safely"
        else
            fail "CN-5 $step nonexistent skill file: expected sentinel, got [$out]"
        fi
    done <<EOF
$D2099N_ROWS
EOF
}

case_begin "normalize-chain-edge-cases" "bin/workflow/normalize-judge-signals"
d2099n_run_chain_edge_cases
case_end
