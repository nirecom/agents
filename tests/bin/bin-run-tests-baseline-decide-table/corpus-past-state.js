"use strict";
// Private case of tests/bin/bin-run-tests-baseline-decide-table.js: corpus (3).
// Checks that every (class, detail) seen in past state (./classifications-seen-in-past-state.json, a snapshot collected once)
// is reachable through the decide output, or through the outside-decide list / the reuse-path list.
const { test } = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");
const { caseBegin, caseEnd } = require("../../lib/harness");
const S = require("./_shared");

const DATA = require(path.join(__dirname, "classifications-seen-in-past-state.json"));
const SHA = "89abcdef0123456789abcdef0123456789abcdef";
const FAILS_AT_BASE = /^fails-at-base-exit-(0|[1-9][0-9]*)(-new-lines)?$/;

// Returns where one entry is reached ("decide" / "decide-direct" / "outside:<id>" / "reuse:<id>" / null).
function reach(entry, reached) {
  const D = S.D();
  if (reached.has(`${entry.class}\t${entry.detail}`)) return "decide";
  const m = FAILS_AT_BASE.exec(entry.detail);
  if (m) {
    // Other exits (2, 4, 6 and so on) fold into the representative 3 in the domain, so build the input directly to check.
    const input = S.IN(S.K.failNormal, S.R("FAIL", "completed", Number(m[1])), "unchanged",
      { branchRecordsAsNormal: m[2] ? "new" : "same" });
    const out = D.decide(input);
    if (out.class === entry.class && out.detail === entry.detail) return "decide-direct";
  }
  for (const [kind, list] of [["outside", D.DETAILS_DECIDED_OUTSIDE_DECIDE], ["reuse", D.DETAILS_FROM_REUSE_PATH]]) {
    const e = list.find((x) => x.detailPattern.test(entry.detail) && x.classes.includes(entry.class));
    if (e) return `${kind}:${e.id}`;
  }
  return null;
}

caseBegin("DT-corpus-past-state", "bin/lib/run-tests-baseline-decide/evaluate.js");
test("DT-corpus-3: every (class, detail) seen in past state is reachable", () => {
  assert.ok(Array.isArray(DATA.classifications) && DATA.classifications.length > 0, "the data has classifications");
  const reached = new Set();
  for (const input of S.D().enumerateDecideInputDomain()) {
    const out = S.D().decide(input);
    if (typeof out.class === "string") reached.add(`${out.class}\t${out.detail}`);
  }
  const unreachable = [];
  for (const raw of DATA.classifications) {
    const entry = { class: raw.class, detail: raw.detail.replace("<sha>", SHA) };
    if (!reach(entry, reached)) unreachable.push(`${raw.class}/${raw.detail}`);
  }
  assert.deepEqual(unreachable, [], "unreachable (class, detail)");
});
caseEnd();

caseBegin("DT-corpus-data-shape", "bin/lib/run-tests-baseline-decide/evaluate.js");
test("DT-corpus-data: the data holds only (class, detail), without sha or -via-rename:", () => {
  for (const e of DATA.classifications) {
    assert.deepEqual(Object.keys(e).sort(), ["class", "detail"], JSON.stringify(e));
    assert.ok(!/-via-rename:/.test(e.detail) && !/[0-9a-f]{40}/.test(e.detail), `${e.detail}: normalized`);
  }
  const keys = DATA.classifications.map((e) => `${e.class}\t${e.detail}`);
  assert.equal(new Set(keys).size, keys.length, "no duplicates");
});
caseEnd();
