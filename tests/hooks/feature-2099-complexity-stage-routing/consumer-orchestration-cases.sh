#!/bin/bash
# tests/hooks/feature-2099-complexity-stage-routing/consumer-orchestration-cases.sh
# Tests: skills/make-detail-plan/SKILL.md, skills/write-tests/SKILL.md, skills/write-code/SKILL.md, bin/workflow/read-complexity-evaluation, bin/workflow/read-session-facts, bin/workflow/derive-complexity-level
# Tags: complexity, routing, consumers, integration, model-selection, scope:issue-specific
# Sourced by ../feature-2099-complexity-stage-routing.sh — helpers come from there.
# Runs each consumer's OWN extracted stored-evaluation read command and maps it to
# a model; the NONE branch (skills/_shared/jev-two-stage-judge.md, #2460) is pinned
# statically in consumers-static.sh, not executed here.

# Every consumer row: skill dir | stage key | level step | Agent-launch step.
# live-e2e-cases.sh walks this table too.
D2099_CONSUMERS="make-detail-plan|detail|MDP-3|MDP-4
write-tests|write_tests|WT-6|WT-7
write-code|write_code|WCD-3|WCD-4"

# The consumers that still READ a stored evaluation (#2460: WCD-3 judges every
# time, so write-code has no stored-read path left to execute).
D2099_STORED_CONSUMERS="make-detail-plan|detail|MDP-3|MDP-4
write-tests|write_tests|WT-6|WT-7"

# d2099_skill_file, the read-CLI choice, extraction and answer normalization:
# consumer-read-cli.sh (sourced first).

# The launch step each level step feeds (detail.md D4 consumer rows).
d2099_launch_step() {
    case "$1" in
        MDP-3) echo "MDP-4" ;;
        WT-6)  echo "WT-7" ;;
        WCD-3) echo "WCD-4" ;;
        *) echo "" ;;
    esac
}

# d2099_orch_model_for — reads model= from BIN_DERIVE for the given level.
# After #2100 skills carry no hardcoded model table (CPR-ORTH with d2099_doc_model_for).
d2099_orch_model_for() {
    case "$2" in high|low) ;; *) echo "NO_LEVEL"; return ;; esac
    local sigs; [ "$2" = "high" ] && sigs="S2-architecture" || sigs=""
    run_with_timeout node "$BIN_DERIVE" --stage detail --signals "$sigs" 2>/dev/null \
        | grep '^model=' | head -1 | sed 's/^model=//'
}

# d2099_orch_model — drives the skill's read command, parses the model= line.
# FALLBACK when the reader answered NONE (the shared-procedure branch).
d2099_orch_model() {
    local f="$1" sid="$2" out first model
    out=$(d2099_consumer_read "$f" "$sid")
    first=$(printf '%s\n' "$out" | head -1)
    [ "$first" = "__NO_COMMAND__" ] && { echo "NO_COMMAND_IN_SKILL"; return; }
    [ "$first" = "NONE" ] && { echo "FALLBACK"; return; }
    model=$(printf '%s\n' "$out" | grep '^model=' | head -1 | sed 's/^model=//')
    [ -n "$model" ] && { echo "$model"; return; }
    case "$first" in
        level=*) echo "NO_MODEL_LINE_FOR:${first#level=}" ;;
        *) echo "UNPARSEABLE:$first" ;;
    esac
}

# CO-0/CO-1: the extraction must have teeth. If a skill carried no runnable read
# command every assertion below would measure an empty string instead of the
# consumer, so the command line is pinned first.
d2099_orch_commands_are_real() {
    local name stage cmd f rcli rstep
    while IFS='|' read -r name stage _; do
        [ -n "$name" ] || continue
        f=$(d2099_skill_file "$name")
        rcli=$(d2099_read_cli "$name")
        rstep=$(d2099_read_step "$name")
        d2099_assert_section_cli_unique "CO-0" "$rstep" "$f" "$rcli"
        cmd=$(d2099_extract_read_cmd "$f")
        if [ "$rcli" = "read-session-facts" ]; then
            # The bundled record carries no --stage flag: the stage is spelled in
            # the KEY the step is told to read, so THAT is what must name it.
            assert_contains "CO-1 $rstep carries a runnable read command naming its own stage" \
                "COMPLEXITY_LEVEL_$stage" "$(d2099_section_for_cli "$f" "$rcli")"
        else
            assert_contains "CO-1 $rstep carries a runnable read command naming its own stage" \
                "--stage $stage" "$cmd"
        fi
        assert_contains "CO-1b $rstep's command passes the session through" \
            '--session "$SESSION_ID"' "$cmd"
    done <<EOF
$D2099_STORED_CONSUMERS
EOF
}

# CO-3..CO-5b: a recorded evaluation must reach the Agent tool as the model that
# stage's routing row implies. Per-stage levels come from the end-state table:
# S1b low/low (detail/write_tests), S2 high/high, S3 low/high, none low/low.
d2099_orch_recorded_selects_model() {
    local sid sid_zero sid_arch sid_sec name stage step want
    sid=$(new_session orchwide)
    run_with_timeout node "$BIN_RECORD" --session "$sid" --signals "S1b-wide-change" >/dev/null 2>&1
    while IFS='|' read -r name stage step _; do
        [ -n "$name" ] || continue
        # S1b left write_tests' solo set in #2460, so it is low on both readers.
        assert_eq "CO-3 $step hands the Agent tool 'sonnet' for a recorded S1b-wide-change evaluation" \
            "sonnet" "$(d2099_orch_model "$(d2099_skill_file "$name")" "$sid")"
    done <<EOF
$D2099_STORED_CONSUMERS
EOF

    sid_zero=$(new_session orchzero)
    run_with_timeout node "$BIN_RECORD" --session "$sid_zero" --signals "" >/dev/null 2>&1
    while IFS='|' read -r name stage step _; do
        [ -n "$name" ] || continue
        assert_eq "CO-4 $step hands the Agent tool 'sonnet' for a recorded zero-signal evaluation" \
            "sonnet" "$(d2099_orch_model "$(d2099_skill_file "$name")" "$sid_zero")"
    done <<EOF
$D2099_STORED_CONSUMERS
EOF

    # S2-architecture is high on every stage: the uniform-high control.
    sid_arch=$(new_session orcharch)
    run_with_timeout node "$BIN_RECORD" --session "$sid_arch" --signals "S2-architecture" >/dev/null 2>&1
    while IFS='|' read -r name stage step _; do
        [ -n "$name" ] || continue
        assert_eq "CO-5 $step hands the Agent tool 'opus' for a recorded S2-architecture evaluation (high on every stage)" \
            "opus" "$(d2099_orch_model "$(d2099_skill_file "$name")" "$sid_arch")"
    done <<EOF
$D2099_STORED_CONSUMERS
EOF

    # S3-security splits the two readers: detail low, write_tests high — so a
    # reader keyed to the wrong stage column is caught.
    sid_sec=$(new_session orchsec)
    run_with_timeout node "$BIN_RECORD" --session "$sid_sec" --signals "S3-security" >/dev/null 2>&1
    while IFS='|' read -r name stage step _; do
        [ -n "$name" ] || continue
        case "$stage" in detail) want="sonnet" ;; *) want="opus" ;; esac
        assert_eq "CO-5b $step hands the Agent tool '$want' for a recorded S3-security evaluation" \
            "$want" "$(d2099_orch_model "$(d2099_skill_file "$name")" "$sid_sec")"
    done <<EOF
$D2099_STORED_CONSUMERS
EOF
}

# CO-6: an unrecorded session must land in the NONE branch (the shared judge
# procedure), never on a model.
d2099_orch_none_fallback() {
    local sid name step
    sid=$(new_session orchnone)   # created, never recorded into
    while IFS='|' read -r name _ step _; do
        [ -n "$name" ] || continue
        assert_eq "CO-6 $step: an unrecorded session lands in the fallback, not on a model" \
            "FALLBACK" "$(d2099_orch_model "$(d2099_skill_file "$name")" "$sid")"
    done <<EOF
$D2099_STORED_CONSUMERS
EOF
}

# CO-9/CO-10: the last link. Without this a skill could compute the right model
# and then dispatch a hardcoded one. All three consumers, write-code included:
# WCD-4 still takes its model from WCD-3.
d2099_orch_agent_handoff() {
    local name step launch f
    while IFS='|' read -r name _ step launch; do
        [ -n "$name" ] || continue
        f=$(d2099_skill_file "$name")
        assert_eq "CO-9 $launch passes the model computed in $step to the Agent tool" "yes" \
            "$(d2099_section_has_re "$f" "$launch" "model: <[^>]*$step[^>]*>")"
        assert_eq "CO-10 $launch never hardcodes a model instead" "no" \
            "$(d2099_has_re "$f" 'model: *"?(opus|sonnet)"?[ ,)]')"
    done <<EOF
$D2099_CONSUMERS
EOF
}

# --- CO-11..CO-15: the `model:` value the launch step actually dispatches -----
# CO-9/CO-10 read the launch step's PROSE. These fill the launch line's own
# `model:` slot from the read step's own command plus the model mapping, and
# assert the literal argument that leaves — stored HIGH, stored LOW, NONE.

# The launch step's `model:` slot, e.g. `<from MDP-3>`, read only inside the
# LAUNCH step's own section (round-10 C1).
d2099_orch_model_slot() {
    local f="$1" read_step="$2" launch
    launch=$(d2099_launch_step "$read_step")
    [ -n "$launch" ] || return 0
    d2099_skill_section "$f" "$launch" \
        | grep -m1 -oE "model: *<[^>]*$read_step[^>]*>" | sed -E 's/^model: *//'
}

# Resolve one consumer's launch-step slot into the literal argument the Agent
# tool would receive. When the read answers NONE the skill runs the shared judge
# procedure, which no bash harness can drive (it dispatches a subagent), so the
# answer is the named token FALLBACK_SHARED_PROCEDURE. `$3` (the judged csv) is
# kept for callers' arity and is no longer consulted.
d2099_orch_dispatched_model() {
    local f="$1" sid="$2" read_step="$4" slot out first lvl model
    slot=$(d2099_orch_model_slot "$f" "$read_step")
    if [ -z "$slot" ]; then
        if [ "$(d2099_has_re "$f" 'model: *"?(opus|sonnet)"?[ ,)]')" = "yes" ]; then
            echo "HARDCODED_MODEL_IN_LAUNCH"
        else
            echo "NO_MODEL_SLOT_BOUND_TO:$read_step"
        fi
        return
    fi
    out=$(d2099_consumer_read "$f" "$sid")
    first=$(printf '%s\n' "$out" | head -1)
    [ "$first" = "__NO_COMMAND__" ] && { echo "NO_READ_COMMAND_IN_SKILL"; return; }
    [ "$first" = "NONE" ] && { echo "FALLBACK_SHARED_PROCEDURE"; return; }
    case "$first" in
        level=*) lvl="${first#level=}" ;;
        *) echo "UNPARSEABLE:$first"; return ;;
    esac
    model=$(d2099_orch_model_for "$f" "$lvl")
    [ -n "$model" ] || { echo "NO_DOCUMENTED_MAPPING_FOR:$lvl"; return; }
    printf 'model: "%s"' "$model"
}

d2099_orch_dispatched_model_cases() {
    local name stage step f sid_hi sid_lo sid_none sid_wide sid_sec want
    sid_hi=$(new_session dispatchhigh)
    run_with_timeout node "$BIN_RECORD" --session "$sid_hi" --signals "S2-architecture" >/dev/null 2>&1
    sid_lo=$(new_session dispatchlow)
    run_with_timeout node "$BIN_RECORD" --session "$sid_lo" --signals "" >/dev/null 2>&1
    sid_none=$(new_session dispatchnone)
    sid_wide=$(new_session dispatchwide)
    run_with_timeout node "$BIN_RECORD" --session "$sid_wide" --signals "S1b-wide-change" >/dev/null 2>&1
    sid_sec=$(new_session dispatchsec)
    run_with_timeout node "$BIN_RECORD" --session "$sid_sec" --signals "S3-security" >/dev/null 2>&1

    while IFS='|' read -r name stage step _; do
        [ -n "$name" ] || continue
        f=$(d2099_skill_file "$name")
        assert_eq "CO-11 $step's launch slot resolves to model: \"opus\" for a STORED high evaluation" \
            'model: "opus"' "$(d2099_orch_dispatched_model "$f" "$sid_hi" "" "$step")"
        assert_eq "CO-12 $step's launch slot resolves to model: \"sonnet\" for a STORED low evaluation" \
            'model: "sonnet"' "$(d2099_orch_dispatched_model "$f" "$sid_lo" "" "$step")"
        assert_eq "CO-13 $step: nothing persisted, so the slot is filled by the shared judge procedure, not a stored model" \
            "FALLBACK_SHARED_PROCEDURE" "$(d2099_orch_dispatched_model "$f" "$sid_none" "" "$step")"
        # S1b-wide-change was escalating at write_tests before #2460; a reader
        # still carrying the old solo row answers opus here.
        assert_eq "CO-14 $step's launch slot resolves to model: \"sonnet\" for the STORED S1b-wide-change record" \
            'model: "sonnet"' "$(d2099_orch_dispatched_model "$f" "$sid_wide" "" "$step")"
        case "$stage" in detail) want='model: "sonnet"' ;; *) want='model: "opus"' ;; esac
        assert_eq "CO-15 $step's launch slot resolves to $want for the STORED S3-security record" \
            "$want" "$(d2099_orch_dispatched_model "$f" "$sid_sec" "" "$step")"
    done <<EOF
$D2099_STORED_CONSUMERS
EOF
}

# SKIPPED: the REAL Agent tool call at MDP-4 / WT-7 / WCD-4 and its `model:`.
# Because: `Agent(...)` exists only inside a live Claude Code session and the
#   launch is PROSE; no process, argv, env or file carries that value for bash.
# L3 gap: an orchestrator that resolves the slot right and hands Agent something
#   else, and the shared-procedure branch end to end. Closest substitute:
#   CO-9..CO-15 plus live-e2e-cases.sh (RUN_TL3).

case_begin "orchestration-commands-are-real" "skills/make-detail-plan/SKILL.md"
d2099_orch_commands_are_real
case_end

case_begin "orchestration-recorded-selects-model" "bin/workflow/read-complexity-evaluation"
d2099_orch_recorded_selects_model
case_end

case_begin "orchestration-none-fallback" "bin/workflow/read-complexity-evaluation"
d2099_orch_none_fallback
case_end

case_begin "orchestration-agent-handoff" "skills/make-detail-plan/SKILL.md"
d2099_orch_agent_handoff
case_end

case_begin "orchestration-dispatched-model-cases" "bin/workflow/read-complexity-evaluation"
d2099_orch_dispatched_model_cases
case_end
