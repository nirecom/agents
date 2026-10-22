#!/bin/bash
# tests/hooks/feature-2099-complexity-stage-routing/consumer-normalize-chain.sh
# Tests: skills/make-detail-plan/SKILL.md, skills/write-tests/SKILL.md, skills/write-code/SKILL.md, bin/workflow/normalize-judge-signals, bin/workflow/derive-complexity-level
# Tags: complexity, routing, consumers, helpers, normalize, jev, shared-procedure, scope:issue-specific
# Sourced by the feature-2099-complexity-stage-routing-*.sh entrypoints before consumer-orchestration-cases.sh.
# Since #2460 MDP-3 / WT-6 / WCD-3 only name skills/_shared/jev-two-stage-judge.md with a point
# and a stage; the chain itself (JJ-1 query -> answer file -> JJ-3 finalize -> JJ-4 derive) lives
# there. The point/stage are read off the skill, the three commands off the shared procedure, and
# run verbatim with JEV off, so the subagent's answer is the judgment; nothing re-encodes the chain.

D2099N_NONE="__NO_COMMAND__"

# skill dir | stage (hyphen) | derive --stage (underscore) | owning step | level for `SIGNALS: S3-security`.
D2099N_ROWS="make-detail-plan|detail|detail|MDP-3|low
write-tests|write-tests|write_tests|WT-6|high
write-code|write-code|write_code|WCD-3|high"

# jev-judge resolves the repository from its cwd: a throwaway one, never the worktree.
D2099N_REPO="$TMPDIR_BASE/consumer-repo"
mkdir -p "$D2099N_REPO"
git init -q "$D2099N_REPO"
git -C "$D2099N_REPO" config core.hooksPath /dev/null
D2099N_FIN_OUT="$TMPDIR_BASE/consumer-chain-finalize.txt"

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

# `<point>|<stage>` of the ONE shared-procedure reference in a skill's owning step; empty when
# the step holds none or several.
d2099n_ref() {
    local line
    line=$(d2099_skill_section "$1" "$2" | grep -F 'jev-two-stage-judge.md')
    [ "$(printf '%s\n' "$line" | grep -c .)" = "1" ] || return 0
    printf '%s|%s' "$(printf '%s' "$line" | sed -nE 's/.*point=`([a-z-]+)`.*/\1/p')" \
        "$(printf '%s' "$line" | sed -nE 's/.*stage=`([a-z-]+)`.*/\1/p')"
}

# The one `node ".../bin/workflow/<cli>" ...` command the shared procedure documents for <cli>
# in one JJ section; $D2099N_NONE when that section holds none or several.
d2099n_jj_cmd() {
    local cmds root_tok='AGENTS_MAIN_ROOT'
    cmds=$(d2099_raw_section "$D2099_JJ_FILE" "$1" \
        | grep -oE -- '`node "\$'"$root_tok"'/bin/workflow/'"$2"'"[^`]*`' | sed 's/`//g')
    if [ "$(printf '%s\n' "$cmds" | grep -c .)" = "1" ]; then printf '%s' "$cmds"; else printf '%s' "$D2099N_NONE"; fi
}

# Fill the procedure's own slots: <cmd> <sid> <point> <stage> <ticket> <csv>.
d2099n_fill() {
    local cmd="$1"
    cmd="${cmd//"<SESSION_ID>"/$2}"
    cmd="${cmd//"<P>"/$3}"
    cmd="${cmd//"<S with _ for ->"/${4//-/_}}"
    cmd="${cmd//"<S>"/$4}"
    cmd="${cmd//"<TICKET>"/$5}"
    cmd="${cmd//"<SIGNALS_CSV>"/$6}"
    printf '%s' "$cmd"
}

d2099n_stage_of() {
    printf '%s' "$1" | grep -oE -- '--stage [A-Za-z_-]+' | head -1 | sed 's/^--stage //'
}

d2099n_kv() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }

# Where finalize fixes one stage's csv.
d2099n_control_path() {
    printf '%s/%s.control/%s-signals.txt' "$WORKFLOW_STATE_DIR" "$1" "$2"
}

d2099n_step_of() {
    printf '%s\n' "$D2099N_ROWS" | awk -F'|' -v n="$(basename "$(dirname "$1")")" '$1 == n { print $4 }'
}

d2099n_jj_run() {
    (cd "$D2099N_REPO" && JEV=off run_with_timeout bash -c "$1" 2>/dev/null)
}

# JJ-1 only, for one skill: prints query's KEY=VALUE output.
d2099n_run_query() {
    local f="$1" sid="$2" ref qcmd
    ref=$(d2099n_ref "$f" "$(d2099n_step_of "$f")")
    qcmd=$(d2099n_jj_cmd JJ-1 jev-judge)
    if [ -z "$ref" ] || [ "$qcmd" = "$D2099N_NONE" ]; then echo "$D2099N_NONE"; return; fi
    d2099n_jj_run "$(d2099n_fill "$qcmd" "$sid" "${ref%%|*}" "${ref#*|}" "" "")"
}

# Subagent answer -> query -> answer file -> finalize -> derive. Prints derive's stdout;
# finalize's own output is left in $D2099N_FIN_OUT. <files> is the size of the WCD-2 list
# (write-code only; default 1, 0 leaves the list missing).
d2099n_run_chain() {
    local f="$1" sid="$2" raw="$3" files="${4:-1}" ref stage fcmd dcmd q fin answer i
    ref=$(d2099n_ref "$f" "$(d2099n_step_of "$f")")
    fcmd=$(d2099n_jj_cmd JJ-3 jev-judge)
    dcmd=$(d2099n_jj_cmd JJ-4 derive-complexity-level)
    if [ -z "$ref" ] || [ "$fcmd" = "$D2099N_NONE" ] || [ "$dcmd" = "$D2099N_NONE" ]; then
        echo "$D2099N_NONE"; return
    fi
    stage="${ref#*|}"
    if [ "$stage" = "write-code" ] && [ "$files" -gt 0 ]; then
        for ((i = 1; i <= files; i++)); do echo "src/f$i.js"; done > "$WORKFLOW_PLANS_DIR/$sid-write-code-files.txt"
    fi
    q=$(d2099n_run_query "$f" "$sid")
    answer=$(d2099n_kv "$q" ANSWER_FILE)
    case "$answer" in
        ''|-) echo "__NO_ANSWER_FILE__"; return ;;
    esac
    printf '%s\n' "${raw:-NO_ANSWER}" > "$answer"
    fin=$(d2099n_jj_run "$(d2099n_fill "$fcmd" "$sid" "${ref%%|*}" "$stage" "$(d2099n_kv "$q" TICKET)" "")")
    printf '%s\n' "$fin" > "$D2099N_FIN_OUT"
    [ "$(d2099n_kv "$fin" RESULT)" = "ok" ] || { echo "__FINALIZE_NOT_OK__"; return; }
    d2099n_jj_run "$(d2099n_fill "$dcmd" "$sid" "${ref%%|*}" "$stage" "" "$(d2099n_kv "$fin" SIGNALS_CSV)")"
}

# A signal csv phrased as the judge would: `SIGNALS: <csv>` (`none` for empty).
d2099n_run_chain_csv() {
    local csv
    csv=$(d2099_csv_for_cli "$3")
    d2099n_run_chain "$1" "$2" "SIGNALS: ${csv:-none}" "${4:-1}"
}

# CN-1..CN-2c: the three commands must be extractable from the shared procedure with the slots
# the chain fills, or every fallback case running it would measure a sentinel.
d2099n_procedure_is_extractable() {
    local qcmd fcmd dcmd c
    qcmd=$(d2099n_jj_cmd JJ-1 jev-judge)
    fcmd=$(d2099n_jj_cmd JJ-3 jev-judge)
    dcmd=$(d2099n_jj_cmd JJ-4 derive-complexity-level)
    assert_contains "CN-1 JJ-1: query takes the stage as the caller spells it (HYPHEN form)" ' query --session "<SESSION_ID>" --point <P> --stage <S>' "$qcmd"
    assert_eq "CN-1a JJ-4: derive takes the UNDERSCORE stage form" "write_tests" \
        "$(d2099n_stage_of "$(d2099n_fill "$dcmd" s complexity-judge write-tests t "")")"
    assert_contains "CN-2 JJ-3: finalize is told the session" '--session "<SESSION_ID>"' "$fcmd"
    assert_contains "CN-2a JJ-3: finalize is told the ticket query issued" '--ticket <TICKET>' "$fcmd"
    assert_contains "CN-2b JJ-4: derive takes the csv finalize printed" '--signals "<SIGNALS_CSV>"' "$dcmd"
    assert_not_contains "CN-2c JJ-4: derive never re-reads the fixed signals file through the session" "--session" "$dcmd"
    for c in "$qcmd" "$fcmd" "$dcmd"; do
        case "$c" in node\ *) pass "CN-3b shared-procedure command starts with 'node ': [${c%% --*}]" ;;
            *) fail "CN-3b shared-procedure command does not start with 'node ': [$c]" ;; esac
    done
}

# CN-0/CN-3: each consumer step names the procedure once with its own stage, and the chain
# built from that reference runs end to end.
d2099n_chain_is_real() {
    local name nstage dstage step explevel f sid out first q ticket answer where
    while IFS='|' read -r name nstage dstage step explevel; do
        [ -n "$name" ] || continue
        f=$(d2099_skill_file "$name")
        assert_eq "CN-0 $step: references the shared procedure exactly once, as complexity-judge at its own stage" \
            "complexity-judge|$nstage" "$(d2099n_ref "$f" "$step")"
        assert_eq "CN-0a $step: runs no normalize-judge-signals of its own" "0" \
            "$(d2099_skill_section "$f" "$step" | grep -cF 'normalize-judge-signals')"

        sid=$(new_session "cnq$step")
        q=$(d2099n_run_query "$f" "$sid")
        ticket=$(d2099n_kv "$q" TICKET)
        answer=$(d2099n_kv "$q" ANSWER_FILE)
        if [ "$(dirname "${answer:-/nonexistent/x}")" -ef "$WORKFLOW_PLANS_DIR" ]; then where="plans-dir"; else where="elsewhere"; fi
        assert_eq "CN-0b $step: query hands back an answer file in the plans dir, scoped to this session and ticket" \
            "plans-dir|$sid-jev-${ticket:-NO_TICKET}-answer.txt" "$where|$(basename "$answer")"
        assert_eq "CN-0c $step: with Jev off the query delegates to the complexity-judge subagent" \
            "need-subagent|complexity-judge" "$(d2099n_kv "$q" RESULT)|$(d2099n_kv "$q" SUBAGENT)"

        sid=$(new_session "cn$step")
        out=$(d2099n_run_chain "$f" "$sid" "SIGNALS: S3-security")
        first=$(printf '%s\n' "$out" | sed -n 1p)
        case "$first" in level=*) ;; *) first="UNPARSEABLE:$first" ;; esac
        assert_eq "CN-3 $step: the extracted chain runs end to end and derive answers the exact level for S3-security" \
            "level=$explevel" "$first"
        assert_eq "CN-3d $step: derive's model= line matches the model for that level" \
            "model=$(d2099n_model_for_level "$explevel")" "$(printf '%s\n' "$out" | sed -n 2p)"
        assert_eq "CN-3a $step: finalize fixed the csv it printed in the control-dir file" \
            "S3-security|S3-security" \
            "$(d2099n_kv "$(cat "$D2099N_FIN_OUT")" SIGNALS_CSV)|$(tr -d '[:space:]' < "$(d2099n_control_path "$sid" "$nstage")" 2>/dev/null)"
        assert_eq "CN-3c $step: the subagent's answer was adopted and the stage settled" \
            "llm|ok" "$(d2099n_kv "$(cat "$D2099N_FIN_OUT")" ADOPTED)|$(d2099n_kv "$(cat "$D2099N_FIN_OUT")" SETTLE)"
    done <<EOF
$D2099N_ROWS
EOF
}

case_begin "normalize-chain-is-real" "bin/workflow/derive-complexity-level"
d2099n_procedure_is_extractable
d2099n_chain_is_real
case_end

# CN-4/CN-5: edge-case inputs to the chain must not crash and must return predictable tokens.
d2099n_run_chain_edge_cases() {
    local name nstage dstage step explevel f sid out cn5_done=0
    while IFS='|' read -r name nstage dstage step explevel; do
        [ -n "$name" ] || continue
        f=$(d2099_skill_file "$name")
        # CN-4: no subagent answer (JJ-2 writes NO_ANSWER) reduces to S0-undecidable, which fails high at every stage
        sid=$(new_session "cn-edge-empty-$step")
        out=$(d2099n_run_chain "$f" "$sid" "" 2>/dev/null | sed -n 1p)
        assert_eq "CN-4 $step empty answer: derive answers level=high (undecidable fails high)" \
            "level=high" "$out"
        assert_eq "CN-4a $step empty answer: finalize fixed S0-undecidable in the control file" \
            "S0-undecidable" "$(tr -d '[:space:]' < "$(d2099n_control_path "$sid" "$nstage")" 2>/dev/null)"
        # CN-5: nonexistent skill file — chain must return the sentinel, not crash (once; row-independent)
        [ "$cn5_done" -eq 0 ] || continue
        cn5_done=1
        sid=$(new_session "cn-edge-nofile-$step")
        out=$(d2099n_run_chain "/nonexistent/skill.md" "$sid" "SIGNALS: S3-security" 2>/dev/null)
        if [ "$out" = "$D2099N_NONE" ]; then
            pass "CN-5 $step nonexistent skill file: chain returns sentinel safely"
        else
            fail "CN-5 $step nonexistent skill file: expected sentinel, got [$out]"
        fi
    done <<EOF
$D2099N_ROWS
EOF
}

case_begin "normalize-chain-edge-cases" "bin/workflow/derive-complexity-level"
d2099n_run_chain_edge_cases
case_end
