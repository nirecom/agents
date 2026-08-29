#!/bin/bash
# tests/feature-2099-complexity-stage-routing/record-read-cases.sh
# Tests: bin/workflow/record-complexity-evaluation, bin/workflow/read-complexity-evaluation, bin/workflow/derive-complexity-level, hooks/workflow-state/state-io/session-fields.js, hooks/workflow-state/state-io/events.js, hooks/workflow-state/state-io/projection.js
# Tags: complexity, routing, cli, round-trip, read-back, security, scope:issue-specific
# Sourced by ../feature-2099-complexity-stage-routing.sh — helpers come from there.
# Dispatch/core cases only; the read-back and history groups are siblings
# (record-read-readback-cases.sh / record-read-history-cases.sh, Pattern A split).

# Inject a raw complexity_evaluation event straight into the session's event
# stream, bypassing recordComplexityEvaluation and its validation. This is the
# only way to prove readLastRawComplexityEvent does NOT backfill (detail.md D6).
d2099_inject_raw_event() {
    BARREL="$BARREL_N" SID="$1" RAW="$2" run_with_timeout node -e '
const fs = require("fs");
const b = require(process.env.BARREL);
const p = b.getStatePath(process.env.SID);
const s = JSON.parse(fs.readFileSync(p, "utf8"));
s.events = (s.events || []).concat([Object.assign({
  kind: "complexity_evaluation",
  provenance: "observed",
  origin: "test-injection",
  recorded_at: "2026-08-23T00:00:00.000Z",
}, JSON.parse(process.env.RAW))]);
// seq must stay contiguous and 1-based across the WHOLE array or
// assertStreamIntegrity() rejects the file and readState() returns null — which
// would make every assertion below pass against an ABSENT record instead of an
// injected one.
s.events.forEach(function (e, i) { e.seq = i + 1; });
fs.writeFileSync(p, JSON.stringify(s, null, 2));
' 2>&1
}

# Counts the raw complexity_evaluation events in a session's append-only log.
# The store never rewrites history, so this is the accessor every "was/was not
# persisted" assertion must go through (detail.md D6).
d2099_raw_ce_count() {
    BARREL="$BARREL_N" SID="$1" run_with_timeout node -e '
const b = require(process.env.BARREL);
const s = b.readState(process.env.SID);
const ev = ((s && s.events) || []).filter(function (e) { return e && e.kind === "complexity_evaluation"; });
console.log(String(ev.length));
' 2>/dev/null
}

# Byte snapshot of the session state file — the only way to prove an append was
# refused ATOMICALLY rather than written and then complained about.
d2099_state_bytes() {
    BARREL="$BARREL_N" SID="$1" run_with_timeout node -e '
const fs = require("fs");
const b = require(process.env.BARREL);
try { console.log(String(fs.readFileSync(b.getStatePath(process.env.SID)).length)); }
catch (e) { console.log("NO_FILE"); }
' 2>/dev/null
}

# Side-effect probe for the malformed-invocation cases: did a rejected CLI call
# leave a complexity_evaluation event or any skip-related annotation behind?
d2099_side_effects() {
    BARREL="$BARREL_N" SID="$1" run_with_timeout node -e '
const b = require(process.env.BARREL);
const s = b.readState(process.env.SID);
const ev = ((s && s.events) || []);
const ce = ev.filter(function (e) { return e && e.kind === "complexity_evaluation"; }).length;
const skip = ev.filter(function (e) {
  return e && e.kind === "step_annotation" && /^skip_/.test(String(e.key));
}).length;
console.log("ce=" + ce + " skip=" + skip);
' 2>/dev/null
}

# Pre-assertion companion for d2099_inject_raw_event: prints the folded record
# so a case can prove the injection survived before asserting on it.
d2099_projected_ce() {
    BARREL="$BARREL_N" SID="$1" run_with_timeout node -e '
const b = require(process.env.BARREL);
const s = b.readState(process.env.SID);
if (!s) { console.log("__NO_STATE__"); }
else { console.log(JSON.stringify(s.complexity_evaluation)); }
' 2>&1
}

# R-1/R-2: record -> read round trip, and the per-stage divergence that is the
# whole point of #2099: ONE signal set yielding different levels per stage.
d2099_round_trip() {
    local sid out rc
    sid=$(new_session rt)

    out=$(run_with_timeout node "$BIN_RECORD" --session "$sid" --signals "S1-multi-file" 2>&1); rc=$?
    assert_eq "R-1 record-complexity-evaluation accepts signals-only and exits 0" "0" "$rc"
    assert_contains "R-2 record prints the RECORDED_COMPLEXITY receipt" "RECORDED_COMPLEXITY" "$out"
    assert_not_contains "R-3 the receipt no longer speaks of a verdict" "verdict=" "$out"

    local matrix=""
    local st
    for st in detail write_tests write_code; do
        matrix="$matrix$st:$(run_with_timeout node "$BIN_READ" --session "$sid" --stage "$st" 2>/dev/null | tr '\n' ';') "
    done
    assert_eq "R-4 one signal set routes differently per stage (S1-multi-file: low/low/high)" \
        "detail:level=low;signals=S1-multi-file; write_tests:level=low;signals=S1-multi-file; write_code:level=high;signals=S1-multi-file; " \
        "$matrix"

    # Aggregate `level` stays on the legacy rule and is NOT the write_code column
    # by construction (detail.md D3) — here they happen to agree.
    out=$(run_with_timeout node "$BIN_READ" --session "$sid" 2>/dev/null | tr '\n' ';')
    assert_eq "R-5 back-compat mode (no --stage) adds a levels= JSON line" \
        "level=high;signals=S1-multi-file;levels={\"detail\":\"low\",\"write_tests\":\"low\",\"write_code\":\"high\"};" \
        "$out"
}

# R-6: the zero-signal path. `--signals ""` is a VALID input meaning "no
# signals"; omitting the flag entirely is a usage error (detail.md R3-C4).
d2099_zero_signal_and_presence() {
    local sid out rc
    sid=$(new_session zero)

    rc=0; out=$(run_with_timeout node "$BIN_RECORD" --session "$sid" --signals "" 2>&1) || rc=$?
    assert_eq "R-6 --signals \"\" records a zero-signal evaluation (exit 0)" "0" "$rc"

    out=$(run_with_timeout node "$BIN_READ" --session "$sid" --stage write_tests 2>/dev/null | tr '\n' ';')
    assert_eq "R-7 a zero-signal record reads back low with signals=none" "level=low;signals=none;" "$out"

    local sid2
    sid2=$(new_session nosig)
    rc=0; out=$(run_with_timeout node "$BIN_RECORD" --session "$sid2" 2>&1) || rc=$?
    assert_eq "R-8 omitting --signals is a usage error, not a silent zero-signal record" "1" "$rc"
    assert_contains "R-9 the usage error names the empty-string escape hatch" '--signals ""' "$out"

    out=$(run_with_timeout node "$BIN_READ" --session "$sid2" --stage detail 2>/dev/null)
    assert_eq "R-10 the rejected call wrote nothing" "NONE" "$out"

    rc=0; out=$(run_with_timeout node "$BIN_RECORD" --session "$sid2" --verdict high --signals "" 2>&1) || rc=$?
    assert_eq "R-11 --verdict is rejected outright" "1" "$rc"
    assert_contains "R-12 the rejection names --verdict" "verdict" "$out"

    rc=0; out=$(run_with_timeout node "$BIN_DERIVE" --stage write_tests --signals "S1-multi-file" 2>&1) || rc=$?
    assert_eq "R-13 derive-complexity-level is stateless and exits 0" "0" "$rc"
    assert_eq "R-14 derive-complexity-level applies the write_tests column" "level=low" "$out"

    rc=0; out=$(run_with_timeout node "$BIN_DERIVE" --stage write_tests 2>&1) || rc=$?
    assert_eq "R-15 derive-complexity-level also presence-detects --signals" "1" "$rc"
}

# R-35..: the OTHER half of presence detection. R-8/R-15 cover an absent flag;
# these cover a flag present with NO value after it — `--signals` as the last
# token. A parser that reads argv[i+1] blindly gets `undefined` (indistinguish-
# able from absent) or, worse, swallows the next flag as the value. Both must be
# usage errors (detail.md D1 items 8/9/10: exit 1 for the two node CLIs, exit 2
# for the bash wrapper) and neither may leave a record behind.
d2099_trailing_flag_usage() {
    local sid rc out

    # Every case here pairs the exit code with the DIAGNOSTIC. Exit 1 alone is also
    # what node returns for a missing file or a crash, so the code on its own would
    # go green against a CLI that does not exist yet.
    sid=$(new_session trailsig)
    rc=0; out=$(run_with_timeout node "$BIN_RECORD" --session "$sid" --signals 2>&1) || rc=$?
    assert_eq "R-35 record-complexity-evaluation: a trailing --signals is a usage error (exit 1)" "1" "$rc"
    assert_contains "R-35a ... reported as a --signals usage error, not a crash" "--signals" "$out"
    assert_eq "R-36 ... and wrote no complexity_evaluation and no skip annotation" \
        "ce=0 skip=0" "$(d2099_side_effects "$sid")"

    # ...and the next flag is not silently consumed as the value either.
    local sid2
    sid2=$(new_session trailsig2)
    rc=0; out=$(run_with_timeout node "$BIN_RECORD" --signals --session "$sid2" 2>&1) || rc=$?
    assert_eq "R-37 ... nor does --signals swallow the following flag as its value" "1" "$rc"
    assert_contains "R-37a ... and says so about --signals" "--signals" "$out"
    assert_eq "R-38 ... leaving that session untouched too" "ce=0 skip=0" "$(d2099_side_effects "$sid2")"

    rc=0; out=$(run_with_timeout node "$BIN_DERIVE" --stage write_tests --signals 2>&1) || rc=$?
    assert_eq "R-39 derive-complexity-level: a trailing --signals is a usage error (exit 1)" "1" "$rc"
    assert_contains "R-39a ... naming --signals rather than failing to load" "--signals" "$out"

    rc=0; out=$(run_with_timeout node "$BIN_DERIVE" --signals "" --stage 2>&1) || rc=$?
    assert_eq "R-40 derive-complexity-level: a trailing --stage is a usage error (exit 1)" "1" "$rc"
    assert_contains "R-40a ... naming --stage rather than failing to load" "--stage" "$out"

    local sid3
    sid3=$(new_session trailstage)
    run_with_timeout node "$BIN_RECORD" --session "$sid3" --signals "S3-security" >/dev/null 2>&1
    rc=0; out=$(run_with_timeout node "$BIN_READ" --session "$sid3" --stage 2>&1) || rc=$?
    assert_eq "R-41 read-complexity-evaluation: a trailing --stage is a usage error (exit 1)" "1" "$rc"
    assert_contains "R-41a ... naming --stage rather than failing to load" "--stage" "$out"
    # The session DOES hold a record, so a level line here would mean the empty
    # --stage silently degraded into the back-compat mode instead of erroring.
    assert_not_contains "R-42 ... and does not fall through to a level line" "level=" "$out"

    # The bash wrapper owns its own presence detection, with its own exit code.
    local sid4
    sid4=$(new_session trailwrap)
    rc=0; out=$(run_with_timeout bash "$BIN_RECORD_SKIP" --session "$sid4" --target outline --signals 2>&1) || rc=$?
    assert_eq "R-43 record-complexity-and-skip: a trailing --signals is a wrapper usage error (exit 2)" "2" "$rc"
    assert_contains "R-43a ... from the wrapper's own presence check, naming --signals" "--signals" "$out"
    assert_eq "R-44 ... and neither a complexity record nor a skip annotation was written" \
        "ce=0 skip=0" "$(d2099_side_effects "$sid4")"
}

# R-16: the API arity change. The 3-arg legacy call must throw loudly rather
# than being silently reinterpreted as (sessionId, signals).
d2099_api_arity() {
    local got
    got=$(run_node '
const b = require(process.env.BARREL_N);
const sid = "s2099-arity-" + process.pid;
// Materialized, not merely constructed — createInitialState writes no file.
b.writeState(sid, b.createInitialState(sid));
let legacy = "NO_THROW";
try { b.recordComplexityEvaluation(sid, "high", ["S1-multi-file"]); }
catch (e) { legacy = /recordComplexityEvaluation/.test(String(e && e.message)) ? "THREW_NAMED" : "THREW_VAGUE"; }
let modern = "NO_THROW";
try { b.recordComplexityEvaluation(sid, ["S3-security"]); modern = "OK"; }
catch (e) { modern = "THREW:" + (e && e.message); }
const ce = b.readComplexityEvaluation(sid);
console.log([
  legacy,
  modern,
  ce && ce.level,
  ce && ce.levels && [ce.levels.detail, ce.levels.write_tests, ce.levels.write_code].join(","),
  ce && ce.signals.join(","),
  typeof b.readLastRawComplexityEvent,
  typeof b.readStageComplexityLevel,
  b.readStageComplexityLevel(sid, "detail"),
].join(" "));
')
    # S3-security is a DIVERGENT row (detail.md D2): solo_escalation for write_tests
    # and legacy_equivalent for write_code, but absent from detail's escalation
    # sets — so the levels map is low/high/high and readStageComplexityLevel("detail")
    # answers low while the aggregate `level` stays high (deriveAggregateLevel:
    # one signal is enough). A uniform high,high,high here would be a table the
    # routing rows do not produce.
    assert_eq "R-16 recordComplexityEvaluation is signals-only; the 3-arg legacy form throws" \
        "THREW_NAMED OK high low,high,high S3-security function function low" "$got"
}

# R-17: read-back verification must read the RAW persisted event, not the
# legacy-backfilling consumer read (detail.md D6 / R3-C2).
d2099_raw_read_back() {
    local sid got
    sid=$(new_session raw)
    d2099_inject_raw_event "$sid" '{"level":"high","signals":["S2-architecture"]}' >/dev/null

    got=$(BARREL="$BARREL_N" SID="$sid" run_with_timeout node -e '
const b = require(process.env.BARREL);
const sid = process.env.SID;
const raw = b.readLastRawComplexityEvent(sid);
const compat = b.readComplexityEvaluation(sid);
console.log([
  "raw_levels=" + JSON.stringify(raw && raw.levels),
  "raw_level=" + (raw && raw.level),
  "raw_signals=" + (raw && raw.signals.join(",")),
  "compat_levels=" + (compat && compat.levels
    ? [compat.levels.detail, compat.levels.write_tests, compat.levels.write_code].join(",")
    : String(compat && compat.levels)),
].join(" "));
' 2>&1)
    assert_eq "R-17 readLastRawComplexityEvent returns the missing levels as-is while the consumer read backfills" \
        "raw_levels=undefined raw_level=high raw_signals=S2-architecture compat_levels=high,high,high" "$got"

    local sid2
    sid2=$(new_session rawbad)
    d2099_inject_raw_event "$sid2" '{"level":"low","signals":["S6-long-plan"],"levels":{"detail":"maybe"}}' >/dev/null
    got=$(BARREL="$BARREL_N" SID="$sid2" run_with_timeout node -e '
const b = require(process.env.BARREL);
const sid = process.env.SID;
const raw = b.readLastRawComplexityEvent(sid);
const compat = b.readComplexityEvaluation(sid);
const intended = b.deriveStageLevels(raw.signals);
const readBackAgrees = JSON.stringify(raw.levels) === JSON.stringify(intended);
console.log([
  "raw_levels=" + JSON.stringify(raw.levels),
  "compat_levels=" + [compat.levels.detail, compat.levels.write_tests, compat.levels.write_code].join(","),
  "read_back=" + (readBackAgrees ? "PASSES" : "DETECTS_MISMATCH"),
].join(" "));
' 2>&1)
    assert_eq "R-18 a malformed persisted levels is never partially adopted, and read-back comparison catches it" \
        "raw_levels={\"detail\":\"maybe\"} compat_levels=low,low,high read_back=DETECTS_MISMATCH" "$got"
}

# R-19: events.js must reject an out-of-shape `levels` at append time, and the
# projection must fold a valid one. "Rejected" is asserted as THROWN *and* the
# stream byte-identical afterwards: a throw raised after the write already
# landed would satisfy the first half alone while leaving an invalid event in an
# append-only log that has no way to remove it.
d2099_event_and_projection_contract() {
    local got
    got=$(run_node '
const fs = require("fs");
const b = require(process.env.BARREL_N);
const base = { kind: "complexity_evaluation", level: "low", signals: [], provenance: "observed", origin: "test" };
const BAD = [
  ["missing-key", { detail: "low", write_tests: "low" }],
  ["extra-key", { detail: "low", write_tests: "low", write_code: "low", docs: "low" }],
  ["bad-value", { detail: "low", write_tests: "low", write_code: "medium" }],
  ["not-object", ["low", "low", "low"] ],
  ["null-value", null],
];
// createInitialState() is a pure constructor and writes NOTHING (state-io/core.js);
// writeState() is what materializes the file. The byte-identical atomicity check
// below needs a real file to compare against, so the seed must go through the
// writer — the previous version read a path that had never been created (round-9 C3).
const seed = function (sid) { b.writeState(sid, b.createInitialState(sid)); };
const out = [];
for (const c of BAD) {
  const sid = "s2099-ev-" + process.pid + "-" + c[0].replace(/[^a-z]/g, "");
  seed(sid);
  const p = b.getStatePath(sid);
  const before = fs.readFileSync(p);
  let verdict;
  try {
    b.appendEvents(sid, [Object.assign({}, base, { levels: c[1] })]);
    verdict = "ACCEPTED";
  } catch (e) {
    verdict = (e && e.name);
  }
  // Atomicity, measured from outside the module: same bytes, same event count.
  const after = fs.readFileSync(p);
  const grew = JSON.parse(String(after)).events.length - JSON.parse(String(before)).events.length;
  if (!after.equals(before) || grew !== 0) { verdict += "+LEAKED(+" + grew + ")"; }
  out.push(c[0] + "=" + verdict);
}
const okSid = "s2099-ev-ok-" + process.pid;
seed(okSid);
b.appendEvents(okSid, [Object.assign({}, base, {
  signals: ["S3-security"],
  level: "high",
  levels: { detail: "low", write_tests: "high", write_code: "high" },
})]);
// Guarded: until the projection carries `levels`, a bare proj.levels.detail
// reports a TypeError stack instead of the want/got diff naming the missing key.
const proj = b.readState(okSid).complexity_evaluation || {};
const pl = proj.levels;
out.push("projected=" + (pl ? [pl.detail, pl.write_tests, pl.write_code].join(",") : "absent"));
out.push("frozen=" + (pl && Object.isFrozen(pl) ? "yes" : "no"));
console.log(out.join(" "));
')
    assert_eq "R-19 events.js validates levels on append; projection folds a valid one" \
        "missing-key=InvalidEventError extra-key=InvalidEventError bad-value=InvalidEventError not-object=InvalidEventError null-value=InvalidEventError projected=low,high,high frozen=yes" \
        "$got"
}

# R-20: security regressions carried over from the CE-SEC-* family — the
# signals-only contract must not open a new injection surface.
d2099_security() {
    local sid rc out
    sid=$(new_session sec)

    rc=0; out=$(run_with_timeout node "$BIN_RECORD" --session 'bad;id' --signals "" 2>&1) || rc=$?
    assert_eq "R-20 a session id with shell metacharacters is rejected" "1" "$rc"

    rc=0; out=$(run_with_timeout node "$BIN_RECORD" --session "$sid" --signals 'S1-multi-file; rm -rf /' 2>&1) || rc=$?
    assert_eq "R-21 signal tokens are data: a metacharacter payload never executes" "0" "$rc"

    out=$(run_with_timeout node "$BIN_READ" --session "$sid" --stage write_code 2>/dev/null | head -1)
    assert_eq "R-22 an unknown/injected token routes undecidable-high, not silently low" "level=high" "$out"

    rc=0; out=$(run_with_timeout node "$BIN_READ" --session "$sid" --stage bogus_stage 2>&1) || rc=$?
    assert_eq "R-23 read-complexity-evaluation rejects an unknown --stage" "1" "$rc"
}

d2099_round_trip
d2099_zero_signal_and_presence
d2099_trailing_flag_usage
d2099_api_arity
d2099_raw_read_back
d2099_event_and_projection_contract
d2099_security
