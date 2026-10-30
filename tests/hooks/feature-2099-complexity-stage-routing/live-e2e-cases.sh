#!/bin/bash
# tests/hooks/feature-2099-complexity-stage-routing/live-e2e-cases.sh
# Tests: skills/clarify-intent/SKILL.md, skills/workflow-init/SKILL.md, skills/make-detail-plan/SKILL.md, skills/write-tests/SKILL.md, skills/write-code/SKILL.md, bin/workflow/record-complexity-evaluation, bin/workflow/read-complexity-evaluation, bin/workflow/derive-complexity-level
# Tags: complexity, routing, e2e, live-agent, cross-module, tl3, scope:common
# Sourced by the feature-2099-complexity-stage-routing-*.sh entrypoints after the consumer-
# orchestration and judge case files — their helpers are reused wholesale.
# Billable (spawns a real judge); gated exactly like JT-6.
D2099E_LANE_NOTE="judge -> record CLI -> store -> reader -> model, one session"

# Why this file exists: every sibling suite observes ONE link. Nothing else runs
# the whole chain, so a seam break — a judge line the record CLI cannot take, a
# record the consumers read differently — stays invisible.
# #2460: the chain records through the end-state write CLI ($BIN_RECORD), which
# must record the judge's verdict and never skip a step (step 2n).

# Every row's fixture body is owned by d2099j_write_fixture (CPR-SSOT), the same
# bodies JT-6..JT-10 judge.
d2099e_write_fixture() {
    d2099j_write_fixture "$1" "$2"
}

# The judge's marker -> the CLI's zero-signal value (the runner's shared mapping).
d2099e_csv_for_cli() {
    d2099_csv_for_cli "$1"
}

D2099E_STAGES="outline detail write_tests write_code"

# The four stages as the stateless CLI derives them, in D2099E_STAGES order.
d2099e_derived_levels() {
    local csv="$1" st out acc=""
    for st in $D2099E_STAGES; do
        out=$(run_with_timeout node "$BIN_DERIVE" --stage "$st" --signals "$csv" 2>/dev/null | head -1)
        acc="$acc${acc:+/}${out#level=}"
    done
    printf '%s' "$acc"
}

# The four stages as the reader answers them for one recorded session.
d2099e_read_levels() {
    local sid="$1" st out acc=""
    for st in $D2099E_STAGES; do
        out=$(run_with_timeout node "$BIN_READ" --session "$sid" --stage "$st" 2>/dev/null | head -1)
        acc="$acc${acc:+/}${out#level=}"
    done
    printf '%s' "$acc"
}

# The raw persisted event, straight off the append-only log — never through the
# compatibility read that backfills `levels`.
d2099e_raw_event() {
    BARREL="$BARREL_N" SID="$1" run_with_timeout node - 2>&1 <<'JS'
const b = require(process.env.BARREL);
const s = b.readState(process.env.SID);
const ev = ((s && s.events) || []).filter(function (e) { return e && e.kind === "complexity_evaluation"; });
if (!ev.length) { console.log("__NO_EVENT__"); process.exit(0); }
const e = ev[ev.length - 1];
const l = e.levels;
console.log("n=" + ev.length + " level=" + String(e.level) + " signals=" + JSON.stringify(e.signals)
  + " levels=" + (l ? [l.outline, l.detail, l.write_tests, l.write_code].join("/") : String(l)));
JS
}

# id | fixture key | expected exact set | stage:level pairs | levels | models
# Levels and models are PER STAGE in D2099E_STAGES order. E2E-1/E2E-2 are the
# uniform-high and uniform-low controls; E2E-4 splits the stages, so a pipeline
# resolving all four from one shared level fails it. E2E-3 is the deterministic-
# only fixture: the judge stays silent, so nothing on this path raises a stage.
D2099E_ROWS='E2E-1|S2-architecture|S2-architecture|outline:high detail:high write_tests:high write_code:high|high/high/high/high|opus/opus/opus/opus
E2E-2|none|none|outline:low detail:low write_tests:low write_code:low|low/low/low/low|sonnet/sonnet/sonnet/sonnet
E2E-3|deterministic-only|none|outline:low detail:low write_tests:low write_code:low|low/low/low/low|sonnet/sonnet/sonnet/sonnet
E2E-4|S3-security|S3-security|outline:low detail:low write_tests:high write_code:high|low/low/high/high|sonnet/sonnet/opus/opus'

# The model this row expects for ONE stage, out of the slash quadruple above.
d2099e_model_for() {
    case "$2" in
        outline)     printf '%s' "$1" | cut -d/ -f1 ;;
        detail)      printf '%s' "$1" | cut -d/ -f2 ;;
        write_tests) printf '%s' "$1" | cut -d/ -f3 ;;
        write_code)  printf '%s' "$1" | cut -d/ -f4 ;;
        *)           printf 'UNKNOWN_STAGE:%s' "$2" ;;
    esac
}

d2099e_run_row() {
    local id="$1" key="$2" want_set="$3" want_stage="$4" want_levels="$5" want_models="$6"
    local dir line ids csv sid rc want_raw agg name stage step want_model

    dir="$TMPDIR_BASE/e2e-$key"
    d2099e_write_fixture "$dir" "$key"
    line=$(d2099j_judge "$dir")
    case "$line" in
        RC*) fail "$id the gated live judge invocation FAILED on the $key fixture — an unreachable judge is a broken integration, not a skip: [$line]"; return ;;
        '')  fail "$id the live judge emitted no parseable 'SIGNALS:' line for the $key fixture"; return ;;
        *)   pass "$id a real judge produced the verdict that drives this whole chain ($line)" ;;
    esac
    ids=$(d2099j_ids "$line")

    # Step 1 — the judge's own line, pinned, so a drifting judge is reported here
    # rather than surfacing as a routing bug further down.
    if [ "$want_set" = "none" ]; then
        assert_eq "${id}a the fixture [$key] is judged exactly 'none'" "none" "$ids"
    else
        d2099j_assert_exact_set "${id}set" "$want_set" "$ids"
    fi
    csv=$(d2099e_csv_for_cli "$ids")
    want_raw=$( [ -z "$csv" ] && echo '[]' || printf '["%s"]' "$want_set" )
    agg=$( [ -z "$csv" ] && echo low || echo high )

    # Step 2 — the end-state write CLI, fed the judge's csv verbatim.
    sid=$(new_session "e2e-$key")
    rc=0
    run_with_timeout node "$BIN_RECORD" --session "$sid" --signals "$csv" >/dev/null 2>&1 || rc=$?
    assert_eq "${id}b record-complexity-evaluation accepts the judge's signal line (exit 0)" "0" "$rc"

    # Step 2n — whatever the judge said (zero signals used to auto-skip), the
    # record skips neither planning stage.
    assert_eq "${id}n ... and skips neither planning stage" \
        "outline=pending detail=pending skip=0" "$(d2099_no_skip_view "$sid")"

    # Step 3 — what actually LANDED, straight off the append-only log.
    assert_eq "${id}c the verdict is persisted verbatim, with the D2 levels beside it" \
        "n=1 level=$agg signals=$want_raw levels=$want_levels" "$(d2099e_raw_event "$sid")"

    # Step 4 — the reader and the stateless derive CLI: two independent code paths
    # that must both equal the recorded levels.
    assert_eq "${id}d read-complexity-evaluation --stage returns the levels that were recorded" \
        "$want_levels" "$(d2099e_read_levels "$sid")"
    assert_eq "${id}e ... and the stateless derive CLI agrees on the same signal line" \
        "$want_levels" "$(d2099e_derived_levels "$csv")"

    # Step 5 — each MUST consumer resolves ITS OWN launch-step `model:` slot from
    # the stored session, compared against the model ITS OWN stage column names.
    while IFS='|' read -r name stage step _; do
        [ -n "$name" ] || continue
        want_model=$(d2099e_model_for "$want_models" "$stage")
        assert_eq "${id}f [$step] the $stage launch slot resolves to model: \"$want_model\" for the recorded verdict" \
            "model: \"$want_model\"" \
            "$(d2099_orch_dispatched_model "$(d2099_skill_file "$name")" "$sid" "" "$step")"
    done <<CONS
$D2099_CONSUMERS
CONS

    # Anchored to D2 once more, so the row is not merely writer and reader agreeing.
    d2099j_assert_stage_levels "${id}g" "$csv" "$want_stage"
}

d2099e_live_chain() {
    local reason id key want_set want_stage want_levels want_models
    reason=$(d2099j_gate_reason)
    while IFS='|' read -r id key want_set want_stage want_levels want_models; do
        [ -n "$id" ] || continue
        if [ -n "$reason" ]; then
            gated_skip "$id live judge-to-model chain [$key]: $reason"
            continue
        fi
        d2099e_run_row "$id" "$key" "$want_set" "$want_stage" "$want_levels" "$want_models"
    done <<EOF
$D2099E_ROWS
EOF
}

# SKIPPED: the literal `Agent(... model: ...)` call at MDP-4 / WT-7 / WCD-4.
# Because: Agent exists only inside a live Claude Code session; the subagent's
#   model reaches no argv, env, file or stdout a bash harness can read.
# Closest substitute: step 5 above plus CO-11..CO-14 — the launch step's own
#   `model:` slot resolved from the read step's own command.
# L3 gap: an orchestrator that resolves the slot right and hands Agent something
#   else. Checked at WORKFLOW_USER_VERIFIED preflight (skill-orchestration).

case_begin "live-judge-to-model-chain" "bin/workflow/read-complexity-evaluation"
d2099e_live_chain
case_end
