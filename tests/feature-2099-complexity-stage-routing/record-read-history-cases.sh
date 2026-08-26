#!/bin/bash
# tests/feature-2099-complexity-stage-routing/record-read-history-cases.sh
# Tests: bin/workflow/record-complexity-evaluation, bin/workflow/read-complexity-evaluation, bin/workflow/record-complexity-and-skip, hooks/workflow-state/state-io/projection.js, hooks/workflow-state/state-io/events.js
# Tags: complexity, routing, idempotency, history, projection, scope:issue-specific
# Sourced by ../feature-2099-complexity-stage-routing.sh AFTER record-read-cases.sh —
# d2099_raw_ce_count lives there. Split per rules/coding/file-split.md Pattern A.

# The three stages exactly as a consumer reads them: one `--stage` call each.
d2099h_stage_matrix() {
    local sid="$1" st acc=""
    for st in detail write_tests write_code; do
        acc="$acc$st:$(run_with_timeout node "$BIN_READ" --session "$sid" --stage "$st" 2>/dev/null | tr '\n' ';') "
    done
    printf '%s' "$acc"
}

# The back-compat (no --stage) view: aggregate level, signals, and the whole
# `levels` map in one line, so a stale FIELD is visible next to a stale STAGE.
d2099h_compat_view() {
    run_with_timeout node "$BIN_READ" --session "$1" 2>/dev/null | tr '\n' ';'
}

# R-33: idempotency at the RAW EVENT layer, through both entry points. The
# projection is last-write-wins, but appendEvents() does no dedup, coalescing or
# rewriting of history, so repeating an identical evaluation deliberately
# APPENDS another event — the audit trail must record that the judgement was
# made N times. Pinning "the count does not grow" would encode the opposite.
d2099_raw_event_idempotency() {
    local sid got
    sid=$(new_session idemapi)
    D2099_SID="$sid" BARREL="$BARREL_N" run_with_timeout node -e '
const b = require(process.env.BARREL);
const sid = process.env.D2099_SID;
b.recordComplexityEvaluation(sid, ["S1-multi-file"]);
b.recordComplexityEvaluation(sid, ["S1-multi-file"]);
b.recordComplexityEvaluation(sid, ["S1-multi-file"]);
' >/dev/null 2>&1 || true
    got=$(D2099_SID="$sid" BARREL="$BARREL_N" run_with_timeout node -e '
const b = require(process.env.BARREL);
const s = b.readState(process.env.D2099_SID);
const ev = ((s && s.events) || []).filter(function (e) { return e && e.kind === "complexity_evaluation"; });
const ce = b.readComplexityEvaluation(process.env.D2099_SID);
console.log("events=" + ev.length + " folded=" + (ce ? ce.signals.join(",") : "NONE"));
' 2>/dev/null)
    assert_eq "R-33 three identical API records append three raw events, folding to one record" \
        "events=3 folded=S1-multi-file" "$got"

    # Same property through the bash wrapper — the layer a consumer actually uses.
    local sid2
    sid2=$(new_session idemcli)
    run_with_timeout bash "$BIN_RECORD_SKIP" --session "$sid2" --signals "S1-multi-file" --target outline >/dev/null 2>&1
    run_with_timeout bash "$BIN_RECORD_SKIP" --session "$sid2" --signals "S1-multi-file" --target outline >/dev/null 2>&1
    got=$(D2099_SID="$sid2" BARREL="$BARREL_N" run_with_timeout node -e '
const b = require(process.env.BARREL);
const s = b.readState(process.env.D2099_SID);
const ev = ((s && s.events) || []).filter(function (e) { return e && e.kind === "complexity_evaluation"; });
const ce = b.readComplexityEvaluation(process.env.D2099_SID);
console.log("events=" + ev.length + " folded=" + (ce ? ce.signals.join(",") : "NONE"));
' 2>/dev/null)
    assert_eq "R-34 two identical wrapper invocations likewise append two raw events, folding to one" \
        "events=2 folded=S1-multi-file" "$got"
}

# R-45..R-47: two DIFFERENT evaluations in one session. R-33/R-34 repeat the same
# signals, so a projection that merged old and new instead of replacing would look
# identical there. Here the second evaluation differs on every field the record
# carries — `level`, `signals` AND the per-stage `levels` map — so each stage
# reader must observe the SECOND evaluation alone. A stale mix is the defect: a
# `levels` map left over from the first record routes a stage to a model the
# current signal set never justified, in either direction (detail.md D3/D4).
# Both raw events stay in the append-only log throughout (detail.md D6).
#
# Rows: label | first signals | second signals | stage matrix after | compat view after
D2099_REEVAL='low-to-high||S2-architecture,S5-breaking|high|high|high|high|S2-architecture,S5-breaking
high-to-low|S3-security||low|low|low|low|none
map-replacement|S2-architecture|S1-multi-file|low|low|high|high|S1-multi-file'

d2099_reevaluation_replaces_projection() {
    local label first second d wt wc agg sig sid want
    while IFS='|' read -r label first second d wt wc agg sig; do
        [ -n "$label" ] || continue
        sid=$(new_session "reeval-$label")

        # Evaluation 1, asserted before the second one lands: without this the
        # "replaced" assertion below could pass against a session where the FIRST
        # record never took effect at all.
        run_with_timeout node "$BIN_RECORD" --session "$sid" --signals "$first" >/dev/null 2>&1
        assert_eq "R-45 [$label] the first evaluation really is what the session holds before the re-evaluation" \
            "1" "$(d2099_raw_ce_count "$sid")"
        assert_contains "R-45a [$label] ... and it is the first signal set the stages read" \
            "signals=$( [ -n "$first" ] && printf '%s' "$first" || printf 'none' );" \
            "$(d2099h_compat_view "$sid")"

        run_with_timeout node "$BIN_RECORD" --session "$sid" --signals "$second" >/dev/null 2>&1

        want="detail:level=$d;signals=${sig}; write_tests:level=$wt;signals=${sig}; write_code:level=$wc;signals=${sig}; "
        assert_eq "R-46 [$label] every stage reader observes ONLY the second evaluation's levels and signals" \
            "$want" "$(d2099h_stage_matrix "$sid")"
        assert_eq "R-46a [$label] ... and the whole record — level, signals and the levels map — is the second evaluation's, not a mix" \
            "level=$agg;signals=$sig;levels={\"detail\":\"$d\",\"write_tests\":\"$wt\",\"write_code\":\"$wc\"};" \
            "$(d2099h_compat_view "$sid")"
        assert_eq "R-47 [$label] ... while BOTH raw evaluations remain in the append-only log" \
            "2" "$(d2099_raw_ce_count "$sid")"
    done <<EOF
$D2099_REEVAL
EOF
}

d2099_raw_event_idempotency
d2099_reevaluation_replaces_projection
