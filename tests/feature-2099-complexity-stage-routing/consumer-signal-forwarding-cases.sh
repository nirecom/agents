#!/bin/bash
# tests/feature-2099-complexity-stage-routing/consumer-signal-forwarding-cases.sh
# Tests: skills/make-detail-plan/SKILL.md, skills/write-tests/SKILL.md, skills/write-code/SKILL.md, bin/workflow/read-complexity-evaluation
# Tags: complexity, routing, consumers, signals, integration, scope:issue-specific
# Sourced by ../feature-2099-complexity-stage-routing.sh after the consumer
# orchestration suite — d2099_extract_cmd / d2099_run_skill_cmd come from there.
# Why: that suite drives model selection off the reader's `level=` line only.
# The second line, `signals=`, is asserted nowhere behaviorally — consumers-static
# greps prose, which passes just as well when the step discards the list.

D2099SF_CSV="S1-multi-file,S3-security,S6-long-plan"
# Chosen so the three stages DISAGREE on level while sharing ONE signal list:
# S3-security escalates write_tests and write_code but not detail (detail.md D2).
# A consumer that reconstructed `signals` from its own level cannot produce this.

# consumer | expected `level=` for D2099SF_CSV
D2099SF_ROWS="make-detail-plan|low
write-tests|high
write-code|high"

d2099sf_read() {
    # What the skill's OWN read command answers, first two lines, exactly as the
    # skill tells the orchestrator to parse them: `level=<v>` then `signals=<csv>`.
    local f="$1" sid="$2" out first second
    out=$(d2099_run_skill_cmd "$(d2099_extract_cmd "$f" "read-complexity-evaluation")" "$sid")
    first=$(printf '%s\n' "$out" | sed -n 1p)
    [ "$first" = "__NO_COMMAND__" ] && { echo "NO_READ_COMMAND_IN_SKILL"; return; }
    [ "$first" = "NONE" ] && { echo "NONE"; return; }
    second=$(printf '%s\n' "$out" | sed -n 2p)
    case "$first" in level=*) ;; *) echo "UNPARSEABLE_LEVEL:$first"; return ;; esac
    case "$second" in
        signals=*) printf '%s %s' "$first" "$second" ;;
        '') echo "$first NO_SIGNALS_LINE" ;;
        *) printf '%s UNPARSEABLE_SIGNALS:%s' "$first" "$second" ;;
    esac
}

d2099sf_multi_signal_reaches_each_consumer() {
    # CSF-1..CSF-3: one stored record, read back through each consumer's own
    # command. The list must arrive verbatim at all three even though the level
    # differs — which rules out "the signals were derived from the level".
    local sid sid_zero sid_one name want
    sid=$(new_session sfmulti)
    run_with_timeout node "$BIN_RECORD" --session "$sid" --signals "$D2099SF_CSV" >/dev/null 2>&1
    sid_zero=$(new_session sfzero)
    run_with_timeout node "$BIN_RECORD" --session "$sid_zero" --signals "" >/dev/null 2>&1
    sid_one=$(new_session sfone)
    run_with_timeout node "$BIN_RECORD" --session "$sid_one" --signals "S3-security" >/dev/null 2>&1

    while IFS='|' read -r name want; do
        [ -n "$name" ] || continue
        assert_eq "CSF-1 $name reads back level=$want AND the full stored signal list, verbatim and in order" \
            "level=$want signals=$D2099SF_CSV" \
            "$(d2099sf_read "$(d2099_skill_file "$name")" "$sid")"
        # `none` is the documented zero-signal value (detail.md D4) — not an
        # empty value, and not the multi-signal list from the row above.
        assert_eq "CSF-2 $name reads back the zero-signal marker rather than an empty or stale list" \
            "level=low signals=none" \
            "$(d2099sf_read "$(d2099_skill_file "$name")" "$sid_zero")"
        # Without this row a reader echoing one constant list would satisfy CSF-1.
        # S3-security alone routes low/high/high (detail.md D2) — the same triple
        # D2099SF_ROWS carries, because S3 is the only escalating signal in
        # D2099SF_CSV. So `$want` is the per-stage level here too, and asserting a
        # flat `high` would contradict the detail row.
        assert_eq "CSF-3 $name reads back level=$want and the one-signal list for a one-signal record" \
            "level=$want signals=S3-security" \
            "$(d2099sf_read "$(d2099_skill_file "$name")" "$sid_one")"
    done <<EOF
$D2099SF_ROWS
EOF
}

d2099sf_order_is_preserved() {
    # CSF-4: detail.md D3 stores the judge's list as given and D4 returns it as a
    # csv; nothing sorts it (PO-4 pins the same order in the raw event). A reader
    # that sorted would silently rewrite the reason shown to the user.
    local sid name want reordered="S6-long-plan,S1-multi-file,S3-security"
    sid=$(new_session sforder)
    run_with_timeout node "$BIN_RECORD" --session "$sid" --signals "$reordered" >/dev/null 2>&1
    while IFS='|' read -r name want; do
        [ -n "$name" ] || continue
        assert_eq "CSF-4 $name returns the same signals in the order they were recorded, not a sorted rewrite" \
            "level=$want signals=$reordered" \
            "$(d2099sf_read "$(d2099_skill_file "$name")" "$sid")"
    done <<EOF
$D2099SF_ROWS
EOF
}

D2099SF_SINKS='make-detail-plan|MDP-3|signals: *\[|signals|
write-tests|WT-6|task_complexity_signals|task_complexity_signals|WT-5
write-code|WCD-3|signals: *\[|signals|'
# skill | section holding the sink | sink line regex | field label | step the sink
# must name (empty when the sink sits in the read step itself). write-tests hands
# the list to its subagent as a structured field (WT-6); the other two emit it as
# the selection reason inside the read step itself.

d2099sf_sink_lines() {
    d2099_skill_section "$1" "$2" | grep -E -- "$3"
}

d2099sf_dispatched_signals() {
    # The literal the sink would carry, resolved from the read step's OWN command
    # — the same substitution CO-11..CO-14 perform for the `model:` slot.
    local f="$1" sid="$2" label="$3" read
    read=$(d2099sf_read "$f" "$sid")
    case "$read" in
        *" signals="*) printf '%s: %s' "$label" "${read##* signals=}" ;;
        *) printf 'UNRESOLVED:%s' "$read" ;;
    esac
}

d2099sf_sink_cases() {
    local sid name step re label bind f lines n
    sid=$(new_session sfsink)
    run_with_timeout node "$BIN_RECORD" --session "$sid" --signals "$D2099SF_CSV" >/dev/null 2>&1

    while IFS='|' read -r name step re label bind; do
        [ -n "$name" ] || continue
        f=$(d2099_skill_file "$name")
        lines=$(d2099sf_sink_lines "$f" "$step" "$re")
        if [ -z "$lines" ]; then
            fail "CSF-5 $name: the $step section forwards no signal list at all — nothing consumes the reader's signals= line, so it can be dropped unnoticed"
            continue
        fi
        pass "CSF-5 $name: the $step section carries a [$label] sink for the reader's signal list"
        # Every sink must be a SLOT: a literal signal id there is a hardcoded
        # list that would survive any change to what the reader returns.
        n=$(printf '%s\n' "$lines" | grep -cE 'S[0-9][a-z]?-[a-z]')
        assert_eq "CSF-6 $name: no [$label] sink hardcodes a signal id instead of taking the reader's list" "0" "$n"
        if [ -n "$bind" ]; then
            n=$(printf '%s\n' "$lines" | grep -cF -- "$bind")
            assert_eq "CSF-7 $name: the [$label] handoff names $bind as the step its value comes from" "1" "$n"
        fi
        assert_eq "CSF-8 $name: the [$label] handoff resolves to the exact recorded list for a 3-signal record" \
            "$label: $D2099SF_CSV" "$(d2099sf_dispatched_signals "$f" "$sid" "$label")"
    done <<EOF
$D2099SF_SINKS
EOF
}

# SKIPPED: reading `task_complexity_signals` out of the REAL subagent prompt at WT-6.
# Because: the Agent tool's prompt exists only inside a live Claude Code session and
#   reaches no argv, env, file or stdout a bash harness can observe — the same wall
#   CO-11..CO-14 hit for `model:`.
# Closest substitute: CSF-8, which resolves the documented sink from the read step's
#   own command output. L3 gap: a skill that resolves the slot and then hands the
#   subagent a different list. Only a TL3 transcript review closes it.

d2099sf_multi_signal_reaches_each_consumer
d2099sf_order_is_preserved
d2099sf_sink_cases
