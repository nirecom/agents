#!/bin/bash
# tests/feature-2099-complexity-stage-routing/invalid-levels-atomicity-cases.sh
# Tests: hooks/workflow-state/state-io/events.js, hooks/workflow-state/state-io/projection.js, hooks/workflow-state/state-io/migrations/v1-to-v2.js, hooks/workflow-state/skip-signal-resolver/complexity.js, bin/workflow/read-complexity-evaluation
# Tags: complexity, routing, validation, atomicity, migration, projection, scope:issue-specific
# Sourced by ../feature-2099-complexity-stage-routing.sh after record-read-cases.sh
# (reuses d2099_inject_raw_event / d2099_state_bytes / d2099_raw_ce_count).

# Why: validateEvent is only the FIRST barrier against an out-of-vocabulary
# `levels.<stage>`; its append-time half is owned by feature-1733 EV13. These
# cases pin the SECOND barrier — a malformed map already on disk, raw-injected
# or produced by the v1->v2 migration, the one producer that skips validateEvent.

# The malformed shapes, in the one place both halves of this file read them from.
d2099il_bad_levels_json() {
    case "$1" in
        bad-value)  printf '{"detail":"low","write_tests":"low","write_code":"medium"}' ;;
        missing-key) printf '{"detail":"low","write_tests":"low"}' ;;
        extra-key)  printf '{"detail":"low","write_tests":"low","write_code":"low","docs":"low"}' ;;
        capitalized) printf '{"detail":"Low","write_tests":"low","write_code":"low"}' ;;
        array)      printf '["low","low","low"]' ;;
        string)     printf '"high"' ;;
        # One stage value out of vocabulary, the OTHERS deliberately disagreeing
        # with what the signals derive — so "partially trusted" is observable.
        partial)    printf '{"detail":"high","write_tests":"high","write_code":"medium"}' ;;
        good)       printf '{"detail":"low","write_tests":"low","write_code":"high"}' ;;
    esac
}

d2099il_seed_raw() {
    local sid shape
    sid=$(new_session "il-$1")
    shape=$(d2099il_bad_levels_json "$1")
    d2099_inject_raw_event "$sid" "{\"level\":\"high\",\"signals\":[\"S1-multi-file\"],\"levels\":$shape}" >/dev/null
    echo "$sid"
}

# IL-1: the projection is the barrier. A malformed map already on disk must fold
# to a NULL per-stage view — never be carried through as-is — while the record
# itself (aggregate level + signals) survives, because dropping the whole
# evaluation would silently re-run the judge instead of using what was decided.
d2099il_projection_strips_malformed_levels() {
    local shape sid got out=""
    for shape in bad-value missing-key extra-key capitalized array string partial good; do
        sid=$(d2099il_seed_raw "$shape")
        got=$(BARREL="$BARREL_N" SID="$sid" run_with_timeout node -e '
const b = require(process.env.BARREL);
const s = b.readState(process.env.SID);
const ce = s && s.complexity_evaluation;
console.log((ce ? "level=" + ce.level + " levels=" + JSON.stringify(ce.levels) : "NO_RECORD"));
' 2>&1)
        out="$out$shape -> $got"$'\n'
    done
    assert_block "IL-1 a malformed levels map on disk folds to null; the record itself survives" \
        "$(printf '%s' "$out")" <<'EOF'
bad-value -> level=high levels=null
missing-key -> level=high levels=null
extra-key -> level=high levels=null
capitalized -> level=high levels=null
array -> level=high levels=null
string -> level=high levels=null
partial -> level=high levels=null
good -> level=high levels={"detail":"low","write_tests":"low","write_code":"high"}
EOF
}

# IL-2: what the STAGE consumer is handed. The consumer read is
# compatibility-completing by design (skip-signal-resolver/complexity.js header):
# a malformed map is re-derived IN FULL from the recorded signals, so no
# out-of-vocabulary value ever reaches a stage decision, and — the half that
# matters — no still-plausible-looking sibling key is partially trusted either.
d2099il_stage_read_is_rederived() {
    local shape sid out="" st
    for shape in bad-value missing-key array partial good; do
        sid=$(d2099il_seed_raw "$shape")
        out="$out$shape ->"
        for st in detail write_tests write_code; do
            out="$out $st=$(run_with_timeout node "$BIN_READ" --session "$sid" --stage "$st" 2>/dev/null | head -1)"
        done
        out="$out"$'\n'
    done
    # Every malformed row must equal the `good` row, which is what the recorded
    # signal set (S1-multi-file) derives on its own.
    assert_block "IL-2 a malformed levels map is re-derived in full from the recorded signals" \
        "$(printf '%s' "$out")" <<'EOF'
bad-value -> detail=level=low write_tests=level=low write_code=level=high
missing-key -> detail=level=low write_tests=level=low write_code=level=high
array -> detail=level=low write_tests=level=low write_code=level=high
partial -> detail=level=low write_tests=level=low write_code=level=high
good -> detail=level=low write_tests=level=low write_code=level=high
EOF

    # Teeth for IL-2: the re-derivation is the SAME answer the stateless CLI
    # gives for those signals — not a constant the reader happens to emit.
    assert_eq "IL-3 ... and that re-derivation matches the stateless derive CLI for the same signals" \
        "$(run_with_timeout node "$BIN_DERIVE" --stage write_code --signals "S1-multi-file" 2>/dev/null)" \
        "$(run_with_timeout node "$BIN_READ" --session "$(d2099il_seed_raw bad-value)" --stage write_code 2>/dev/null | head -1)"

    # And the `partial` row above only has teeth because its stored detail value
    # ("high") DISAGREES with the derived one — it was discarded, not kept.
    sid=$(d2099il_seed_raw partial)
    assert_not_contains "IL-4 a stored stage value beside a malformed sibling is discarded, never partially trusted" \
        "high" "$(run_with_timeout node "$BIN_READ" --session "$sid" --stage detail 2>/dev/null | head -1)"
}

# IL-5: the back-compat (no --stage) mode carries the same completed map, and
# the malformed value never appears in the JSON a caller would parse.
d2099il_aggregate_read_completes_levels() {
    local sid got
    sid=$(d2099il_seed_raw bad-value)
    got=$(run_with_timeout node "$BIN_READ" --session "$sid" 2>/dev/null | tr '\n' ';')
    assert_eq "IL-5 back-compat mode emits the re-derived levels= map" \
        "level=high;signals=S1-multi-file;levels={\"detail\":\"low\",\"write_tests\":\"low\",\"write_code\":\"high\"};" "$got"
    assert_not_contains "IL-6 ... and no out-of-vocabulary value leaks onto stdout" "medium" "$got"
    assert_eq "IL-6a ... and the completed read is still exit 0" \
        "0" "$(run_with_timeout node "$BIN_READ" --session "$sid" >/dev/null 2>&1; echo $?)"
}

# IL-7: the append-time barrier, from THIS issue's side. The full malformed
# vocabulary and its byte-level atomicity are owned by feature-1733 EV13; what
# is asserted here is that the barrier still stands in front of the #2099 writer
# path, so IL-1's "already on disk" premise is reachable only by bypassing it.
d2099il_append_is_refused_atomically() {
    local sid before after_bytes after_count err
    sid=$(new_session il-append)
    before=$(d2099_state_bytes "$sid")
    err=$(BARREL="$BARREL_N" SID="$sid" run_with_timeout node -e '
const b = require(process.env.BARREL);
try {
  b.appendEvents(process.env.SID, [{
    kind: "complexity_evaluation",
    provenance: "observed",
    origin: "test",
    at: new Date().toISOString(),
    level: "high",
    signals: [],
    levels: { detail: "low", write_tests: "low", write_code: "medium" },
  }]);
  console.log("NO_THROW");
} catch (e) { console.log(e.name); }
' 2>&1)
    assert_eq "IL-7 appendEvents refuses a levels map with an out-of-vocabulary stage value" \
        "InvalidEventError" "$err"
    after_bytes=$(d2099_state_bytes "$sid")
    after_count=$(d2099_raw_ce_count "$sid")
    assert_eq "IL-8 ... and the refusal is atomic: the state file is byte-identical" "$before" "$after_bytes"
    assert_eq "IL-9 ... and no complexity_evaluation event reached the stream" "0" "$after_count"
}

# --- v1 -> v2 migration -----------------------------------------------------
# The migration builds its complexity_evaluation event directly, without
# validateEvent, so it is the only producer that could put a malformed map on a
# v2 stream. IL-10..IL-14 pin what it actually emits.

d2099il_write_v1() {
    local sid="il-v1-$1-$$-$RANDOM"
    BARREL="$BARREL_N" SID="$sid" CE="$2" run_with_timeout node -e '
const fs = require("fs");
const b = require(process.env.BARREL);
fs.writeFileSync(b.getStatePath(process.env.SID), JSON.stringify({
  version: 1,
  session_id: process.env.SID,
  workflow_type: "WF-CODE",
  current: { steps: {} },
  complexity_evaluation: JSON.parse(process.env.CE),
}, null, 2));
' >/dev/null 2>&1
    echo "$sid"
}

d2099il_migrated_shape() {
    BARREL="$BARREL_N" SID="$1" run_with_timeout node -e '
const b = require(process.env.BARREL);
const s = b.readState(process.env.SID);
const ev = ((s && s.events) || []).filter((e) => e && e.kind === "complexity_evaluation");
if (!ev.length) { console.log("events=0"); }
else { console.log("events=" + ev.length + " level=" + ev[0].level + " levels=" + JSON.stringify(ev[0].levels)); }
' 2>&1
}

# IL-10: every migrated evaluation carries a WELL-FORMED levels map or no map at
# all — the shape validateEvent would have demanded, arrived at without it.
d2099il_migration_emits_only_wellformed_levels() {
    local out="" label sid ce
    for label in opus sonnet unknown low; do
        case "$label" in
            opus) ce='{"verdict":"opus","signals":[],"recorded_at":"2026-01-01T00:00:00.000Z"}' ;;
            sonnet) ce='{"verdict":"sonnet","signals":["S1-multi-file"],"recorded_at":"2026-01-01T00:00:00.000Z"}' ;;
            unknown) ce='{"verdict":"haiku","signals":[],"recorded_at":"2026-01-01T00:00:00.000Z"}' ;;
            low) ce='{"level":"low","signals":["S1-multi-file"],"recorded_at":"2026-01-01T00:00:00.000Z"}' ;;
        esac
        sid=$(d2099il_write_v1 "$label" "$ce")
        out="$out$label -> $(d2099il_migrated_shape "$sid")"$'\n'
    done
    assert_block "IL-10 migration emits a well-formed levels map, or no event at all for an unmappable verdict" \
        "$(printf '%s' "$out")" <<'EOF'
opus -> events=1 level=high levels={"detail":"high","write_tests":"high","write_code":"high"}
sonnet -> events=1 level=low levels={"detail":"low","write_tests":"low","write_code":"high"}
unknown -> events=0
low -> events=1 level=low levels={"detail":"low","write_tests":"low","write_code":"high"}
EOF
}

# IL-11: the unmappable-verdict row of IL-10 seen from the consumer end — an
# omitted event must read as NONE, not as some default level.
d2099il_migration_unmappable_reads_none() {
    local sid got
    sid=$(d2099il_write_v1 none '{"verdict":"haiku","signals":[],"recorded_at":"2026-01-01T00:00:00.000Z"}')
    got=$(run_with_timeout node "$BIN_READ" --session "$sid" --stage write_code 2>/dev/null)
    assert_eq "IL-11 an unmappable legacy verdict reads back as NONE, not a defaulted level" "NONE" "$got"

    sid=$(d2099il_write_v1 ok '{"verdict":"opus","signals":[],"recorded_at":"2026-01-01T00:00:00.000Z"}')
    got=$(run_with_timeout node "$BIN_READ" --session "$sid" --stage write_code 2>/dev/null | head -1)
    assert_eq "IL-12 ... while a mappable one does answer, so IL-11 is not measuring a dead reader" \
        "level=high" "$got"
}

# IL-13: a v1 file whose AGGREGATE level is itself out of vocabulary. Unlike
# `levels.<stage>`, `event.level` carries no vocabulary check, so the value
# survives migration verbatim; the containment is downstream, in
# hasComplexityEvaluation(). Pinned as CURRENT behaviour — see the suite report:
# the per-stage map this input produces is all-low, i.e. it fails LOW.
d2099il_migration_out_of_vocabulary_aggregate() {
    local sid got
    sid=$(d2099il_write_v1 medium '{"level":"medium","signals":[],"recorded_at":"2026-01-01T00:00:00.000Z"}')
    assert_eq "IL-13 an out-of-vocabulary aggregate level survives migration verbatim (no level vocabulary check)" \
        'events=1 level=medium levels={"detail":"low","write_tests":"low","write_code":"low"}' \
        "$(d2099il_migrated_shape "$sid")"
    got=$(RESOLVER="$RESOLVER_N" SID="$sid" run_with_timeout node -e '
const r = require(process.env.RESOLVER);
console.log(String(r.hasComplexityEvaluation(process.env.SID)));
' 2>&1)
    assert_eq "IL-14 ... and hasComplexityEvaluation() is the containment: it refuses that record" \
        "false" "$got"
}

d2099il_projection_strips_malformed_levels
d2099il_stage_read_is_rederived
d2099il_aggregate_read_completes_levels
d2099il_append_is_refused_atomically
d2099il_migration_emits_only_wellformed_levels
d2099il_migration_unmappable_reads_none
d2099il_migration_out_of_vocabulary_aggregate
