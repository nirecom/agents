"use strict";
// tests/skills/feature-2853-gate-action-audit-branches.js
// Tests: skills/clarify-intent/SKILL.md, skills/make-outline-plan/SKILL.md, skills/make-detail-plan/SKILL.md, skills/_shared/confirm-plan.md, bin/workflow/lib/next-step/gate-mode.js, docs/glossary/internal.md
// Tags: scope:issue-specific, TL1, pre-confirm-audit, next-step-gate, confirm-gate, test-lang-exception:text-only
// #2853: the plan-stage gate gains audit-wait / audit-block; every place that states the GATE_ACTION
// vocabulary (gate-mode.js, CPA-3, the three plan skills, the glossary) names the same values.
// TL3 gap: text-only; whether a live model takes these branches needs a real Claude Code session.

const { caseBegin, caseEnd } = require("../lib/harness");
const { test, after } = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "..", "..");
const read = (rel) => { try { return fs.readFileSync(path.join(ROOT, rel), "utf8"); } catch (e) { return ""; } };
const NEW = ["audit-wait", "audit-block"];
let failures = 0;
function check(name, ok, detail) {
  if (ok) console.log(`PASS ${name}`);
  else { failures += 1; console.log(`FAIL ${name} :: ${String(detail).replace(/\s+/g, " ").slice(0, 300)}`); }
}
// checked(fn) -> a node:test body that fails when any check() inside fn fails.
const checked = (fn) => () => {
  const before = failures;
  fn();
  assert.strictEqual(failures - before, 0, "check(s) failed; see the FAIL lines above");
};
after(() => console.log(failures === 0 ? "ALL PASS" : `${failures} FAILED`));

// skillNamesBoth(rel): the skill file names both audit branches.
function skillNamesBoth(rel) {
  const text = read(rel);
  check(`(a) ${rel} readable`, text.length > 0, rel);
  for (const v of NEW) check(`(a) ${rel} mentions ${v}`, text.includes(v), "absent");
}

const cpa3 = () => { const m = /\*\*CPA-3[\s\S]*?(?=\n## |$)/.exec(read("skills/_shared/confirm-plan.md")); return m ? m[0] : ""; };

// The vocabulary gate-mode.js can print: the keys of its HINTS table.
function gateVocabulary() {
  const m = /const HINTS = \{([\s\S]*?)\n\};/.exec(read("bin/workflow/lib/next-step/gate-mode.js"));
  if (!m) return [];
  const keys = [];
  for (const k of m[1].matchAll(/^\s{2}(?:"([a-z-]+)"|([a-z]+)):/gm)) keys.push(k[1] || k[2]);
  return keys.sort();
}

caseBegin("(a) clarify-intent names both audit branches", "skills/clarify-intent/SKILL.md");
test("(a) clarify-intent names both audit branches", checked(() => skillNamesBoth("skills/clarify-intent/SKILL.md")));
caseEnd();

caseBegin("(a) make-outline-plan names both audit branches", "skills/make-outline-plan/SKILL.md");
test("(a) make-outline-plan names both audit branches", checked(() => skillNamesBoth("skills/make-outline-plan/SKILL.md")));
caseEnd();

caseBegin("(a) make-detail-plan names both audit branches", "skills/make-detail-plan/SKILL.md");
test("(a) make-detail-plan names both audit branches", checked(() => skillNamesBoth("skills/make-detail-plan/SKILL.md")));
caseEnd();

caseBegin("(b) CPA-3 defines audit-wait and audit-block", "skills/_shared/confirm-plan.md");
test("(b) CPA-3 defines audit-wait and audit-block", checked(() => {
  const sec = cpa3();
  check("(b) CPA-3 section found", sec.length > 0, "no CPA-3");
  for (const v of NEW) check(`(b) CPA-3 has a branch bullet for ${v}`, new RegExp("^- `" + v + "`", "m").test(sec), "no bullet");
}));
caseEnd();

caseBegin("(c) gate-mode.js vocabulary includes the audit values", "bin/workflow/lib/next-step/gate-mode.js");
test("(c) gate-mode.js vocabulary includes the audit values", checked(() => {
  const vocab = gateVocabulary();
  check("(c) HINTS table parsed", vocab.length >= 4, JSON.stringify(vocab));
  for (const v of NEW) check(`(c) gate-mode.js HINTS has ${v}`, vocab.includes(v), JSON.stringify(vocab));
  const header = read("bin/workflow/lib/next-step/gate-mode.js").split("\n").slice(0, 8).join(" ");
  for (const v of vocab) check(`(c) gate-mode.js header comment lists ${v}`, header.includes(v), header);
}));
caseEnd();

caseBegin("(c) glossary GATE_ACTION definition matches gate-mode.js", "docs/glossary/internal.md");
test("(c) glossary GATE_ACTION definition matches gate-mode.js", checked(() => {
  const vocab = gateVocabulary();
  const def = read("docs/glossary/internal.md").split("\n").find((l) => l.includes("closed-vocabulary confirm gate verdict")) || "";
  check("(c) glossary definition line found", def.length > 0, "missing");
  const listed = [...def.matchAll(/`([a-z-]+)`/g)].map((x) => x[1]).sort();
  check("(c) glossary lists exactly the gate-mode.js vocabulary", JSON.stringify(listed) === JSON.stringify(vocab), `glossary=${JSON.stringify(listed)} gate=${JSON.stringify(vocab)}`);
}));
caseEnd();

caseBegin("(c) CPA-3 branch bullets match gate-mode.js", "skills/_shared/confirm-plan.md");
test("(c) CPA-3 branch bullets match gate-mode.js", checked(() => {
  const vocab = gateVocabulary();
  const bullets = [...cpa3().matchAll(/^- `([a-z-]+)`/gm)].map((x) => x[1]).sort();
  check("(c) CPA-3 has one branch bullet per gate value", JSON.stringify(bullets) === JSON.stringify(vocab), `cpa3=${JSON.stringify(bullets)} gate=${JSON.stringify(vocab)}`);
}));
caseEnd();
