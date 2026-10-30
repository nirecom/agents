#!/bin/bash
# tests/hooks/feature-2099-complexity-stage-routing/producer-orchestration-cases.sh
# Tests: skills/clarify-intent/SKILL.md, skills/workflow-init/SKILL.md, skills/_shared/complexity-and-outline-skip.md, bin/workflow/normalize-judge-signals, bin/workflow/record-complexity-evaluation,bin/workflow/read-complexity-evaluation
# Tags: complexity, routing, producers, integration, skip-dispatch, jev, shared-procedure, scope:issue-specific
# Sourced by the feature-2099-complexity-stage-routing-*.sh entrypoints — helpers come from there.
# #2460: CI-C1b / A3a delegate to the COS procedure, which runs the shared judge
# (skills/_shared/jev-two-stage-judge.md); its JJ-4 complexity write is
# `record-complexity-evaluation --signals "<SIGNALS_CSV>"`, so the producers'
# persisted shape is asserted through that one CLI.

# skill dir | step label | write target
D2099P_PRODUCERS="clarify-intent|CI-C1b|outline
workflow-init|A3a|outline"

D2099P_COS_REF="skills/_shared/complexity-and-outline-skip.md"

d2099p_skill_file() { echo "$SCRIPT_CHECKOUT_ROOT/skills/$1/SKILL.md"; }
d2099p_cos_file() { echo "$SCRIPT_CHECKOUT_ROOT/$D2099P_COS_REF"; }

D2099P_PLANS=""
d2099p_plans_dir() {
    if [ -z "$D2099P_PLANS" ]; then
        D2099P_PLANS="$TMPDIR_BASE/producer-plans"
        mkdir -p "$D2099P_PLANS"
    fi
    printf '%s' "$D2099P_PLANS"
}

# The producer write for one session: the JJ-4 complexity record with the csv the
# judge settled (empty csv = zero signals). Kept under its old name and argument
# order for callers that still pass the skill file first.
d2099p_run_producer() {
    local sid="$2" signals="$3"
    run_with_timeout node "$BIN_RECORD" --session "$sid" --signals "$signals" 2>/dev/null | tail -1
}

# The raw persisted event, straight out of the append-only log — never through the
# compatibility read that backfills `levels` (detail.md D6).
d2099p_raw_event() {
    BARREL="$BARREL_N" SID="$1" run_with_timeout node -e '
const b = require(process.env.BARREL);
const s = b.readState(process.env.SID);
const ev = ((s && s.events) || []).filter((e) => e && e.kind === "complexity_evaluation");
ev.length || (console.log("__NO_EVENT__"), process.exit(0));
const e = ev[ev.length - 1];
console.log("n=" + ev.length
  + " level=" + String(e.level)
  + " signals=" + JSON.stringify(e.signals)
  + " levels=" + (e.levels ? [e.levels.detail, e.levels.write_tests, e.levels.write_code].join("/") : String(e.levels)));
' 2>&1
}

# The three stage levels as the CONSUMERS would read them back.
d2099p_stage_levels() {
    local sid="$1" st out acc=""
    for st in detail write_tests write_code; do
        out=$(run_with_timeout node "$BIN_READ" --session "$sid" --stage "$st" 2>/dev/null | head -1)
        acc="$acc${acc:+/}${out#level=}"
    done
    printf '%s' "$acc"
}

# PO-1/PO-2: both write points delegate to the ONE shared COS procedure (CPR-ORTH).
d2099p_write_points_delegate() {
    local name step target n acc=""
    while IFS='|' read -r name step target; do
        [ -n "$name" ] || continue
        n=$(d2099_skill_section "$(d2099p_skill_file "$name")" "$step" | grep -cF -- "$D2099P_COS_REF")
        acc="$acc${acc:+ }$n"
    done <<EOF
$D2099P_PRODUCERS
EOF
    assert_eq "PO-2 CI-C1b and A3a each reference the one shared COS procedure (CPR-ORTH)" "1 1" "$acc"
    assert_eq "PO-2a the shared COS procedure file exists" "yes" \
        "$( [ -f "$(d2099p_cos_file)" ] && echo yes || echo no )"
}

# PO-3..PO-5: the end-state signal shapes the judge settles, recorded the way
# JJ-4 records them. Levels per detail/write_tests/write_code (#2460 end-state):
# S1b low/low/high, S3 low/high/high, S2 and S0 high everywhere, zero low.
d2099p_record_scenarios() {
    local label signals want_raw want_levels sid
    while IFS='|' read -r label signals want_raw want_levels; do
        [ -n "$label" ] || continue
        signals=${signals//%EMPTY%/}
        sid=$(new_session "prod-rec-$label")
        d2099p_run_producer "" "$sid" "$signals" >/dev/null
        assert_contains "PO-3 [$label] exactly one raw complexity_evaluation event carries the recorded signals and stage levels" \
            "signals=$want_raw levels=$want_levels" "$(d2099p_raw_event "$sid")"
        assert_contains "PO-4 [$label] ... and it is the only one" "n=1 " "$(d2099p_raw_event "$sid")"
        assert_eq "PO-5 [$label] the three stages read back the end-state routing levels" \
            "$want_levels" "$(d2099p_stage_levels "$sid")"
    done <<'SCEN'
zero|%EMPTY%|[]|low/low/low
wide|S1b-wide-change|["S1b-wide-change"]|low/low/high
security|S3-security|["S3-security"]|low/high/high
multi|S2-architecture,S4-installer|["S2-architecture","S4-installer"]|high/high/high
undecidable|S0-undecidable|["UNRECOGNIZED(1)"]|high/high/high
SCEN
}

# PO-INJ-4/5: exactly one of --signals / --signals-file at the node CLI, so no
# caller can end up with an ambiguous or absent csv source.
d2099p_signals_flag_arity() {
    local sid f out rc
    f="$(d2099p_plans_dir)/arity-signals.txt"
    printf 'S1b-wide-change\n' > "$f"

    sid=$(new_session "prodarity-both-n")
    rc=0
    out=$(run_with_timeout node "$BIN_RECORD" --session "$sid" --signals "S1b-wide-change" \
        --signals-file "$f" 2>&1) || rc=$?
    assert_eq "PO-INJ-4c the node CLI rejects both flags (exit 1)" "1" "$rc"
    assert_contains "PO-INJ-4d ... with the mutual-exclusion message" "mutually exclusive" "$out"

    sid=$(new_session "prodarity-none-n")
    rc=0
    out=$(run_with_timeout node "$BIN_RECORD" --session "$sid" 2>&1) || rc=$?
    assert_eq "PO-INJ-5c the node CLI rejects neither flag (exit 1)" "1" "$rc"
    assert_contains "PO-INJ-5d ... with the required-flag message" "is required" "$out"
}

# PO-INJ-6: a legitimate csv delivered by file records EXACTLY what the same csv
# delivered by --signals records — otherwise the file path is a divergent parser.
d2099p_signals_file_round_trip() {
    local label csv sid_f sid_s f
    while IFS='|' read -r label csv; do
        [ -n "$label" ] || continue
        csv=${csv//%EMPTY%/}
        sid_f=$(new_session "prodrt-file-$label")
        f="$(d2099p_plans_dir)/$sid_f-roundtrip.txt"
        printf '%s\n' "$csv" > "$f"
        run_with_timeout node "$BIN_RECORD" --session "$sid_f" --signals-file "$f" >/dev/null 2>&1
        sid_s=$(new_session "prodrt-arg-$label")
        run_with_timeout node "$BIN_RECORD" --session "$sid_s" --signals "$csv" >/dev/null 2>&1
        assert_eq "PO-INJ-6 [$label] --signals-file records what --signals records" \
            "$(d2099p_raw_event "$sid_s")" "$(d2099p_raw_event "$sid_f")"
    done <<RT
empty|%EMPTY%
single|S1b-wide-change
multi|S2-architecture,S4-installer
spaced|S2-architecture, S4-installer
undecidable|S0-undecidable
RT
}

# PO-10..14 (outline-stage call sites) and PO-20..23 (COS steps) are stage-5
# checks: ../feature-2460-jev-call-sites-static/producer-call-sites.sh.

case_begin "producer-write-points-delegate" "skills/clarify-intent/SKILL.md"
d2099p_write_points_delegate
case_end

case_begin "producer-record-scenarios" "bin/workflow/read-complexity-evaluation"
d2099p_record_scenarios
d2099p_signals_flag_arity
d2099p_signals_file_round_trip
case_end
