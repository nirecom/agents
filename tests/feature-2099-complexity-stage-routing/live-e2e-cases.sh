#!/bin/bash
# tests/feature-2099-complexity-stage-routing/live-e2e-cases.sh
# Tests: skills/clarify-intent/SKILL.md, skills/workflow-init/SKILL.md, skills/make-detail-plan/SKILL.md, skills/write-tests/SKILL.md, skills/write-code/SKILL.md, bin/workflow/record-complexity-and-skip, bin/workflow/read-complexity-evaluation, bin/workflow/derive-complexity-level
# Tags: complexity, routing, e2e, live-agent, cross-module, tl3, scope:common
# Sourced by ../feature-2099-complexity-stage-routing.sh after the producer,
# consumer-orchestration and judge case files — their helpers are reused wholesale.
# Billable (spawns a real judge); gated exactly like JT-1.
D2099E_LANE_NOTE="judge -> write point -> store -> reader -> model, one session"

# Why this file exists: every sibling suite observes ONE link. The producer suite
# feeds the write point a hand-written csv; the consumer suite reads a hand-recorded
# session. Nothing runs the whole chain, so a seam break — a judge line the write
# point cannot parse, a record the consumers read differently — stays invisible.

# Two of the four rows need a fixture d2099j_write_fixture does not carry.
# S1-multi-file reuses the file-count fixture JT-12 judges at the threshold
# (CPR-SSOT: one body, one threshold constant). S3-security is written here
# rather than added to d2099j_write_fixture because PI-5 owns the adversarial
# security fixture and this one must stay deliberately plain.
d2099e_write_fixture() {
    local dir="$1" sig="$2"
    case "$sig" in
      S1-multi-file)
        d2099j_fixture "$dir" "$D2099J_S1_DOCUMENTED"
        ;;
      S3-security)
        d2099j_signal_fixture "$dir" <<'BODY'
# Intent

Tighten the permission check that guards the credential store: the reader
currently accepts any authenticated caller, and must instead require the
credential-read authorization scope before returning a secret.

Out of scope: no design decision, architectural change or refactor of any kind;
no install script, dotfile bootstrap or system configuration; no public API or
inter-process contract changes (the function signature is unchanged); EXACTLY
ONE file is touched; this intent file is the only prior-stage artifact, far
under 200 lines.
BODY
        ;;
      *) d2099j_write_fixture "$dir" "$sig" ;;
    esac
}

# The judge's marker -> the CLI's zero-signal value. Delegates to the runner's
# d2099_csv_for_cli so this lane, the consumer fallbacks and the write points all
# translate identically (CPR-SSOT; round-9 C1 found them diverged).
d2099e_csv_for_cli() {
    d2099_csv_for_cli "$1"
}

# The three stages as the stateless CLI derives them, in the reader's own order.
d2099e_derived_levels() {
    local csv="$1" st out acc=""
    for st in detail write_tests write_code; do
        out=$(run_with_timeout node "$BIN_DERIVE" --stage "$st" --signals "$csv" 2>/dev/null | head -1)
        acc="$acc${acc:+/}${out#level=}"
    done
    printf '%s' "$acc"
}

# id | fixture signal | expected exact set | stage levels | raw levels | models
# The last column is PER STAGE in the reader's order, because E2E-3 and E2E-4
# resolve different models at different stages from ONE record (detail.md D2) —
# and they split the stages in OPPOSITE directions, so a pipeline resolving all
# three from one shared level fails one of them whichever level it picked.
# E2E-1/E2E-2 are the uniform-high and uniform-low controls.
D2099E_ROWS='E2E-1|S2-architecture|S2-architecture|detail:high write_tests:high write_code:high|high/high/high|opus/opus/opus
E2E-2|none|none|detail:low write_tests:low write_code:low|low/low/low|sonnet/sonnet/sonnet
E2E-3|S1-multi-file|S1-multi-file|detail:low write_tests:low write_code:high|low/low/high|sonnet/sonnet/opus
E2E-4|S3-security|S3-security|detail:low write_tests:high write_code:high|low/high/high|sonnet/opus/opus'

# The model this row expects for ONE stage, out of the slash triple above.
d2099e_model_for() {
    case "$2" in
        detail)      printf '%s' "$1" | cut -d/ -f1 ;;
        write_tests) printf '%s' "$1" | cut -d/ -f2 ;;
        write_code)  printf '%s' "$1" | cut -d/ -f3 ;;
        *)           printf 'UNKNOWN_STAGE:%s' "$2" ;;
    esac
}

d2099e_run_row() {
    local id="$1" sig="$2" want_set="$3" want_stage="$4" want_levels="$5" want_models="$6"
    local dir line ids csv pname pstep f sid raw stages want_raw agg name stage step want_model

    dir="$TMPDIR_BASE/e2e-$sig"
    d2099e_write_fixture "$dir" "$sig"
    line=$(d2099j_judge "$dir")
    case "$line" in
        RC*) fail "$id the gated live judge invocation FAILED on the $sig fixture — an unreachable judge is a broken integration, not a skip: [$line]"; return ;;
        '')  fail "$id the live judge emitted no parseable 'SIGNALS:' line for the $sig fixture"; return ;;
        *)   pass "$id a real judge produced the verdict that drives this whole chain ($line)" ;;
    esac
    ids=$(d2099j_ids "$line")

    # Step 1 — the judge's own line, pinned. Everything downstream is attributed to
    # this exact set, so a drifting judge is reported here rather than surfacing as
    # a routing bug three assertions later.
    if [ "$want_set" = "none" ]; then
        assert_eq "${id}a a task tripping no rubric signal is judged exactly 'none'" "none" "$ids"
    else
        d2099j_assert_exact_set "${id}set" "$want_set" "$ids"
    fi
    csv=$(d2099e_csv_for_cli "$ids")
    want_raw=$( [ -z "$csv" ] && echo '[]' || printf '["%s"]' "$sig" )
    agg=$( [ -z "$csv" ] && echo low || echo high )

    # Step 2 — the REAL write points, running their OWN documented command line
    # with the judge's csv as its `--signals` value.
    while IFS='|' read -r pname pstep _; do
        [ -n "$pname" ] || continue
        f=$(d2099p_skill_file "$pname")
        sid=$(new_session "e2e-$pname-$sig")
        if [ "$(d2099p_run_producer "$f" "$sid" "$csv")" = "__NO_COMMAND__" ]; then
            fail "${id}b [$pstep] unattributable: the write point carries no runnable record-complexity-and-skip line, so nothing was produced to read back"
            continue
        fi

        # Step 3 — what actually LANDED, straight off the append-only log.
        raw=$(d2099p_raw_event "$sid")
        assert_eq "${id}b [$pstep] the judge's verdict is persisted verbatim, with the D2 levels beside it" \
            "n=1 level=$agg signals=$want_raw levels=$want_levels" "$raw"

        # Step 4 — the READER's answer must equal what the producer recorded: two
        # independent code paths over one real record.
        stages=$(d2099p_stage_levels "$sid")
        assert_eq "${id}c [$pstep] read-complexity-evaluation --stage returns the levels the producer recorded" \
            "$want_levels" "$stages"
        assert_eq "${id}d [$pstep] ... and the stateless derive CLI agrees on the same signal line" \
            "$want_levels" "$(d2099e_derived_levels "$csv")"

        # Step 5 — the three MUST consumers, each resolving ITS OWN launch-step
        # `model:` slot from that same stored session, and each compared against
        # the model ITS OWN stage column names — not one row-wide value.
        while IFS='|' read -r name stage step _; do
            [ -n "$name" ] || continue
            want_model=$(d2099e_model_for "$want_models" "$stage")
            assert_eq "${id}e [$pstep -> $step] the $stage launch slot resolves to model: \"$want_model\" for the recorded verdict" \
                "model: \"$want_model\"" \
                "$(d2099_orch_dispatched_model "$(d2099_skill_file "$name")" "$sid" "" "$step")"
        done <<CONS
$D2099_CONSUMERS
CONS
    done <<PROD
$D2099P_PRODUCERS
PROD

    # Anchored to D2 once more, so the row's expectation is not merely the reader
    # and the writer agreeing with each other.
    d2099j_assert_stage_levels "${id}f" "$csv" "$want_stage"
}

d2099e_live_chain() {
    local reason id sig want_set want_stage want_levels want_models
    reason=$(d2099j_gate_reason)
    while IFS='|' read -r id sig want_set want_stage want_levels want_models; do
        [ -n "$id" ] || continue
        if [ -n "$reason" ]; then
            gated_skip "$id live judge-to-model chain [$sig]: $reason"
            continue
        fi
        d2099e_run_row "$id" "$sig" "$want_set" "$want_stage" "$want_levels" "$want_models"
    done <<EOF
$D2099E_ROWS
EOF
}

# SKIPPED: the literal `Agent(... model: ...)` call at MDP-4 / WT-6 / WCD-4.
# Because: Agent exists only inside a live Claude Code session and the three skills
#   express the launch as prose. Even in THIS lane — a real `claude` process — the
#   subagent's model reaches no argv, env, file or stdout a bash harness can read
#   (round 4's C2 investigation reached the same conclusion).
# Closest substitute: step 5 above plus CO-11..CO-14 — the launch step's own
#   `model:` slot resolved from the read step's own command, asserted as the
#   literal argument that would leave. Every link EXCEPT the tool dispatch runs here.
# L3 gap: an orchestrator that resolves the slot right and hands Agent something
#   else. Checked at WORKFLOW_USER_VERIFIED preflight (skill-orchestration).

d2099e_live_chain
