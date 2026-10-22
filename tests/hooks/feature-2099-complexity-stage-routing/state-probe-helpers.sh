#!/bin/bash
# tests/hooks/feature-2099-complexity-stage-routing/state-probe-helpers.sh
# Tests: tests/hooks/feature-2099-complexity-stage-routing/_lib.sh
# Tags: complexity, routing, cli, helpers, scope:issue-specific
# Helper-only, no cases of its own. Sourced by _lib.sh for every #2099 group
# entrypoint (#2723 split): the state probes were defined in record-read-cases.sh
# but used by the hardening, traversal and signals-file suites too.

# Inject a raw complexity_evaluation event straight into the session's event
# stream, bypassing recordComplexityEvaluation and its validation. This is the
# only way to prove readLastRawComplexityEvent does NOT backfill (detail.md D6).
d2099_inject_raw_event() {
    BARREL="$BARREL_N" SID="$1" RAW="$2" run_with_timeout node - <<'JS' 2>&1
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
JS
}

# Counts the raw complexity_evaluation events in a session's append-only log.
# The store never rewrites history, so this is the accessor every "was/was not
# persisted" assertion must go through (detail.md D6).
d2099_raw_ce_count() {
    BARREL="$BARREL_N" SID="$1" run_with_timeout node - <<'JS' 2>/dev/null
const b = require(process.env.BARREL);
const s = b.readState(process.env.SID);
const ev = ((s && s.events) || []).filter(function (e) { return e && e.kind === "complexity_evaluation"; });
console.log(String(ev.length));
JS
}

# Byte snapshot of the session state file — the only way to prove an append was
# refused ATOMICALLY rather than written and then complained about.
d2099_state_bytes() {
    BARREL="$BARREL_N" SID="$1" run_with_timeout node - <<'JS' 2>/dev/null
const fs = require("fs");
const b = require(process.env.BARREL);
try { console.log(String(fs.readFileSync(b.getStatePath(process.env.SID)).length)); }
catch (e) { console.log("NO_FILE"); }
JS
}

# Side-effect probe for the malformed-invocation cases: did a rejected CLI call
# leave a complexity_evaluation event or any skip-related annotation behind?
d2099_side_effects() {
    BARREL="$BARREL_N" SID="$1" run_with_timeout node - <<'JS' 2>/dev/null
const b = require(process.env.BARREL);
const s = b.readState(process.env.SID);
const ev = ((s && s.events) || []);
const ce = ev.filter(function (e) { return e && e.kind === "complexity_evaluation"; }).length;
const skip = ev.filter(function (e) {
  return e && e.kind === "step_annotation" && /^skip_/.test(String(e.key));
}).length;
console.log("ce=" + ce + " skip=" + skip);
JS
}

# No-skip probe (#2460 retired the zero-signal auto-skip): a recorded evaluation
# may leave neither skippable step anything but `pending`, and no skip
# annotation may appear.
d2099_no_skip_view() {
    BARREL="$BARREL_N" SID="$1" run_with_timeout node - <<'JS' 2>/dev/null
const b = require(process.env.BARREL);
const s = b.readState(process.env.SID);
const st = function (n) { const x = s && s.steps && s.steps[n]; return x && x.status ? x.status : "NO_STEP"; };
const skip = ((s && s.events) || []).filter(function (e) {
  return e && e.kind === "step_annotation" && /^skip_/.test(String(e.key));
}).length;
console.log("outline=" + st("outline") + " detail=" + st("detail") + " skip=" + skip);
JS
}

# Pre-assertion companion for d2099_inject_raw_event: prints the folded record
# so a case can prove the injection survived before asserting on it.
d2099_projected_ce() {
    BARREL="$BARREL_N" SID="$1" run_with_timeout node - <<'JS' 2>&1
const b = require(process.env.BARREL);
const s = b.readState(process.env.SID);
if (!s) { console.log("__NO_STATE__"); }
else { console.log(JSON.stringify(s.complexity_evaluation)); }
JS
}
