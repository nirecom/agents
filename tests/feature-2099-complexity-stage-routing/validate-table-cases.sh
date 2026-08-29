#!/bin/bash
# tests/feature-2099-complexity-stage-routing/validate-table-cases.sh
# Tests: hooks/workflow-state/complexity-routing.js
# Tags: complexity, routing, validation, shape, table-driven, scope:issue-specific
# Sourced by ../feature-2099-complexity-stage-routing.sh — helpers come from there.
# Split out of derivation-cases.sh purely for the >300-line WARN threshold
# (rules/coding/file-split.md Pattern A); detail.md groups both concerns as case file 1.

# V-1: validateRoutingTable is a PURE function over an arbitrary value. Every
# malformed shape from detail.md D1 must come back as {valid:false, errors:[...]}
# WITHOUT throwing — the contract that lets tests break the table without
# breaking the module.
d2099_validate_table() {
    local got
    got=$(run_node '
const m = require(process.env.CR_MOD_N);
const base = JSON.parse(JSON.stringify(m.STAGE_ROUTING));
function mutate(fn) { const t = JSON.parse(JSON.stringify(base)); fn(t); return t; }

const CASES = [
  ["default-arg", undefined, true],
  ["pristine-clone", base, true],
  ["table-array", [], false],
  ["table-string", "detail", false],
  ["table-null", null, false],
  ["table-number", 7, false],
  ["missing-stage", mutate(function (t) { delete t.write_code; }), false],
  ["extra-stage", mutate(function (t) { t.docs = t.detail; }), false],
  ["entry-null", mutate(function (t) { t.detail = null; }), false],
  ["entry-primitive", mutate(function (t) { t.detail = 3; }), false],
  ["entry-array", mutate(function (t) { t.detail = []; }), false],
  ["bad-default-level", mutate(function (t) { t.detail.default_level = "medium"; }), false],
  ["missing-default-level", mutate(function (t) { delete t.detail.default_level; }), false],
  ["missing-undecidable-level", mutate(function (t) { delete t.detail.undecidable_level; }), false],
  ["bad-undecidable-level", mutate(function (t) { t.detail.undecidable_level = "medium"; }), false],
  ["nonstring-default-level", mutate(function (t) { t.detail.default_level = 0; }), false],
  ["solo-not-array", mutate(function (t) { t.detail.solo_escalation = "S2-architecture"; }), false],
  ["solo-empty-ok", mutate(function (t) { t.detail.solo_escalation = []; }), true],
  ["solo-unknown-id", mutate(function (t) { t.detail.solo_escalation = ["S9-nope"]; }), false],
  ["legacy-not-array", mutate(function (t) { t.write_code.legacy_equivalent_escalation = "S1-multi-file"; }), false],
  ["legacy-empty-inner", mutate(function (t) { t.write_code.legacy_equivalent_escalation.push([]); }), false],
  ["legacy-nonarray-inner", mutate(function (t) { t.write_code.legacy_equivalent_escalation.push("S1-multi-file"); }), false],
  ["legacy-unknown-id", mutate(function (t) { t.write_code.legacy_equivalent_escalation.push(["S9-nope"]); }), false],
  ["combo-empty-inner", mutate(function (t) { t.detail.combination_escalation.push([]); }), false],
  ["combo-singleton", mutate(function (t) { t.detail.combination_escalation.push(["S2-architecture"]); }), false],
  ["combo-not-array", mutate(function (t) { t.detail.combination_escalation = ["S2-architecture"]; }), false],
  ["combo-unknown-id", mutate(function (t) { t.detail.combination_escalation.push(["S9-nope", "S6-long-plan"]); }), false],
  // Malformed NESTED element types. A number is not an unknown signal id — it is
  // the wrong type — and the D1 shape table requires every escalation element
  // (nested ones included) to be a member of SIGNAL_IDS, which no number is.
  ["solo-number-element", mutate(function (t) { t.detail.solo_escalation.push(7); }), false],
  ["solo-null-element", mutate(function (t) { t.detail.solo_escalation.push(null); }), false],
  ["legacy-number-element", mutate(function (t) { t.write_code.legacy_equivalent_escalation.push([7]); }), false],
  ["combo-number-element", mutate(function (t) { t.detail.combination_escalation.push([7, "S6-long-plan"]); }), false],
  ["combo-object-element", mutate(function (t) { t.detail.combination_escalation.push([{}, "S6-long-plan"]); }), false],
  // Overlap between escalation fields is VALID: D1s shape table enumerates every
  // rejected condition and cross-field uniqueness is not among them, while the
  // D1 derivation order (solo before legacy_equivalent) makes a duplicate
  // behaviourally inert — both routes escalate to "high". Pinned as valid so a
  // future implementation cannot quietly add a uniqueness rule that would reject
  // a table the design permits.
  ["duplicate-across-solo-and-legacy", mutate(function (t) {
    t.write_code.solo_escalation = ["S3-security", "S1-multi-file"];
  }), true],
  ["duplicate-across-solo-and-combination", mutate(function (t) {
    t.detail.solo_escalation = t.detail.solo_escalation.concat(["S1b-wide-change"]);
  }), true],
];

for (const c of CASES) {
  let line;
  try {
    const r = c[1] === undefined ? m.validateRoutingTable() : m.validateRoutingTable(c[1]);
    const shapeOk = r && typeof r === "object" && typeof r.valid === "boolean" && Array.isArray(r.errors);
    if (!shapeOk) { line = "BAD_SHAPE"; }
    else if (r.valid !== c[2]) { line = "valid=" + r.valid + " want=" + c[2]; }
    else if (!r.valid && r.errors.length === 0) { line = "invalid-but-no-errors"; }
    else if (r.valid && r.errors.length !== 0) { line = "valid-but-errors"; }
    else { line = "OK"; }
  } catch (e) {
    line = "THREW:" + (e && e.name);
  }
  console.log(c[0] + " " + line);
}
')
    assert_block "V-1 validateRoutingTable classifies every malformed shape without throwing" "$got" <<'EOF'
default-arg OK
pristine-clone OK
table-array OK
table-string OK
table-null OK
table-number OK
missing-stage OK
extra-stage OK
entry-null OK
entry-primitive OK
entry-array OK
bad-default-level OK
missing-default-level OK
missing-undecidable-level OK
bad-undecidable-level OK
nonstring-default-level OK
solo-not-array OK
solo-empty-ok OK
solo-unknown-id OK
legacy-not-array OK
legacy-empty-inner OK
legacy-nonarray-inner OK
legacy-unknown-id OK
combo-empty-inner OK
combo-singleton OK
combo-not-array OK
combo-unknown-id OK
solo-number-element OK
solo-null-element OK
legacy-number-element OK
combo-number-element OK
combo-object-element OK
duplicate-across-solo-and-legacy OK
duplicate-across-solo-and-combination OK
EOF
}

# V-2: the D2 field split must stay structural. `solo_escalation` for write_code
# is pinned to S3-security alone (intent.md Scope), and combination_escalation
# may never hold a singleton (that is what legacy_equivalent_escalation is for).
d2099_table_structure() {
    local got
    got=$(run_node '
const m = require(process.env.CR_MOD_N);
const t = m.STAGE_ROUTING;
const soloSingletonLeak = m.ROUTING_STAGES.some(function (s) {
  return (t[s].combination_escalation || []).some(function (c) { return c.length < 2; });
});
console.log([
  t.detail.solo_escalation.join(","),
  t.write_tests.solo_escalation.join(","),
  t.write_code.solo_escalation.join(","),
  (t.write_code.legacy_equivalent_escalation || []).map(function (c) { return c.join("+"); }).join(","),
  (t.detail.combination_escalation || []).map(function (c) { return c.join("+"); }).join(","),
  soloSingletonLeak ? "SINGLETON_LEAK" : "NO_SINGLETON_LEAK",
  Object.isFrozen(t) && Object.isFrozen(t.detail.solo_escalation) ? "DEEP_FROZEN" : "NOT_DEEP_FROZEN",
].join(" | "));
')
    assert_eq "V-2 STAGE_ROUTING carries the D2 field split verbatim and its root/solo array are frozen" \
        "S2-architecture,S5-breaking | S1b-wide-change,S2-architecture,S3-security,S4-installer,S5-breaking | S3-security | S1-multi-file,S1b-wide-change,S2-architecture,S4-installer,S5-breaking,S6-long-plan | S1b-wide-change+S6-long-plan | NO_SINGLETON_LEAK | DEEP_FROZEN" \
        "$got"

    got=$(run_node '
const m = require(process.env.CR_MOD_N);
const d = m.ROUTING_STAGES.map(function (s) { return m.describeStageRouting(s); });
const allStrings = d.every(function (x) { return typeof x === "string" && x.length > 0; });
const mentionsOwnStage = m.ROUTING_STAGES.every(function (s, i) { return d[i].indexOf(s) !== -1; });
console.log((allStrings ? "STRINGS" : "NOT_STRINGS") + " " + (mentionsOwnStage ? "NAMED" : "UNNAMED"));
')
    assert_eq "V-3 describeStageRouting yields a non-empty description naming its own stage" \
        "STRINGS NAMED" "$got"
}

# V-4/V-5: TRUE deep freeze. V-2 only samples the root and one array, so a table
# whose stage entries or nested escalation arrays were left mutable would still
# report DEEP_FROZEN. detail.md "Files to modify" item 1 requires `Object.freeze`
# applied RECURSIVELY down to the nested arrays; a routing row that can be edited
# at runtime is a routing decision that can be edited at runtime.
d2099_table_deep_freeze() {
    local got
    got=$(run_node '
const m = require(process.env.CR_MOD_N);
// Walk every reachable object/array under the exported surface and name the
// unfrozen ones by path, so a failure says WHICH row is writable.
const unfrozen = [];
const seen = new Set();
function walk(v, path) {
  if (v === null || typeof v !== "object") { return; }
  if (seen.has(v)) { return; }
  seen.add(v);
  if (!Object.isFrozen(v)) { unfrozen.push(path); }
  if (Array.isArray(v)) {
    v.forEach(function (el, i) { walk(el, path + "[" + i + "]"); });
  } else {
    Object.keys(v).forEach(function (k) { walk(v[k], path + "." + k); });
  }
}
walk(m.STAGE_ROUTING, "STAGE_ROUTING");
walk(m.ROUTING_STAGES, "ROUTING_STAGES");
walk(m.SIGNAL_IDS, "SIGNAL_IDS");
walk(m.ROUTING_TABLE_ERRORS, "ROUTING_TABLE_ERRORS");
console.log(unfrozen.length ? unfrozen.sort().join(",") : "ALL_FROZEN");
')
    assert_eq "V-4 every nested node of the routing table (stage entries, escalation arrays, combination arrays) is frozen" \
        "ALL_FROZEN" "$got"

    # `Object.isFrozen` is the declaration; this is the behaviour. Sloppy mode
    # swallows the write, so each attempt is judged by whether the VALUE changed,
    # not by whether it threw — an implementation that froze nothing would be
    # caught here even if it never throws.
    got=$(run_node '
const m = require(process.env.CR_MOD_N);
const t = m.STAGE_ROUTING;
function snap(v) { return JSON.stringify(v); }
const ATTEMPTS = [
  ["root-replace-entry", function () { t.detail = {}; }],
  ["root-add-stage", function () { t.docs = { default_level: "low" }; }],
  ["root-delete-stage", function () { delete t.write_tests; }],
  ["entry-add-field", function () { t.detail.some_field = "x"; }],
  ["entry-overwrite-default-level", function () { t.detail.default_level = "high"; }],
  ["entry-overwrite-undecidable-level", function () { t.write_tests.undecidable_level = "low"; }],
  ["entry-replace-solo-array", function () { t.write_code.solo_escalation = []; }],
  ["solo-push", function () { t.detail.solo_escalation.push("S9-injected"); }],
  ["solo-element-assign", function () { t.detail.solo_escalation[0] = "S9-injected"; }],
  ["solo-length-truncate", function () { t.write_tests.solo_escalation.length = 0; }],
  ["combo-push", function () { t.detail.combination_escalation.push(["S3-security", "S4-installer"]); }],
  ["combo-inner-push", function () { t.detail.combination_escalation[0].push("S9-injected"); }],
  ["combo-inner-element-assign", function () { t.detail.combination_escalation[0][0] = "S9-injected"; }],
  ["legacy-push", function () { t.write_code.legacy_equivalent_escalation.push(["S9-injected"]); }],
  ["legacy-inner-element-assign", function () { t.write_code.legacy_equivalent_escalation[0][0] = "S9-injected"; }],
  ["stages-push", function () { m.ROUTING_STAGES.push("docs"); }],
  ["signal-ids-push", function () { m.SIGNAL_IDS.push("S9-injected"); }],
];
const mutated = [];
for (const a of ATTEMPTS) {
  const before = snap(t) + "|" + snap(m.ROUTING_STAGES) + "|" + snap(m.SIGNAL_IDS);
  try { a[1](); } catch (e) { /* strict-mode TypeError is a pass, not a change */ }
  const after = snap(t) + "|" + snap(m.ROUTING_STAGES) + "|" + snap(m.SIGNAL_IDS);
  if (before !== after) { mutated.push(a[0]); }
}
console.log(mutated.length ? mutated.join(",") : "NO_MUTATION_TOOK_EFFECT");
')
    assert_eq "V-5 no mutation of any routing row — root, stage entry, escalation array or nested combination — takes effect at runtime" \
        "NO_MUTATION_TOOK_EFFECT" "$got"

    # Teeth for V-4/V-5: the same walk and the same attempts against a THAWED
    # deep clone must report the mutations. Without this, a module that failed to
    # load at all (every attempt throwing) would look identical to a frozen one.
    got=$(run_node '
const m = require(process.env.CR_MOD_N);
const t = JSON.parse(JSON.stringify(m.STAGE_ROUTING));
let mutated = 0;
try { t.detail.some_field = "x"; if (t.detail.some_field === "x") { mutated++; } } catch (e) {}
try { t.detail.solo_escalation.push("S9-injected");
      if (t.detail.solo_escalation.indexOf("S9-injected") !== -1) { mutated++; } } catch (e) {}
try { t.detail.combination_escalation[0].push("S9-injected");
      if (t.detail.combination_escalation[0].indexOf("S9-injected") !== -1) { mutated++; } } catch (e) {}
console.log("thawed_mutations=" + mutated);
')
    assert_eq "V-6 teeth: the same mutation attempts DO take effect on a thawed clone, so V-5 is measuring the freeze" \
        "thawed_mutations=3" "$got"
}

d2099_validate_table
d2099_table_structure
d2099_table_deep_freeze
