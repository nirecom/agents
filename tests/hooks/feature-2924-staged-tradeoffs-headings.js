"use strict";
// tests/hooks/feature-2924-staged-tradeoffs-headings.js
// Tests: hooks/lib/plan-schema.js, bin/sweep-plan-headings.js
// Tags: TL1, TL2, hooks, plan-schema, sweep, accepted-tradeoffs, staged-heading, lint-plan-lang, table-driven, scope:issue-specific
// lang-check: ignore — the assertions match plan-language marker values and plan text the code under test emits (functional data).
// #2924: each plan stage writes its own `## Accepted Tradeoffs (<stage>)`; the legacy
// `## Accepted Tradeoffs` stays readable as the intent stage. plan-schema.js owns the rule and
// the CLI; bin/sweep-plan-headings.js is unchanged but must keep working on the staged headings.
// TL3 gap: a --all sweep over a real plans dir mixing legacy and staged plans.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const assert = require("node:assert");
const { test, after } = require("node:test");
const cp = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2924-headings-"));
after(() => { restore(); fs.rmSync(TMP, { recursive: true, force: true }); });
const ROOT = path.resolve(__dirname, "..", "..");
const SCHEMA = path.join(ROOT, "hooks", "lib", "plan-schema.js");
const SWEEP = path.join(ROOT, "bin", "sweep-plan-headings.js");
const S = require(SCHEMA);
const cli = (...args) => cp.spawnSync(process.execPath, [SCHEMA, ...args], { encoding: "utf8", timeout: 30000 });

caseBegin("accepted-tradeoffs-stage-table", "hooks/lib/plan-schema.js");
const STAGE_CASES = [
  { name: "intent", input: "Accepted Tradeoffs (intent)", want: "intent" },
  { name: "outline", input: "Accepted Tradeoffs (outline)", want: "outline" },
  { name: "detail", input: "Accepted Tradeoffs (detail)", want: "detail" },
  { name: "legacy-maps-to-intent", input: "Accepted Tradeoffs", want: "intent" },
  { name: "h2-line-form", input: "## Accepted Tradeoffs (outline)", want: "outline" },
  { name: "unknown-stage", input: "Accepted Tradeoffs (foo)", want: null },
  { name: "other-heading", input: "Risks & edge cases", want: null },
  { name: "empty", input: "", want: null },
  { name: "null", input: null, want: null },
];
for (const { name, input, want } of STAGE_CASES) {
  test(`acceptedTradeoffsStage ${name}`, () => {
    assert.strictEqual(typeof S.acceptedTradeoffsStage, "function", "acceptedTradeoffsStage is not exported");
    assert.strictEqual(S.acceptedTradeoffsStage(input), want, `${name}: input=${JSON.stringify(input)}`);
  });
}
caseEnd();

caseBegin("accepted-tradeoffs-heading-builder", "hooks/lib/plan-schema.js");
test("acceptedTradeoffsHeading builds the staged literal and the constants are exported", () => {
  assert.strictEqual(typeof S.acceptedTradeoffsHeading, "function", "acceptedTradeoffsHeading is not exported");
  for (const stage of ["intent", "outline", "detail"]) {
    assert.strictEqual(S.acceptedTradeoffsHeading(stage), `Accepted Tradeoffs (${stage})`, stage);
  }
  assert.deepStrictEqual(Array.from(S.ACCEPTED_TRADEOFFS_STAGES || []), ["intent", "outline", "detail"]);
  assert.strictEqual(S.LEGACY_ACCEPTED_TRADEOFFS, "Accepted Tradeoffs");
});
caseEnd();

caseBegin("canonical-sections-carry-staged-heading", "hooks/lib/plan-schema.js");
test("CANONICAL_SECTIONS carry the staged heading per artifact type", () => {
  const C = S.CANONICAL_SECTIONS;
  assert.ok(C.intent.includes("Accepted Tradeoffs (intent)"), `intent=${JSON.stringify(C.intent)}`);
  assert.ok(!C.intent.includes("Accepted Tradeoffs"), "intent still lists the legacy heading");
  assert.ok(C.outline.includes("Accepted Tradeoffs (outline)"), `outline=${JSON.stringify(C.outline)}`);
  assert.ok(!C.outline.includes("Accepted Tradeoffs"), "outline still lists the legacy heading");
  const d = C.detail;
  const at = d.indexOf("Accepted Tradeoffs (detail)");
  assert.ok(at > 0 && d[at - 1] === "Risks & edge cases", `detail=${JSON.stringify(d)}`);
});
test("the legacy literal and the staged literals stay canonical", () => {
  for (const h of ["Accepted Tradeoffs", "Accepted Tradeoffs (intent)", "Accepted Tradeoffs (outline)", "Accepted Tradeoffs (detail)"]) {
    assert.strictEqual(S.canonicalizeHeading(h), h, h);
  }
  assert.strictEqual(S.canonicalizeHeading("受容したトレードオフ"), "Accepted Tradeoffs");
});
caseEnd();

caseBegin("cli-accepted-tradeoffs-heading", "hooks/lib/plan-schema.js");
const CLI_CASES = [
  { name: "intent", stage: "intent", want: "Accepted Tradeoffs (intent)\n" },
  { name: "outline", stage: "outline", want: "Accepted Tradeoffs (outline)\n" },
  { name: "detail", stage: "detail", want: "Accepted Tradeoffs (detail)\n" },
];
for (const { name, stage, want } of CLI_CASES) {
  test(`CLI --accepted-tradeoffs-heading ${name}`, () => {
    const r = cli("--accepted-tradeoffs-heading", stage);
    assert.strictEqual(r.status, 0, `${name}: status=${r.status} err=${r.stderr}`);
    assert.strictEqual(r.stdout, want, name);
  });
}
for (const { name, args } of [{ name: "unknown-stage", args: ["foo"] }, { name: "missing-stage", args: [] }]) {
  test(`CLI --accepted-tradeoffs-heading ${name} exits non-zero`, () => {
    const r = cli("--accepted-tradeoffs-heading", ...args);
    assert.notStrictEqual(r.status, 0, `${name}: stdout=${r.stdout}`);
    assert.strictEqual(r.stdout, "", name);
  });
}
test("CLI --accepted-tradeoffs-headings lists the 3 staged headings and the legacy one", () => {
  const r = cli("--accepted-tradeoffs-headings");
  assert.strictEqual(r.status, 0, `status=${r.status} err=${r.stderr}`);
  const lines = r.stdout.replace(/\n$/, "").split("\n");
  assert.deepStrictEqual(lines.slice().sort(), [
    "Accepted Tradeoffs",
    "Accepted Tradeoffs (detail)",
    "Accepted Tradeoffs (intent)",
    "Accepted Tradeoffs (outline)",
  ]);
});
caseEnd();

caseBegin("lint-plan-lang-accepts-staged-and-legacy", "hooks/lib/plan-schema.js");
const { lintPlanLang } = require(path.join(ROOT, "hooks", "lib", "lint-plan-lang.js"));
const LINT_CASES = [
  { name: "intent-staged", type: "intent", heading: "Accepted Tradeoffs (intent)" },
  { name: "intent-legacy", type: "intent", heading: "Accepted Tradeoffs" },
  { name: "outline-staged", type: "outline", heading: "Accepted Tradeoffs (outline)" },
  { name: "outline-legacy", type: "outline", heading: "Accepted Tradeoffs" },
  { name: "detail-staged", type: "detail", heading: "Accepted Tradeoffs (detail)" },
];
for (const { name, type, heading } of LINT_CASES) {
  test(`lint-plan-lang reports no heading violation for ${name}`, () => {
    const v = lintPlanLang(`# Plan\n\n## ${heading}\n\nNone.\n`, "english", type);
    assert.deepStrictEqual(v, [], `${name}: ${JSON.stringify(v)}`);
  });
}
test("lint-plan-lang still flags the localized variant (control)", () => {
  const v = lintPlanLang("# Plan\n\n## 受容したトレードオフ\n", "off", "intent");
  assert.strictEqual(v.length, 1, JSON.stringify(v));
});
caseEnd();

const SID = "a1b2c3d4-e5f6-7890-abcd-ef12349292";
function sweep(file, fix) {
  const args = fix ? [SWEEP, "--fix", file] : [SWEEP, file];
  return cp.execFileSync(process.execPath, args, { encoding: "utf8", cwd: TMP, timeout: 30000 });
}
function lines(file) { return fs.readFileSync(file, "utf8").split(/\r?\n/); }
function count(file, line) { return lines(file).filter((l) => l === line).length; }

caseBegin("sweep-staged-outline-heading-is-reordered", "bin/sweep-plan-headings.js");
test("--fix moves ## Accepted Tradeoffs (outline) into canonical order without renaming it", () => {
  const f = path.join(TMP, `${SID}01-outline.md`);
  fs.writeFileSync(f, "# Plan\n\n## Issues\n\n- #1\n\n## Accepted Tradeoffs (outline)\n\n- staged-body-marker\n\n## Adopted approach\n\napproach body\n");
  sweep(f, true);
  const ls = lines(f);
  assert.strictEqual(count(f, "## Accepted Tradeoffs (outline)"), 1, ls.join("\n"));
  assert.ok(ls.some((l) => l.includes("staged-body-marker")), "the staged body was dropped");
  const a = ls.indexOf("## Adopted approach");
  const t = ls.indexOf("## Accepted Tradeoffs (outline)");
  assert.ok(a >= 0 && t > a, `Accepted Tradeoffs (outline) must follow Adopted approach: ${ls.join(" | ")}`);
});
caseEnd();

caseBegin("sweep-legacy-outline-heading-is-kept", "bin/sweep-plan-headings.js");
test("a legacy ## Accepted Tradeoffs is never rewritten to a staged heading or dropped", () => {
  const f = path.join(TMP, `${SID}02-outline.md`);
  fs.writeFileSync(f, "# Plan\n\n## Adopted approach\n\napproach body\n\n## Accepted Tradeoffs\n\n- legacy-body-marker\n");
  assert.ok(sweep(f, true).includes("[outline]"), "the sweep did not treat the fixture as an outline (vacuous)");
  assert.strictEqual(count(f, "## Accepted Tradeoffs"), 1);
  assert.strictEqual(count(f, "## Accepted Tradeoffs (outline)"), 0);
  assert.ok(lines(f).some((l) => l.includes("legacy-body-marker")), "the legacy body was dropped");
});
caseEnd();

caseBegin("sweep-staged-detail-heading-needs-no-change", "bin/sweep-plan-headings.js");
test("dry-run reports no rename for ## Accepted Tradeoffs (detail) and leaves the file intact", () => {
  const f = path.join(TMP, `${SID}03-detail.md`);
  const before = "# Detail\n\n## Risks & edge cases\n\n- r\n\n## Accepted Tradeoffs (detail)\n\nなし\n";
  fs.writeFileSync(f, before);
  const out = sweep(f, false);
  assert.ok(out.includes("[detail]") && !out.includes("rename"), out);
  assert.strictEqual(fs.readFileSync(f, "utf8"), before);
});
caseEnd();
