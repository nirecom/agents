#!/bin/bash
# tests/feature-2099-complexity-stage-routing/derivation-cases.sh
# Tests: hooks/workflow-state/complexity-routing.js
# Tags: complexity, routing, derivation, table-driven, scope:issue-specific
# Sourced by ../feature-2099-complexity-stage-routing.sh — helpers come from there.
# Pins the D2 routing table (detail.md) as a table-driven matrix so a silent
# threshold edit shows up as a diff, not as a behaviour change.

# D-1: every export named in detail.md D1 must exist with the right typeof.
d2099_exports() {
    local got
    got=$(run_node '
const m = require(process.env.CR_MOD_N);
const EXPECTED = [
  ["ROUTING_STAGES", "object"], ["SIGNAL_IDS", "object"],
  ["UNDECIDABLE_SIGNAL", "string"], ["STAGE_ROUTING", "object"],
  ["ROUTING_TABLE_VALID", "boolean"], ["ROUTING_TABLE_ERRORS", "object"],
  ["RoutingTableUnavailableError", "function"], ["validateRoutingTable", "function"],
  ["deriveStageLevel", "function"], ["deriveStageLevels", "function"],
  ["deriveAggregateLevel", "function"], ["deriveLegacyStageLevels", "function"],
  ["isZeroSignalLow", "function"], ["describeStageRouting", "function"],
  ["renderStageRoutingMarkdown", "function"], ["renderSignalIdsMarkdown", "function"],
];
const missing = EXPECTED.filter(function (e) { return typeof m[e[0]] !== e[1]; })
  .map(function (e) { return e[0] + ":" + typeof m[e[0]]; });
console.log(missing.length ? missing.join(",") : "ALL_PRESENT");
')
    assert_eq "D-1 complexity-routing exports the full D1 surface" "ALL_PRESENT" "$got"

    got=$(run_node '
const m = require(process.env.CR_MOD_N);
console.log([m.ROUTING_STAGES.join("|"), m.UNDECIDABLE_SIGNAL, m.SIGNAL_IDS.join("|")].join(" "));
')
    assert_eq "D-2 stage keys, undecidable token and signal ids are the SSOT values" \
        "detail|write_tests|write_code S0-undecidable S1-multi-file|S1b-wide-change|S2-architecture|S3-security|S4-installer|S5-breaking|S6-long-plan" \
        "$got"

    got=$(run_node '
const m = require(process.env.CR_MOD_N);
console.log(String(m.ROUTING_TABLE_VALID) + " " + m.ROUTING_TABLE_ERRORS.length);
')
    assert_eq "D-3 the shipped STAGE_ROUTING self-validates clean at load time" "true 0" "$got"
}

# D-4: full deriveStageLevel matrix (3 stages x 13 signal sets).
d2099_matrix() {
    local got
    got=$(run_node '
const m = require(process.env.CR_MOD_N);
const CASES = [
  ["EMPTY", []],
  ["S1-multi-file", ["S1-multi-file"]],
  ["S1b-wide-change", ["S1b-wide-change"]],
  ["S2-architecture", ["S2-architecture"]],
  ["S3-security", ["S3-security"]],
  ["S4-installer", ["S4-installer"]],
  ["S5-breaking", ["S5-breaking"]],
  ["S6-long-plan", ["S6-long-plan"]],
  ["S1b+S6", ["S1b-wide-change", "S6-long-plan"]],
  ["S1+S6", ["S1-multi-file", "S6-long-plan"]],
  ["UNDECIDABLE", ["S0-undecidable"]],
  ["BOGUS", ["S9-not-a-signal"]],
  ["NOT-ARRAY", null],
  // The signals read contract accepts an ARRAY whose ELEMENTS are of any type
  // (skip-signal-resolver.js only checks Array.isArray, and events.js only
  // checks the same) — so a persisted record can legitimately carry non-string
  // elements. D1 step 4 stringifies (`String(s).trim()`) rather than rejecting,
  // so each of these becomes a token outside SIGNAL_IDS and falls to
  // `undecidable_level` (= high) deterministically, without throwing.
  ["NUM-ELEMENT", [1]],
  ["NULL-ELEMENT", [null]],
  ["OBJ-ELEMENT", [{}]],
  ["MIXED-ELEMENTS", ["S3-security", 1, null]],
];
for (const stage of ["detail", "write_tests", "write_code"]) {
  for (const c of CASES) {
    let out;
    try { out = m.deriveStageLevel(stage, c[1]); }
    catch (e) { out = "THREW:" + (e && e.name); }
    console.log(stage + " " + c[0] + " " + out);
  }
}
')
    assert_block "D-4 deriveStageLevel matrix matches the D2 routing table" "$got" <<'EOF'
detail EMPTY low
detail S1-multi-file low
detail S1b-wide-change low
detail S2-architecture high
detail S3-security low
detail S4-installer low
detail S5-breaking high
detail S6-long-plan low
detail S1b+S6 high
detail S1+S6 low
detail UNDECIDABLE high
detail BOGUS high
detail NOT-ARRAY high
detail NUM-ELEMENT high
detail NULL-ELEMENT high
detail OBJ-ELEMENT high
detail MIXED-ELEMENTS high
write_tests EMPTY low
write_tests S1-multi-file low
write_tests S1b-wide-change high
write_tests S2-architecture high
write_tests S3-security high
write_tests S4-installer high
write_tests S5-breaking high
write_tests S6-long-plan low
write_tests S1b+S6 high
write_tests S1+S6 low
write_tests UNDECIDABLE high
write_tests BOGUS high
write_tests NOT-ARRAY high
write_tests NUM-ELEMENT high
write_tests NULL-ELEMENT high
write_tests OBJ-ELEMENT high
write_tests MIXED-ELEMENTS high
write_code EMPTY low
write_code S1-multi-file high
write_code S1b-wide-change high
write_code S2-architecture high
write_code S3-security high
write_code S4-installer high
write_code S5-breaking high
write_code S6-long-plan high
write_code S1b+S6 high
write_code S1+S6 high
write_code UNDECIDABLE high
write_code BOGUS high
write_code NOT-ARRAY high
write_code NUM-ELEMENT high
write_code NULL-ELEMENT high
write_code OBJ-ELEMENT high
write_code MIXED-ELEMENTS high
EOF
}

# D-5: write_code must stay bit-equivalent to the legacy aggregate rule across
# the whole SIGNAL_IDS powerset (128 subsets). This is the regression that
# guards "write_code reduction = zero" from detail.md D2.
d2099_equivalence() {
    local got
    got=$(run_node '
const m = require(process.env.CR_MOD_N);
const ids = m.SIGNAL_IDS.slice();
const mismatches = [];
let aggHigh = 0;
for (let mask = 0; mask < (1 << ids.length); mask++) {
  const sig = ids.filter(function (_, i) { return mask & (1 << i); });
  const agg = m.deriveAggregateLevel(sig);
  const wc = m.deriveStageLevel("write_code", sig);
  if (agg !== wc) mismatches.push(mask + ":" + agg + "/" + wc);
  if (agg === "high") aggHigh++;
}
console.log("subsets=" + (1 << ids.length) + " aggHigh=" + aggHigh + " mismatches=" + mismatches.length);
')
    assert_eq "D-5 deriveStageLevel(write_code) === deriveAggregateLevel over the signal powerset" \
        "subsets=128 aggHigh=127 mismatches=0" "$got"

    got=$(run_node '
const m = require(process.env.CR_MOD_N);
console.log([
  m.deriveAggregateLevel([]),
  m.deriveAggregateLevel(["S1-multi-file"]),
  m.deriveAggregateLevel(null),
].join(" "));
')
    assert_eq "D-6 deriveAggregateLevel keeps the legacy 0-signal/1+-signal/undecidable rule" \
        "low high high" "$got"

    # The aggregate `level` must be derived independently of the write_code
    # column so a future write_code narrowing cannot silently move CI-C1c.
    got=$(run_node '
const src = require("fs").readFileSync(process.env.CR_MOD_N, "utf8");
const fn = src.slice(src.indexOf("function deriveAggregateLevel"));
const body = fn.slice(0, fn.indexOf("\nfunction "));
console.log(/write_code/.test(body) ? "COUPLED" : "INDEPENDENT");
')
    assert_eq "D-7 deriveAggregateLevel does not delegate to the write_code column" \
        "INDEPENDENT" "$got"
}

# D-8: deriveStageLevels / determinism / input non-destruction / bad stage.
d2099_bulk_and_purity() {
    local got
    got=$(run_node '
const m = require(process.env.CR_MOD_N);
const sig = ["S2-architecture", "S6-long-plan"];
const before = JSON.stringify(sig);
const a = m.deriveStageLevels(sig);
const b = m.deriveStageLevels(sig);
const perStage = m.ROUTING_STAGES.map(function (s) { return m.deriveStageLevel(s, sig); }).join(",");
console.log([
  Object.keys(a).join("|"),
  a.detail + "," + a.write_tests + "," + a.write_code,
  perStage,
  JSON.stringify(a) === JSON.stringify(b) ? "DETERMINISTIC" : "NONDETERMINISTIC",
  Object.isFrozen(a) ? "FROZEN" : "MUTABLE",
  JSON.stringify(sig) === before ? "INPUT_INTACT" : "INPUT_MUTATED",
].join(" "));
')
    assert_eq "D-8 deriveStageLevels agrees with per-stage derivation, is frozen, pure and deterministic" \
        "detail|write_tests|write_code high,high,high high,high,high DETERMINISTIC FROZEN INPUT_INTACT" "$got"

    got=$(run_node '
const m = require(process.env.CR_MOD_N);
const out = [];
for (const bad of ["code", "", null, "DETAIL"]) {
  try { m.deriveStageLevel(bad, []); out.push("NO_THROW"); }
  catch (e) { out.push(e && e.name); }
}
console.log(out.join(" "));
')
    assert_eq "D-9 an unknown stage is a programming error (TypeError), not a fail-open" \
        "TypeError TypeError TypeError TypeError" "$got"

    got=$(run_node '
const m = require(process.env.CR_MOD_N);
console.log([
  m.deriveStageLevel("detail", ["  S2-architecture  ", ""]),
  m.deriveStageLevel("write_tests", ["", "  "]),
].join(" "));
')
    assert_eq "D-10 tokens are trimmed and empty tokens dropped before matching" "high low" "$got"
}

# D-11: isZeroSignalLow owns the truth table that resolveSkipConditionsFromComplexity
# used to inline — semantics must be unchanged (level=low AND signals=[]).
d2099_zero_signal_low() {
    local got
    got=$(run_node '
const m = require(process.env.CR_MOD_N);
const CASES = [
  ["low+empty", { level: "low", signals: [] }],
  ["low+one", { level: "low", signals: ["S1-multi-file"] }],
  ["high+empty", { level: "high", signals: [] }],
  ["high+one", { level: "high", signals: ["S3-security"] }],
  ["low+nonarray", { level: "low", signals: "none" }],
  ["low+missing", { level: "low" }],
  ["null", null],
  ["undefined", undefined],
  ["notobject", "low"],
];
console.log(CASES.map(function (c) {
  let v;
  try { v = String(m.isZeroSignalLow(c[1])); } catch (e) { v = "THREW"; }
  return c[0] + "=" + v;
}).join(" "));
')
    assert_block "D-11 isZeroSignalLow truth table" "$got" <<'EOF'
low+empty=true low+one=false high+empty=false high+one=false low+nonarray=false low+missing=false null=false undefined=false notobject=false
EOF
}

# D-12: deriveLegacyStageLevels covers the L1/L2 rows of the Legacy table.
d2099_legacy_derivation() {
    local got
    got=$(run_node '
const m = require(process.env.CR_MOD_N);
function fmt(l) { return l ? l.detail + "," + l.write_tests + "," + l.write_code : String(l); }
const CASES = [
  ["L1-high-signals", "high", ["S1-multi-file"]],
  ["L1-low-signals", "low", ["S6-long-plan"]],
  ["L2-high-empty", "high", []],
  ["L2-low-empty", "low", []],
];
console.log(CASES.map(function (c) {
  return c[0] + "=" + fmt(m.deriveLegacyStageLevels(c[1], c[2]));
}).join(" "));
')
    assert_block "D-12 deriveLegacyStageLevels applies L1 per-signal derivation and L2 high round-up" "$got" <<'EOF'
L1-high-signals=low,low,high L1-low-signals=low,low,high L2-high-empty=high,high,high L2-low-empty=low,low,low
EOF
}

d2099_exports
d2099_matrix
d2099_equivalence
d2099_bulk_and_purity
d2099_zero_signal_low
d2099_legacy_derivation
