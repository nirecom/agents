#!/bin/bash
# tests/feature-2099-complexity-stage-routing/writer-api-arg-cases.sh
# Tests: hooks/workflow-state/state-io/session-fields.js, hooks/workflow-state/complexity-routing.js
# Tags: complexity, routing, writer-api, error-handling, edge-cases, scope:issue-specific
# Sourced by ../feature-2099-complexity-stage-routing.sh — helpers come from there.
# R-16 pins the ARITY change only. The signals-only contract moved level
# derivation inside the writer, so the second argument's VALUE now decides a
# routing outcome — and detail.md D1 step 3 names exactly ONE outcome for a
# non-array: the stage's undecidable_level, a recorded fail-high (the only throw
# the design specifies is the 3-arg legacy form, which R-16 owns).

d2099w_probe() {
    local case_id="$1" sid="$2"
    BARREL="$BARREL_N" CR="$CR_MOD_N" SID="$sid" CASE="$case_id" run_with_timeout node -e '
const b = require(process.env.BARREL);
const m = require(process.env.CR);
const sid = process.env.SID;
const wrapped = { signals: ["S3-security"] };
const arrayLike = { 0: "S3-security", length: 1 };
const CASES = {
  "omitted":     function () { return b.recordComplexityEvaluation(sid); },
  "undefined":   function () { return b.recordComplexityEvaluation(sid, undefined); },
  "null":        function () { return b.recordComplexityEvaluation(sid, null); },
  "string-id":   function () { return b.recordComplexityEvaluation(sid, "S3-security"); },
  "string-csv":  function () { return b.recordComplexityEvaluation(sid, "S3-security,S2-architecture"); },
  "string-empty":function () { return b.recordComplexityEvaluation(sid, ""); },
  "object":      function () { return b.recordComplexityEvaluation(sid, wrapped); },
  "array-like":  function () { return b.recordComplexityEvaluation(sid, arrayLike); },
  "number":      function () { return b.recordComplexityEvaluation(sid, 3); },
  "boolean":     function () { return b.recordComplexityEvaluation(sid, true); },
  "valid-empty": function () { return b.recordComplexityEvaluation(sid, []); },
  "valid-one":   function () { return b.recordComplexityEvaluation(sid, ["S3-security"]); },
};
let threw = null;
try { CASES[process.env.CASE](); }
catch (e) { threw = String((e && e.name) || "Error"); }

const ev = (((b.readState(sid) || {}).events) || [])
  .filter(function (e) { return e && e.kind === "complexity_evaluation"; });
if (threw) { console.log("REJECTED n=" + ev.length + " err=" + threw); process.exit(0); }
if (!ev.length) { console.log("SILENT n=0"); process.exit(0); }

const e = ev[ev.length - 1];
const known = (m.SIGNAL_IDS || []).concat([m.UNDECIDABLE_SIGNAL]);
const isArr = Array.isArray(e.signals);
// An "alien" element is one the writer invented out of the malformed value — a
// character of the string, a wrapper key, an index. Fail-high may normalize the
// list, but it must never fabricate signal ids nobody passed.
const alien = isArr ? e.signals.filter(function (s) { return known.indexOf(s) === -1; }).length : -1;
console.log("RECORDED n=" + ev.length
  + " level=" + String(e.level)
  + " levels=" + (e.levels ? [e.levels.detail, e.levels.write_tests, e.levels.write_code].join("/") : String(e.levels))
  + " signals_is_array=" + isArr
  + " alien=" + alien);
' 2>/dev/null
}

D2099W_FAILHIGH='RECORDED n=1 level=high levels=high/high/high signals_is_array=true alien=0'

# WA-1: controls. The writer must actually record, and must record DIFFERENT
# levels for different valid inputs — otherwise every fail-high verdict below
# would be satisfied by a writer that answers high to everything.
d2099w_controls() {
    local sid
    sid=$(new_session waok0)
    assert_eq "WA-1 control: a valid empty signal list records level=low across all three stages" \
        "RECORDED n=1 level=low levels=low/low/low signals_is_array=true alien=0" \
        "$(d2099w_probe valid-empty "$sid")"
    sid=$(new_session waok1)
    assert_eq "WA-1a control: a valid one-signal list records the D2 per-stage split, not a blanket high" \
        "RECORDED n=1 level=high levels=low/high/high signals_is_array=true alien=0" \
        "$(d2099w_probe valid-one "$sid")"
}

# WA-2: the malformed corpus, pinned to the ONE documented outcome. A throw here
# would be a contract change, not an equally-good answer: the fail-high record is
# what keeps the consumers on a level at all, so a writer that starts refusing
# leaves every stage on the NONE path with no record to read.
d2099w_malformed() {
    local case_id sid before after got
    for case_id in omitted undefined null string-id string-csv string-empty object array-like number boolean; do
        sid=$(new_session "wa-$case_id")
        # new_session materializes the file through writeState (round-9 C3). The
        # previous "materialize" line called the READ CLI, which by contract never
        # writes (detail.md D4) — so `before` was NO_FILE and WA-2b could only ever
        # report the missing-file branch, never the growth it names.
        before=$(d2099_state_bytes "$sid")
        got=$(d2099w_probe "$case_id" "$sid")
        after=$(d2099_state_bytes "$sid")

        assert_eq "WA-2 [$case_id] a non-array signals argument records the D1-step-3 fail-high, and nothing else" \
            "$D2099W_FAILHIGH" "$got"
        assert_eq "WA-2a [$case_id] ... exactly one complexity event, with no skip annotation beside it" \
            "ce=1 skip=0" "$(d2099_side_effects "$sid")"
        # The record is an APPEND, so the file must grow. Equal bytes would mean
        # the probe read a record the writer never actually persisted.
        if [ "$before" = "NO_FILE" ] || [ "$after" = "NO_FILE" ]; then
            fail "WA-2b [$case_id] the session state file is missing around the call (before=[$before] after=[$after])"
        elif [ "$after" -gt "$before" ]; then
            pass "WA-2b [$case_id] ... persisted as a real append (state file grew $before -> $after bytes)"
        else
            fail "WA-2b [$case_id] the fail-high event was never persisted: state file did not grow ($before -> $after)"
        fi
    done
}

# WA-3: the malformed call must not poison the session. Its fail-high event stands
# (the log is append-only), so the next well-formed call is the SECOND event and
# the folded record is its own — an implementation that half-writes, coalesces, or
# leaves the session unwritable fails on the exact count.
d2099w_recovery_after_refusal() {
    local case_id sid
    for case_id in null string-id object; do
        sid=$(new_session "warec-$case_id")
        d2099w_probe "$case_id" "$sid" >/dev/null
        assert_eq "WA-3 [$case_id] the fail-high record stands and the next valid call appends cleanly after it" \
            "RECORDED n=2 level=high levels=low/high/high signals_is_array=true alien=0" \
            "$(d2099w_probe valid-one "$sid")"
    done
}

d2099w_controls
d2099w_malformed
d2099w_recovery_after_refusal
