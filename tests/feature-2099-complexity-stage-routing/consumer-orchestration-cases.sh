#!/bin/bash
# tests/feature-2099-complexity-stage-routing/consumer-orchestration-cases.sh
# Tests: skills/make-detail-plan/SKILL.md, skills/write-tests/SKILL.md, skills/write-code/SKILL.md, bin/workflow/read-complexity-evaluation, bin/workflow/derive-complexity-level
# Tags: complexity, routing, consumers, integration, model-selection, scope:issue-specific
# Sourced by ../feature-2099-complexity-stage-routing.sh — helpers come from there.
# MDP-3 / WT-5 / WCD-3 are the three mandatory consumer points (detail.md). The
# sibling static and dispatch suites grep them or replay a hand-written command;
# neither runs what the skill itself specifies. Here the command is EXTRACTED
# FROM THE SKILL FILE, run verbatim, and mapped to a model by the mapping that
# same file states — the decision procedure is never re-encoded test-side.

# The three consumer rows: skill dir | stage key | read step | Agent-launch step.
D2099_CONSUMERS="make-detail-plan|detail|MDP-3|MDP-4
write-tests|write_tests|WT-5|WT-6
write-code|write_code|WCD-3|WCD-4"

d2099_skill_file() { echo "$AGENTS_DIR/skills/$1/SKILL.md"; }

# Pull the shell command the skill tells the orchestrator to run. The skills wrap
# it as `bash -c '<cmd>'`; the inner command uses double quotes only, so the
# single quotes delimit it unambiguously.
#
# Bounded to the REQUIRED step's own section (d2099_section_cli_line): a whole-file
# grep would take the first mention anywhere — an example, a stale duplicate, or
# prose — and validate that instead of MDP-3/WT-5/WCD-3 (round-10 C1). A section
# holding zero or several such lines yields "" here and is reported by name in
# CO-0 below, never resolved to an arbitrary pick.
d2099_extract_cmd() {
    local f="$1" cli="$2" line
    line=$(d2099_section_cli_line "$f" "$cli" | grep -oE "bash -c '[^']*'" | head -1)
    [ -n "$line" ] || { echo ""; return; }
    printf '%s' "$line" | sed -E "s/^bash -c '//; s/'$//"
}

# The launch step each read step feeds (detail.md D4 consumer rows).
d2099_launch_step() {
    case "$1" in
        MDP-3) echo "MDP-4" ;;
        WT-5)  echo "WT-6" ;;
        WCD-3) echo "WCD-4" ;;
        *) echo "" ;;
    esac
}

# --- the signals FILE, the only channel the judged csv now travels on ----------
# MDP-3 / WT-5 / WCD-3 no longer carry a `--signals <csv-or-empty>` splice slot.
# The orchestrator Writes the judged csv (Write tool, never Bash) to
# `<PLANS_DIR>/<session-id>-<stage>-signals.txt` and the documented line carries
# only `--signals-file "<that path>"` — a constant shape no judge text reaches.
# These helpers simulate exactly that Write step, mirroring the producer side's
# d2099p_plans_dir / d2099p_write_signals_file (CPR-ORTH: one mechanism, two
# boundaries), so every case below runs the skill's line VERBATIM apart from the
# `<PLANS_DIR>` / `<session-id>` slots the skill itself marks as fill-in.
D2099_CONSUMER_PLANS=""
d2099_plans_dir() {
    if [ -z "$D2099_CONSUMER_PLANS" ]; then
        D2099_CONSUMER_PLANS="$TMPDIR_BASE/consumer-plans"
        mkdir -p "$D2099_CONSUMER_PLANS"
    fi
    printf '%s' "$D2099_CONSUMER_PLANS"
}

# Fill ONLY the two slots the skill marks as fill-in. The csv is never
# substituted into the command, so no payload can be re-quoted into something
# the skill never wrote — which is what makes CF-8 a test of the DESIGN rather
# than of this harness's quoting.
d2099_fill_signals_file_cmd() {
    local cmd="$1" sid="$2" dir
    dir=$(d2099_plans_dir)
    printf '%s' "$cmd" | sed -E -e "s#<PLANS_DIR>#$dir#g" -e "s#<session-id>#$sid#g"
}

# The path the FILLED command will read, taken out of that command instead of
# rebuilt here (CPR-SSOT): the file this fixture writes and the file the CLI
# opens cannot drift apart, and a renamed path in a SKILL.md moves both at once.
d2099_signals_file_path() {
    printf '%s' "$1" | grep -oE -- '--signals-file "[^"]*"' | head -1 \
        | sed -E 's/^--signals-file "//; s/"$//'
}

# Run an extracted command exactly as written, with only the environment the
# skill assumes. Two documented line shapes, DETECTED rather than assumed (a
# sibling fixture or a future skill may still document the older one):
#   `--signals-file "<PLANS_DIR>/<session-id>-...">` — the csv goes into the FILE
#     at the resolved path, by a plain write, never into the command text the
#     shell parses. That is the whole point of the redesign.
#   `<placeholder>` — the pre-#2099 splice slot: the csv is substituted into the
#     command line, escaped for sed.
# Anything else (the read command) runs untouched.
d2099_run_skill_cmd() {
    local cmd="$1" sid="$2" signals="${3:-}" escaped_signals path
    [ -n "$cmd" ] || { echo "__NO_COMMAND__"; return; }
    case "$cmd" in
        *--signals-file*)
            cmd=$(d2099_fill_signals_file_cmd "$cmd" "$sid")
            path=$(d2099_signals_file_path "$cmd")
            # A slot this fixture cannot resolve must be a NAMED token, never a
            # corrupted path that measures the CLI's ENOENT instead of routing.
            [ -n "$path" ] || { echo "__NO_SIGNALS_FILE_PATH__"; return; }
            case "$path" in
                *'<'*|*'>'*) echo "__UNFILLED_SLOT_IN_SIGNALS_FILE_PATH__"; return ;;
            esac
            mkdir -p "$(dirname "$path")"
            printf '%s' "$signals" > "$path"
            ;;
        *'<'*)
            # `signals` is untrusted (CF-8 feeds it hostile payloads containing
            # `/` and `&`), and both are special inside a sed replacement: `/`
            # closes the s/// expression early (the char-N "unknown option to
            # `s'" failure) and `&` expands to the whole match. Escape both
            # before splicing into the s///.
            escaped_signals=$(printf '%s' "$signals" | sed -e 's/[\/&]/\\&/g')
            cmd=$(printf '%s' "$cmd" | sed -E "s/<[^>]*>/$escaped_signals/g")
            ;;
    esac
    AGENTS_CONFIG_DIR="$AGENTS_DIR" SESSION_ID="$sid" \
        run_with_timeout bash -c "$cmd" 2>/dev/null
}

# The model that FILE says a level maps to — read out of the document under
# test, so a skill that changed its own mapping cannot silently pass. Bounded to
# the read step's own section: a mapping stated somewhere else in the file is not
# the mapping this step applies (round-10 C1).
d2099_orch_model_for() {
    case "$2" in high|low) ;; *) echo "NO_LEVEL"; return ;; esac
    d2099_section_for_cli "$1" "read-complexity-evaluation" \
        | grep -oE "$2 *(→|->) *(opus|sonnet)" | head -1 | sed -E 's/.*(→|->) *//'
}

# The whole consumer procedure driven by the skill's own command line: run it,
# parse the level, map to a model. FALLBACK when the CLI answered NONE.
d2099_orch_model() {
    local f="$1" sid="$2" out first lvl model
    out=$(d2099_run_skill_cmd "$(d2099_extract_cmd "$f" "read-complexity-evaluation")" "$sid")
    first=$(printf '%s\n' "$out" | head -1)
    [ "$first" = "__NO_COMMAND__" ] && { echo "NO_COMMAND_IN_SKILL"; return; }
    [ "$first" = "NONE" ] && { echo "FALLBACK"; return; }
    case "$first" in
        level=*) lvl="${first#level=}" ;;
        *) echo "UNPARSEABLE:$first"; return ;;
    esac
    model=$(d2099_orch_model_for "$f" "$lvl")
    [ -n "$model" ] || { echo "NO_DOCUMENTED_MAPPING_FOR:$lvl"; return; }
    echo "$model"
}

# CO-1/CO-2: the extraction must have teeth. If a skill carried no runnable
# command every assertion below would measure an empty string instead of the
# consumer, so the command line is pinned first.
d2099_orch_commands_are_real() {
    local name stage step cmd f
    while IFS='|' read -r name stage step _; do
        [ -n "$name" ] || continue
        f=$(d2099_skill_file "$name")
        # CO-0: the bound itself. Every assertion below extracts from INSIDE the
        # $step section; if that section is missing, empty of the CLI, or carries
        # duplicates, say which rather than measuring an arbitrary line.
        d2099_assert_section_cli_unique "CO-0" "$step" "$f" "read-complexity-evaluation"
        d2099_assert_section_cli_unique "CO-0a" "$step" "$f" "derive-complexity-level"
        cmd=$(d2099_extract_cmd "$f" "read-complexity-evaluation")
        assert_contains "CO-1 $step carries a runnable read command naming its own stage" \
            "--stage $stage" "$cmd"
        assert_contains "CO-1b $step's command passes the session through" \
            '--session "$SESSION_ID"' "$cmd"
        cmd=$(d2099_extract_cmd "$f" "derive-complexity-level")
        assert_contains "CO-2 $step's NONE fallback carries a runnable derive command for its stage" \
            "--stage $stage" "$cmd"
        # CO-2a/CO-2b are the consumer-side twin of PO-1b/PO-1b1: the judged csv
        # reaches the CLI by FILE at a slot-shaped path, and the splice slot every
        # CF-8 payload used to travel through is gone. Without CO-2b the runner
        # above would silently take its legacy `<placeholder>` branch again.
        assert_contains "CO-2a $step's fallback passes the judged csv by file" \
            "--signals-file" "$cmd"
        assert_not_contains "CO-2b $step's fallback carries no --signals <csv> splice slot" \
            "--signals <" "$cmd"
        assert_contains "CO-2c $step's fallback names the documented per-stage signals-file path" \
            '--signals-file "<PLANS_DIR>/<session-id>-' "$cmd"
    done <<EOF
$D2099_CONSUMERS
EOF
}

# CO-3..CO-5: a recorded evaluation must reach the Agent tool as the model that
# stage's routing row implies. S1-multi-file is the #2099 case itself: one
# record, sonnet for detail and write_tests, opus for write_code.
d2099_orch_recorded_selects_model() {
    local sid sid_zero sid_sec name stage step want
    sid=$(new_session orchlow)
    run_with_timeout node "$BIN_RECORD" --session "$sid" --signals "S1-multi-file" >/dev/null 2>&1
    while IFS='|' read -r name stage step _; do
        [ -n "$name" ] || continue
        case "$stage" in write_code) want="opus" ;; *) want="sonnet" ;; esac
        assert_eq "CO-3 $step hands the Agent tool '$want' for a recorded S1-multi-file evaluation" \
            "$want" "$(d2099_orch_model "$(d2099_skill_file "$name")" "$sid")"
    done <<EOF
$D2099_CONSUMERS
EOF

    # A zero-signal record is the only input that routes low on all three.
    sid_zero=$(new_session orchzero)
    run_with_timeout node "$BIN_RECORD" --session "$sid_zero" --signals "" >/dev/null 2>&1
    while IFS='|' read -r name stage step _; do
        [ -n "$name" ] || continue
        assert_eq "CO-4 $step hands the Agent tool 'sonnet' for a recorded zero-signal evaluation" \
            "sonnet" "$(d2099_orch_model "$(d2099_skill_file "$name")" "$sid_zero")"
    done <<EOF
$D2099_CONSUMERS
EOF

    # ...and S2-architecture is solo_escalation for detail and write_tests and a
    # legacy_equivalent single for write_code (detail.md D2), so it is the
    # genuinely uniform-high control: the same procedure must flip on all three.
    local sid_arch
    sid_arch=$(new_session orcharch)
    run_with_timeout node "$BIN_RECORD" --session "$sid_arch" --signals "S2-architecture" >/dev/null 2>&1
    while IFS='|' read -r name stage step _; do
        [ -n "$name" ] || continue
        assert_eq "CO-5 $step hands the Agent tool 'opus' for a recorded S2-architecture evaluation (high on every stage)" \
            "opus" "$(d2099_orch_model "$(d2099_skill_file "$name")" "$sid_arch")"
    done <<EOF
$D2099_CONSUMERS
EOF

    # S3-security is the OTHER divergent row: detail's escalation sets do not
    # contain it, so detail stays sonnet while write_tests and write_code flip to
    # opus. It splits the three stages the opposite way from CO-3's S1-multi-file
    # (low/low/high vs low/high/high), which no uniform row can distinguish.
    sid_sec=$(new_session orchsec)
    run_with_timeout node "$BIN_RECORD" --session "$sid_sec" --signals "S3-security" >/dev/null 2>&1
    while IFS='|' read -r name stage step _; do
        [ -n "$name" ] || continue
        case "$stage" in detail) want="sonnet" ;; *) want="opus" ;; esac
        assert_eq "CO-5b $step hands the Agent tool '$want' for a recorded S3-security evaluation" \
            "$want" "$(d2099_orch_model "$(d2099_skill_file "$name")" "$sid_sec")"
    done <<EOF
$D2099_CONSUMERS
EOF
}

# CO-6..CO-8: the NONE fallback, driven the same way. An unrecorded session must
# land in the inline branch, and THAT branch's own command must still produce a
# level — otherwise the fallback dispatches with no model at all.
d2099_orch_none_fallback() {
    local sid name stage step f out want want_level
    sid=$(new_session orchnone)   # created, never recorded into
    while IFS='|' read -r name stage step _; do
        [ -n "$name" ] || continue
        f=$(d2099_skill_file "$name")
        assert_eq "CO-6 $step: an unrecorded session lands in the fallback, not on a model" \
            "FALLBACK" "$(d2099_orch_model "$f" "$sid")"

        case "$stage" in
            write_code) want="opus"; want_level="high" ;;
            *) want="sonnet"; want_level="low" ;;
        esac
        out=$(d2099_run_skill_cmd "$(d2099_extract_cmd "$f" "derive-complexity-level")" \
            "$sid" "S1-multi-file" | head -1)
        case "$out" in level=*) ;; *) out="UNPARSEABLE:$out" ;; esac
        assert_eq "CO-7 $step: the fallback's own command answers with a level for its stage" \
            "level=$want_level" "$out"
        assert_eq "CO-8 $step: ... which the file's mapping turns into the Agent model '$want'" \
            "$want" "$(d2099_orch_model_for "$f" "${out#level=}")"
    done <<EOF
$D2099_CONSUMERS
EOF
}

# CO-9/CO-10: the last link. Without this a skill could compute the right model
# and then dispatch a hardcoded one.
d2099_orch_agent_handoff() {
    local name stage step launch f
    while IFS='|' read -r name stage step launch; do
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

# --- CO-11..CO-14: the `model:` value the launch step actually dispatches -----
# CO-9/CO-10 read the launch step's PROSE: the slot is bound to the read step and
# is not a literal — never what comes OUT of that binding. The Agent call itself
# is unobservable from bash (Skipped-Because below); the SUBSTITUTION is not. So
# these cases fill the launch line's own `model:` slot from the read step's own
# command plus the file's own level→model mapping, and assert the literal
# argument that leaves — stored HIGH, stored LOW, and the NONE/fallback path.

# The launch step's `model:` slot, e.g. `<from MDP-3>`. Matched by the READ step
# id it must name, so a slot bound to nothing (or to a literal) yields "" — and
# read only inside the LAUNCH step's own section (round-10 C1).
d2099_orch_model_slot() {
    local f="$1" read_step="$2" launch
    launch=$(d2099_launch_step "$read_step")
    [ -n "$launch" ] || return 0
    d2099_skill_section "$f" "$launch" \
        | grep -m1 -oE "model: *<[^>]*$read_step[^>]*>" | sed -E 's/^model: *//'
}

# Resolve one consumer's launch-step slot into the literal argument the Agent
# tool would receive. `$3` is the signal csv the skill's inline judgment would
# carry; consulted ONLY when the read command answers NONE (the documented
# fallback branch).
d2099_orch_dispatched_model() {
    local f="$1" sid="$2" fb_signals="$3" read_step="$4" slot out first lvl model
    slot=$(d2099_orch_model_slot "$f" "$read_step")
    if [ -z "$slot" ]; then
        # Two different defects, two different tokens, so the failure message
        # says which one happened rather than just "not a model".
        if [ "$(d2099_has_re "$f" 'model: *"?(opus|sonnet)"?[ ,)]')" = "yes" ]; then
            echo "HARDCODED_MODEL_IN_LAUNCH"
        else
            echo "NO_MODEL_SLOT_BOUND_TO:$read_step"
        fi
        return
    fi
    out=$(d2099_run_skill_cmd "$(d2099_extract_cmd "$f" "read-complexity-evaluation")" "$sid")
    first=$(printf '%s\n' "$out" | head -1)
    [ "$first" = "__NO_COMMAND__" ] && { echo "NO_READ_COMMAND_IN_SKILL"; return; }
    if [ "$first" = "NONE" ]; then
        out=$(d2099_run_skill_cmd "$(d2099_extract_cmd "$f" "derive-complexity-level")" "$sid" "$fb_signals")
        first=$(printf '%s\n' "$out" | head -1)
        [ "$first" = "__NO_COMMAND__" ] && { echo "NO_DERIVE_COMMAND_IN_SKILL"; return; }
    fi
    case "$first" in
        level=*) lvl="${first#level=}" ;;
        *) echo "UNPARSEABLE:$first"; return ;;
    esac
    model=$(d2099_orch_model_for "$f" "$lvl")
    [ -n "$model" ] || { echo "NO_DOCUMENTED_MAPPING_FOR:$lvl"; return; }
    # The filled slot: what the Agent tool is handed, not what the level was.
    printf 'model: "%s"' "$model"
}

d2099_orch_dispatched_model_cases() {
    local name stage step f sid_hi sid_lo sid_none sid_s1 sid_sec want
    # (a) stored HIGH — S2-architecture is the signal that escalates all three
    # (solo for detail and write_tests, legacy_equivalent single for write_code,
    # detail.md D2). S3-security does NOT: detail has no S3 row, so it is the
    # divergent (e) case below, not this uniform control.
    sid_hi=$(new_session dispatchhigh)
    run_with_timeout node "$BIN_RECORD" --session "$sid_hi" --signals "S2-architecture" >/dev/null 2>&1
    # (b) stored LOW — a zero-signal record is the only input low on all three.
    sid_lo=$(new_session dispatchlow)
    run_with_timeout node "$BIN_RECORD" --session "$sid_lo" --signals "" >/dev/null 2>&1
    # (c) NONE — created, never recorded into, so the fallback branch runs.
    sid_none=$(new_session dispatchnone)
    # (d) the #2099 case itself: one stored record, two different models.
    sid_s1=$(new_session dispatchs1)
    run_with_timeout node "$BIN_RECORD" --session "$sid_s1" --signals "S1-multi-file" >/dev/null 2>&1
    # (e) the OTHER divergent row: S3-security splits detail from the other two,
    # where S1-multi-file splits write_code from the other two.
    sid_sec=$(new_session dispatchsec)
    run_with_timeout node "$BIN_RECORD" --session "$sid_sec" --signals "S3-security" >/dev/null 2>&1

    while IFS='|' read -r name stage step _; do
        [ -n "$name" ] || continue
        f=$(d2099_skill_file "$name")
        assert_eq "CO-11 $step's launch slot resolves to model: \"opus\" for a STORED high evaluation" \
            'model: "opus"' "$(d2099_orch_dispatched_model "$f" "$sid_hi" "" "$step")"
        assert_eq "CO-12 $step's launch slot resolves to model: \"sonnet\" for a STORED low evaluation" \
            'model: "sonnet"' "$(d2099_orch_dispatched_model "$f" "$sid_lo" "" "$step")"
        case "$stage" in write_code) want='model: "opus"' ;; *) want='model: "sonnet"' ;; esac
        assert_eq "CO-13 $step's launch slot resolves to $want on the NONE fallback path (nothing persisted; judged S1-multi-file)" \
            "$want" "$(d2099_orch_dispatched_model "$f" "$sid_none" "S1-multi-file" "$step")"
        # Without this row a resolver that ignored the level entirely — always
        # answering one model — would satisfy CO-11..CO-13 in isolation.
        assert_eq "CO-14 $step's launch slot resolves to $want for the STORED S1-multi-file record" \
            "$want" "$(d2099_orch_dispatched_model "$f" "$sid_s1" "" "$step")"
        # And the mirror split, so a resolver keyed to the write_code column alone
        # — which CO-11..CO-14 cannot separate from a correct one — is caught: here
        # detail is the odd stage out, not write_code.
        case "$stage" in detail) want='model: "sonnet"' ;; *) want='model: "opus"' ;; esac
        assert_eq "CO-15 $step's launch slot resolves to $want for the STORED S3-security record" \
            "$want" "$(d2099_orch_dispatched_model "$f" "$sid_sec" "" "$step")"
    done <<EOF
$D2099_CONSUMERS
EOF
}

# SKIPPED: observing the REAL Agent tool call at MDP-4 / WT-6 / WCD-4 and asserting
#   the `model:` the subagent is actually launched with.
# Because: `Agent(...)` exists only inside a live Claude Code session and the three
#   skills express the launch as PROSE ("Launch subagent (Agent tool, ..., model:
#   <from MDP-3>)"). No process, argv, env or file carries that value for a bash
#   harness to observe; `claude -p` would re-run the orchestration
#   nondeterministically and still never expose the subagent's model.
# L3 gap: an orchestrator that resolves the slot right and hands Agent something
#   else. Closest substitute: CO-9..CO-14. Only a TL3 transcript review closes it.

d2099_orch_commands_are_real
d2099_orch_recorded_selects_model
d2099_orch_none_fallback
d2099_orch_agent_handoff
d2099_orch_dispatched_model_cases

# Why CO-11..CO-14 IS the closest feasible approximation, not a convenient one.
# The chain is judge -> write point -> stored record -> read step -> `model:` slot
# -> Agent. CO-11..CO-14 own the last two links using each skill's OWN extracted
# read command, and E2E-1/E2E-2 (live-e2e-cases.sh, RUN_TL3) run every link before
# them against a real judge and the real write points. So exactly ONE link is
# unobserved anywhere: the argument crossing into Agent.
# Attempts considered and rejected: a stub `claude` on PATH (asserts the stub, not
# the skill); parsing a session transcript (Agent input is not written to one);
# a fake Agent tool (Claude Code has no tool-substitution seam). Faking any of
# these would report coverage of the one link nothing can see.
