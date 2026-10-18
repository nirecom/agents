#!/bin/bash
# tests/hooks/feature-2460-jev-call-sites-static/shared-procedure-static.sh
# Tests: skills/_shared/jev-two-stage-judge.md, skills/write-code/SKILL.md, agents/complexity-judge.md, agents/plan-skip-judge.md
# Tags: complexity, prompt-static, jev, shared-procedure, stage-5, scope:issue-specific
# Sourced by ../feature-2460-jev-call-sites-static.sh — helpers come from there.
# Moved with their CS ids kept from feature-2099-complexity-stage-routing/
# consumers-static.sh: the shared procedure's own steps (detail plan L858-870,
# L876) and the WCD-2 edit list (L886).

# CS-40..53: JJ-2..JJ-5 of the shared procedure.
d2460jj_static() {
    local f="$D2099_JJ_FILE" s2 s3 s4 s5 items sup bad
    assert_eq "CS-40 skills/_shared/jev-two-stage-judge.md exists" "present" "$([ -f "$f" ] && echo present || echo absent)"
    s2=$(d2099_raw_section "$f" JJ-2)
    assert_contains "CS-41 JJ-2 hands the subagent the JEV_INPUT_FILE path" "JEV_INPUT_FILE" "$s2"
    assert_eq "CS-42 JJ-2 says when to read the full sources (Jev input truncated / absent)" "yes yes" \
        "$(printf '%s\n' "$s2" | grep -qE '(^|[^_a-z])sources([^_a-z]|$)' && echo yes || echo no) $(printf '%s\n' "$s2" | grep -qiE 'truncated|absent' && echo yes || echo no)"
    assert_contains "CS-43 JJ-2 states how to treat sources_unavailable" "sources_unavailable" "$s2"
    assert_contains "CS-44 JJ-2 has the orchestrator write the answer to ANSWER_FILE" "ANSWER_FILE" "$s2"

    s3=$(d2099_raw_section "$f" JJ-3)
    assert_contains "CS-45 JJ-3 runs jev-judge finalize" "finalize" "$s3"
    assert_eq "CS-46 JJ-3 re-runs the same finalize exactly once on an abnormal exit" "yes yes" \
        "$(printf '%s\n' "$s3" | grep -qiE 're-?run|retry|again' && echo yes || echo no) $(printf '%s\n' "$s3" | grep -qiE 'once|one time|1 time' && echo yes || echo no)"

    s4=$(d2099_raw_section "$f" JJ-4)
    assert_eq "CS-47 JJ-4's SETTLE=ok rows pass --signals \"<SIGNALS_CSV>\" to record and derive" "record=yes derive=yes" \
        "record=$(printf '%s\n' "$s4" | grep -F 'record-complexity-evaluation' | grep -qF -- '--signals "<SIGNALS_CSV>"' && echo yes || echo no) derive=$(printf '%s\n' "$s4" | grep -F 'derive-complexity-level' | grep -qF -- '--signals "<SIGNALS_CSV>"' && echo yes || echo no)"
    # CS-48 and CS-50 are absence checks; CS-47 / CS-49 above prove JJ-4 was found.
    assert_eq "CS-48 JJ-4 carries no derive --session form, no --signals-file, no SIGNALS_FILE" "no no no" \
        "$(printf '%s\n' "$s4" | grep -F 'derive-complexity-level' | grep -qF -- '--session' && echo yes || echo no) $(printf '%s\n' "$s4" | grep -qF -- '--signals-file' && echo yes || echo no) $(printf '%s\n' "$s4" | grep -qF 'SIGNALS_FILE' && echo yes || echo no)"
    items=$(d2099_md_items "$s4")
    sup=$(printf '%s\n' "$items" | grep -F 'superseded' | grep -vF 'SKIP=')
    assert_eq "CS-49 JJ-4's complexity superseded row: no write, no record/derive, stop, follow next-step" \
        "nowrite=yes stop=yes nextstep=yes" \
        "nowrite=$(printf '%s\n' "$sup" | grep -qiE "(do not|don't|never|without) (write|writing|record|recording|deriv)" && echo yes || echo no) stop=$(printf '%s\n' "$sup" | grep -qiE '\bstop' && echo yes || echo no) nextstep=$(printf '%s\n' "$sup" | grep -qF 'next-step' && echo yes || echo no)"
    # Mentions of JJ-5 / the fail-safe are allowed only as prohibitions.
    bad=$(printf '%s\n' "$sup" | sed 's/\. /.\n/g; s/; /;\n/g' | grep -iE 'JJ-5|fail-?safe' \
        | grep -viE "(do not|don't|never|not|no) " | head -1)
    assert_eq "CS-50 JJ-4's superseded row hands nothing to JJ-5 and applies no fail-safe" "none" "${bad:-none}"

    s5=$(d2099_raw_section "$f" JJ-5)
    items=$(d2099_md_items "$s5")
    assert_contains "CS-51 JJ-5 handles finalize RESULT=error" "RESULT=error" "$s5"
    assert_eq "CS-52 JJ-5 complexity fail-safe runs jev-judge failsafe and hands SIGNALS_CSV on" "yes" \
        "$(printf '%s\n' "$items" | grep -F 'complexity-judge' | grep -F 'failsafe' | grep -qF 'SIGNALS_CSV' && echo yes || echo no)"
    assert_eq "CS-53 JJ-5 skip fail-safe treats the result as SKIP=false and runs the step" "yes" \
        "$(printf '%s\n' "$items" | grep -E 'outline-skip|detail-skip|skip' | grep -F 'SKIP=false' | grep -qiE '\b(run|runs|execute|executes)\b' && echo yes || echo no)"
}

# CS-60: WCD-2 writes the complete edit list S1b/S4 are computed from.
d2460jj_wcd2_file_list() {
    local s
    s=$(d2099_raw_section "$SCRIPT_CHECKOUT_ROOT/skills/write-code/SKILL.md" WCD-2)
    assert_eq "CS-60 WCD-2 writes every edited file, one path per line, to write-code-files.txt with the Write tool" \
        "file=yes every=yes perline=yes write=yes" \
        "file=$(printf '%s\n' "$s" | grep -qF 'write-code-files.txt' && echo yes || echo no) every=$(printf '%s\n' "$s" | grep -qiE '(every|all) (file|files|edited|planned)' && echo yes || echo no) perline=$(printf '%s\n' "$s" | grep -qiE '(one|1) path per line' && echo yes || echo no) write=$(printf '%s\n' "$s" | grep -qF 'Write tool' && echo yes || echo no)"
}

# CS-61..62 (#2701): the snapshot -> Jev input rename leaves no old name behind. Every token is
# Jev-specific: the SNAPSHOT_FILE key, buildSnapshot, the snapshot_file / snapshot_sha256 ticket
# fields, the -snapshot.md suffix, the snapshot module, and the Jev-input phrasings the plan
# renames in bin/workflow and jev.md. Unrelated snapshots (shell snapshot, cap-snapshot, the
# reconciled state snapshot, the test-overrides entry snapshot) do not match.
D2460_SNAP_TOKENS='SNAPSHOT_FILE|buildSnapshot|snapshot_file|snapshot_sha256|-snapshot\.md|snapshot\.js|require\("\./snapshot"\)|Jev snapshot|snapshot (may )?carr|Snapshot section order|Snapshots the stage|gate, snapshot,'
d2460jj_jev_input_rename() {
    local r="$SCRIPT_CHECKOUT_ROOT" hits d
    local -a paths=()
    for d in agents skills hooks/lib/jev docs/architecture/jev docs/architecture/jev.md bin/workflow; do paths+=("$r/$d"); done
    hits=$(grep -rnE "$D2460_SNAP_TOKENS" "${paths[@]}" 2>/dev/null | sed "s#^$r/##" | head -5)
    assert_eq "CS-61 no snapshot-era Jev name in agents/ skills/ hooks/lib/jev/ docs/architecture/jev(.md) bin/workflow/" "none" "${hits:-none}"
    assert_eq "CS-62 hooks/lib/jev/two-stage/snapshot.js is gone" "absent" \
        "$([ -e "$r/hooks/lib/jev/two-stage/snapshot.js" ] && echo present || echo absent)"
}

# CS-63: both backup subagents take the Jev input file and say so in their ## Input section.
d2460jj_judge_agents_input() {
    local a f input
    for a in complexity-judge plan-skip-judge; do
        f="$SCRIPT_CHECKOUT_ROOT/agents/$a.md"
        input=$(sed -n '/^## Input[[:space:]]*$/,/^## /p' "$f" 2>/dev/null)
        assert_eq "CS-63 agents/$a.md: JEV_INPUT_FILE named, ## Input says Jev input" "file=yes input=yes" \
            "file=$(grep -qF 'JEV_INPUT_FILE' "$f" && echo yes || echo no) input=$(printf '%s\n' "$input" | grep -qF 'Jev input' && echo yes || echo no)"
    done
}

case_begin "jev-input-rename-sweep" "agents/complexity-judge.md"
d2460jj_jev_input_rename
case_end

case_begin "judge-agents-jev-input" "agents/complexity-judge.md"
d2460jj_judge_agents_input
case_end

case_begin "jev-two-stage-judge-static" "skills/_shared/jev-two-stage-judge.md"
d2460jj_static
case_end

case_begin "write-code-wcd2-file-list" "skills/write-code/SKILL.md"
d2460jj_wcd2_file_list
case_end
