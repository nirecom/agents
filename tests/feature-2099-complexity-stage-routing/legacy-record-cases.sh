#!/bin/bash
# tests/feature-2099-complexity-stage-routing/legacy-record-cases.sh
# Tests: hooks/workflow-state/skip-signal-resolver.js, hooks/workflow-state/complexity-routing.js, hooks/workflow-state/state-io/migrations/v1-to-v2.js
# Tags: complexity, routing, legacy, backward-compatibility, migration, scope:issue-specific
# Sourced by ../feature-2099-complexity-stage-routing.sh — helpers come from there.
# One row per line of detail.md's "Legacy compatibility" table. No migration
# script ships, so every row must be absorbed on the READ side.

# L-1..L-4: the legacy shapes, read through the consumer-facing API.
d2099_legacy_shapes() {
    local got
    got=$(run_node '
const fs = require("fs");
const path = require("path");
const b = require(process.env.BARREL_N);

// Two seeders, because the two legacy families live in different places.
//
// `complexity_evaluation` is a PROJECTION key (#1733): createInitialState()
// writes no file at all, and a hand-set top-level field is overwritten by the
// fold on every read. The previous seeder did exactly that and produced null
// for EVERY row. So level/levels/signals shapes are injected as raw events
// (seq must be contiguous or assertStreamIntegrity() rejects the file), and
// `verdict` shapes — which the v3 stream has no vocabulary for — are seeded as
// v1 state files so migrations/v1-to-v2.js performs the real verdict shim.
function seedEvent(tag, ce) {
  const sid = "s2099-lg-" + process.pid + "-" + tag;
  const s = b.createInitialState(sid);
  s.events = (s.events || []).concat([Object.assign({
    kind: "complexity_evaluation", provenance: "observed", origin: "test-legacy",
  }, ce)]);
  s.events.forEach(function (e, i) { e.seq = i + 1; });
  const p = b.getStatePath(sid);
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, JSON.stringify(s, null, 2));
  return sid;
}
function seedV1(tag, ce) {
  const sid = "s2099-lgv1-" + process.pid + "-" + tag;
  const p = b.getStatePath(sid);
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, JSON.stringify({
    version: 1,
    session_id: sid,
    created_at: "2026-06-20T09:00:00.000Z",
    steps: { workflow_init: { status: "complete", updated_at: "2026-06-20T09:01:00.000Z" } },
    complexity_evaluation: ce,
  }, null, 2));
  return sid;
}
function fmt(tag, sid) {
  const ce = b.readComplexityEvaluation(sid);
  if (!ce) return tag + "=null";
  const l = ce.levels;
  return tag + "=" + ce.level + ":" + (l ? [l.detail, l.write_tests, l.write_code].join("/") : String(l));
}
const AT = "2026-06-20T09:02:00.000Z";
// [tag, record, seeder]
const ROWS = [
  ["L1-arch", { level: "high", signals: ["S2-architecture"], recorded_at: AT }, seedEvent],
  ["L1-multifile", { level: "high", signals: ["S1-multi-file"], recorded_at: AT }, seedEvent],
  ["L2-high-empty", { level: "high", signals: [], recorded_at: AT }, seedEvent],
  ["L2-low-empty", { level: "low", signals: [], recorded_at: AT }, seedEvent],
  ["L3-opus", { verdict: "opus", signals: ["S1-multi-file"], recorded_at: AT }, seedV1],
  ["L3-sonnet", { verdict: "sonnet", signals: [], recorded_at: AT }, seedV1],
  ["L3-unknown", { verdict: "gpt", signals: [], recorded_at: AT }, seedV1],
  ["BAD-partial", { level: "high", signals: ["S1-multi-file"], levels: { detail: "low" }, recorded_at: AT }, seedEvent],
  ["BAD-value", { level: "high", signals: ["S1-multi-file"], levels: { detail: "low", write_tests: "yes", write_code: "high" }, recorded_at: AT }, seedEvent],
  ["STORED-wins", { level: "low", signals: [], levels: { detail: "high", write_tests: "high", write_code: "high" }, recorded_at: AT }, seedEvent],
  // A persisted record whose signals array holds NON-STRING elements. The read
  // contract accepts any array, so this must not throw: every non-string
  // stringifies to a token outside SIGNAL_IDS and falls to undecidable-high,
  // deterministically — including the row where a REAL signal sits beside junk.
  ["C9-mixed", { level: "high", signals: ["S3-security", 1, null], recorded_at: AT }, seedEvent],
  ["C9-nonstring-only", { level: "low", signals: [1, {}], recorded_at: AT }, seedEvent],
];
const out = [];
let projected = 0;
for (const r of ROWS) {
  const sid = r[2](r[0].replace(/[^A-Za-z0-9]/g, ""), r[1]);
  const st = b.readState(sid);
  if (st && st.complexity_evaluation) { projected += 1; }
  out.push(fmt(r[0], sid));
}
// Pre-assertion: the seeds must actually reach the projection. Every row but
// L3-unknown (an unmappable verdict) folds to a record; if the seeding were
// silently dropped this would read 0 and the table below would be vacuous.
out.unshift("projected=" + projected + "/" + ROWS.length);
console.log(out.join("\n"));
')
    assert_block "L-1 every legacy complexity_evaluation shape resolves per the compatibility table" "$got" <<'EOF'
projected=11/12
L1-arch=high:high/high/high
L1-multifile=high:low/low/high
L2-high-empty=high:high/high/high
L2-low-empty=low:low/low/low
L3-opus=high:low/low/high
L3-sonnet=low:low/low/low
L3-unknown=null
BAD-partial=high:low/low/high
BAD-value=high:low/low/high
STORED-wins=low:high/high/high
C9-mixed=high:high/high/high
C9-nonstring-only=low:high/high/high
EOF
}

# L-5: readStageComplexityLevel is the consumer entry point — it must see the
# same backfilled values, and reject an unknown stage.
d2099_legacy_stage_reader() {
    local got
    got=$(run_node '
const fs = require("fs");
const path = require("path");
const b = require(process.env.BARREL_N);
const sid = "s2099-lgstage-" + process.pid;
// Raw-event seed, not a hand-set projection key — see the note in
// d2099_legacy_shapes for why the latter persists nothing.
const s = b.createInitialState(sid);
s.events = (s.events || []).concat([{
  kind: "complexity_evaluation", provenance: "observed", origin: "test-legacy",
  level: "high", signals: ["S1-multi-file"], recorded_at: "2026-06-20T09:02:00.000Z",
}]);
s.events.forEach(function (e, i) { e.seq = i + 1; });
const p = b.getStatePath(sid);
fs.mkdirSync(path.dirname(p), { recursive: true });
fs.writeFileSync(p, JSON.stringify(s, null, 2));
const seeded = b.readState(sid);
const out = ["seeded=" + (seeded && seeded.complexity_evaluation ? "yes" : "no")];
b.ROUTING_STAGES.forEach(function (st) { out.push(st + "=" + b.readStageComplexityLevel(sid, st)); });
let bad;
try { bad = "stage=" + b.readStageComplexityLevel(sid, "docs"); }
catch (e) { bad = "stage=" + (e && e.name); }
out.push(bad);
out.push("missing=" + b.readStageComplexityLevel("s2099-absent-" + process.pid, "detail"));
console.log(out.join(" "));
')
    assert_eq "L-5 readStageComplexityLevel backfills legacy records and rejects an unknown stage" \
        "seeded=yes detail=low write_tests=low write_code=high stage=TypeError missing=null" "$got"
}

# L-6 (row L4): a v1 state file must come out of migration with levels attached
# to the backfilled complexity_evaluation event.
#
# readState() is READ-ONLY by contract (state-io/core.js): it normalizes a v1 file
# IN MEMORY and never writes back — persistMigratedState() is the writer that does.
# So the migrated event is asserted on readState's OWN return value, and the raw
# file only AFTER that writer runs. Reading the raw file straight after readState
# measured an untouched v1 file with no `events` key at all (round-9 C2).
d2099_v1_migration() {
    local got want_levels
    got=$(run_node '
const fs = require("fs");
const b = require(process.env.BARREL_N);
const sid = "s2099-v1-" + process.pid;
const p = b.getStatePath(sid);
fs.mkdirSync(require("path").dirname(p), { recursive: true });
fs.writeFileSync(p, JSON.stringify({
  version: 1,
  session_id: sid,
  created_at: "2026-06-20T09:00:00.000Z",
  steps: { workflow_init: { status: "complete", updated_at: "2026-06-20T09:01:00.000Z" } },
  complexity_evaluation: {
    level: "high",
    signals: ["S1-multi-file", "S2-architecture"],
    recorded_at: "2026-06-20T09:02:00.000Z",
  },
}, null, 2));
const ceEvents = function (s) {
  return ((s && s.events) || []).filter(function (e) { return e && e.kind === "complexity_evaluation"; });
};
const st = b.readState(sid);
// Read the projection defensively: while the backfill is unimplemented `levels`
// is absent, and a bare ce.levels.detail would report a TypeError stack instead
// of the want/got diff that names the missing key.
const ce = (st && st.complexity_evaluation) || {};
const cl = ce.levels || {};
const mem = ceEvents(st);
// raw_before is pinned, not incidental: it is why the raw half needs its own call.
const rawBefore = ceEvents(b.readRawState(sid));
const persisted = b.persistMigratedState(sid);
const rawAfter = ceEvents(b.readRawState(sid));
console.log([
  "level=" + ce.level,
  "levels=" + [cl.detail, cl.write_tests, cl.write_code].join("/"),
  "mem_events=" + mem.length,
  "mem_levels=" + (mem.length ? JSON.stringify(mem[0].levels) : "none"),
  "raw_before=" + rawBefore.length,
  "persisted=" + persisted,
  "raw_events=" + rawAfter.length,
  "raw_levels=" + (rawAfter.length ? JSON.stringify(rawAfter[0].levels) : "none"),
].join(" "));
')
    want_levels="{\"detail\":\"high\",\"write_tests\":\"high\",\"write_code\":\"high\"}"
    assert_eq "L-6 v1-to-v2 backfills the complexity event with derived levels, in memory and once a writer persists it" \
        "level=high levels=high/high/high mem_events=1 mem_levels=$want_levels raw_before=0 persisted=true raw_events=1 raw_levels=$want_levels" \
        "$got"
}

# L-7: the other half of L-6. detail.md item 6 says the v1 backfill adds
# `levels: deriveLegacyStageLevels(...)` and OMITS it when derivation is
# impossible — migration must still succeed. Run against the corrupted tree
# fail-open-cases.sh builds (sourced earlier), which is the only way to make a
# derivation genuinely unavailable without touching the real repo. Same
# in-memory-then-persist split as L-6 (round-9 C2).
d2099_v1_migration_fail_open() {
    local got
    if [ ! -f "$D2099_ISO/hooks/workflow-state.js" ]; then
        fail "L-7 unattributable: the isolated broken-table tree at $D2099_ISO was never built, so 'derivation unavailable' could not be produced"
        return
    fi
    got=$(ISO_BARREL="$(to_node_path "$D2099_ISO/hooks/workflow-state.js")" run_with_timeout node -e '
const fs = require("fs");
const b = require(process.env.ISO_BARREL);
const sid = "s2099-v1fo-" + process.pid;
const p = b.getStatePath(sid);
fs.mkdirSync(require("path").dirname(p), { recursive: true });
fs.writeFileSync(p, JSON.stringify({
  version: 1,
  session_id: sid,
  created_at: "2026-06-20T09:00:00.000Z",
  steps: { workflow_init: { status: "complete", updated_at: "2026-06-20T09:01:00.000Z" } },
  complexity_evaluation: {
    level: "high",
    signals: ["S1-multi-file", "S2-architecture"],
    recorded_at: "2026-06-20T09:02:00.000Z",
  },
}, null, 2));
let st;
try { st = b.readState(sid); }
catch (e) { console.log("MIGRATION_THREW:" + (e && e.name)); process.exit(0); }
const ce = (st && st.complexity_evaluation) || {};
const ceEvents = function (s) {
  return ((s && s.events) || []).filter(function (e) { return e && e.kind === "complexity_evaluation"; });
};
// The migrated stream lives on the RETURN VALUE of readState; the on-disk file
// is still v1 until persistMigratedState() runs (state-io/core.js).
const mem = ceEvents(st);
// `levels` must be ABSENT, not a fabricated map: an invented per-stage record
// would be indistinguishable from a real one on every later read.
const hasKey = function (list) {
  return list.length ? Object.prototype.hasOwnProperty.call(list[0], "levels") : "no-event";
};
const rawBefore = ceEvents(b.readRawState(sid));
const persisted = b.persistMigratedState(sid);
const rawAfter = ceEvents(b.readRawState(sid));
console.log([
  "migrated=" + (st && st.version >= 2 ? "yes" : "no"),
  "level=" + ce.level,
  "signals=" + JSON.stringify(ce.signals),
  "ce_levels=" + JSON.stringify(ce.levels === undefined ? null : ce.levels),
  "mem_events=" + mem.length,
  "mem_has_levels=" + hasKey(mem),
  "raw_before=" + rawBefore.length,
  "persisted=" + persisted,
  "raw_events=" + rawAfter.length,
  "raw_has_levels=" + hasKey(rawAfter),
].join(" "));
' 2>/dev/null)
    assert_eq "L-7 an underivable v1 record still migrates, keeps level/signals, and omits levels rather than inventing them" \
        "migrated=yes level=high signals=[\"S1-multi-file\",\"S2-architecture\"] ce_levels=null mem_events=1 mem_has_levels=false raw_before=0 persisted=true raw_events=1 raw_has_levels=false" \
        "$got"
}

d2099_legacy_shapes
d2099_legacy_stage_reader
d2099_v1_migration
d2099_v1_migration_fail_open
