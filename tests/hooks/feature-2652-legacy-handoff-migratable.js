#!/usr/bin/env node
"use strict";
// Tests: hooks/lib/temporary-migrations/control-dir-split/plan.js
// Tags: TL2, control-dir, migration, legacy-handoff, plans-artifact-registry, regression-2652, scope:issue-specific, pwsh-not-required
// #2652: a leftover plans-dir <sid>-handoff.md (control kind legacy-handoff) is still migratable, so the
// control-dir migration moves it next to the state file where the state handoff reader looks for it.
// TL3 gap (what this test does NOT catch):
// - the move itself; feature-2652-state-handoff-reader.js R24/R25 drive it through readStateHandoff.

const { isolate } = require("../lib/harness");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { after, test } = require("node:test");

const restore = isolate();
after(restore);

const PLAN = require(path.resolve(__dirname, "..", "..", "hooks", "lib", "temporary-migrations", "control-dir-split", "plan.js"));
const SID = "aa000000-0000-4000-8000-000000002652";
const PLANS = process.env.WORKFLOW_PLANS_DIR;
fs.mkdirSync(PLANS, { recursive: true });
for (const n of ["handoff.md", "handoff-risk.json", "handoff.md.bak", "handoff.md.tmp"]) fs.writeFileSync(path.join(PLANS, `${SID}-${n}`), "x");
fs.mkdirSync(path.join(PLANS, `${SID}-handoff-pressure.json`));
const listed = PLAN.listSessionEntries(SID, PLANS);

test("legacy-handoff is in the control-dir-split MIGRATABLE set", () => {
  assert.strictEqual(PLAN.MIGRATABLE.has("legacy-handoff"), true);
});

const cases = [
  { name: "handoff-md", input: "handoff.md", want: "legacy-handoff" },
  { name: "handoff-risk", input: "handoff-risk.json", want: "legacy-handoff" },
  { name: "bak-suffix", input: "handoff.md.bak", want: null },
  { name: "tmp-never-moved", input: "handoff.md.tmp", want: null },
  { name: "directory-not-moved", input: "handoff-pressure.json", want: null },
];
for (const { name, input, want } of cases) {
  test(`${name}: plans-dir ${input} -> ${want === null ? "not listed for migration" : want}`, () => {
    const hit = listed.find((e) => e.name === input);
    assert.strictEqual(hit ? hit.kind : null, want, `${name}: ${JSON.stringify(listed)}`);
    if (want) assert.strictEqual(hit.src, path.join(PLANS, `${SID}-${input}`), `${name}: src`);
  });
}
