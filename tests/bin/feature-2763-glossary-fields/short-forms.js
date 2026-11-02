"use strict";
// Test bodies for tests/bin/feature-2763-glossary-fields.js (#2763): the Short forms field — the
// spelling check (a proper word subsequence of the headword), the overlap check across records,
// the entry and V3-row gates built on them, and the provenance of a Short forms change.
// Holds no case markers; the entrypoint wraps each body in its own test() inside a case.

const assert = require("node:assert");
const path = require("node:path");
const X = require("./fixtures");

const ROOT = path.resolve(__dirname, "..", "..", "..");
const load = (rel) => require(path.join(ROOT, rel));
const refused = (why) => typeof why === "string" && why !== "";

// [name, term, spelling]: an order-preserving, shorter run of the headword's words.
const GOOD = [
  ["last word of a two-word term", "workflow step", "step"],
  ["first word of a two-word term", "detail plan", "detail"],
  ["non-adjacent words of a three-word term", "state handoff record", "state record"],
];
// [name, term, spelling]: each is refused by checkShortFormSpelling.
const BAD = [
  ["words out of order", "state handoff record", "record state"],
  ["the headword itself", "workflow step", "workflow step"],
  ["the headword with case and separator changes", "workflow step", "Workflow-Step"],
  ["a synonym (not a word of the headword)", "workflow step", "stage"],
  ["a one-word term (no proper subsequence)", "workflow", "workflow"],
  ["a plural of a headword word", "workflow step", "steps"],
  ["an empty spelling", "workflow step", ""],
  ["a whitespace-only spelling", "workflow step", "   "],
];

function termModule() {
  const t = load("hooks/lib/glossary-term.js");
  assert.strictEqual(typeof t.checkShortFormSpelling, "function", "checkShortFormSpelling is exported");
  assert.strictEqual(typeof t.shortFormConflicts, "function", "shortFormConflicts is exported");
  return t;
}

function spellingCheck() {
  const t = termModule();
  for (const [name, term, s] of GOOD) {
    assert.strictEqual(t.checkShortFormSpelling(term, s), null, `${name}: ${term} / ${s} passes`);
  }
  for (const [name, term, s] of BAD) {
    const why = t.checkShortFormSpelling(term, s);
    assert.ok(refused(why), `${name}: ${term} / ${JSON.stringify(s)} is refused: ${JSON.stringify(why)}`);
  }
}

const rec = (term, shortForms) => ({ term, shortForms });
const pick = (cs) => cs.map((c) => [c.term, c.spelling]);

function conflicts() {
  const t = termModule();
  const headword = t.shortFormConflicts([rec("detail plan", ["detail"]), rec("detail", [])]);
  assert.deepStrictEqual(pick(headword), [["detail plan", "detail"]], `overlap with a headword: ${JSON.stringify(headword)}`);
  assert.strictEqual(headword[0].other, "detail", "other names the headword it overlaps");
  const caseVariant = t.shortFormConflicts([rec("detail plan", ["Detail"]), rec("detail", [])]);
  assert.deepStrictEqual(pick(caseVariant), [["detail plan", "Detail"]], `compactKey folds case: ${JSON.stringify(caseVariant)}`);
  const shared = t.shortFormConflicts([rec("detail plan", ["detail"]), rec("detail view", ["detail"])]);
  assert.ok(shared.length > 0, "overlap with another entry's short form is detected");
  for (const c of shared) {
    assert.strictEqual(c.spelling, "detail", JSON.stringify(c));
    assert.strictEqual(c.other, c.term === "detail plan" ? "detail view" : "detail plan", `other is the other entry: ${JSON.stringify(c)}`);
  }
  const dup = t.shortFormConflicts([rec("workflow step", ["step", "step"])]);
  assert.ok(dup.length > 0 && dup.every((c) => c.term === "workflow step" && c.spelling === "step"),
    `duplicate inside one list: ${JSON.stringify(dup)}`);
  for (const c of headword.concat(shared, dup)) assert.ok(refused(c.other), `other is a non-empty string: ${JSON.stringify(c)}`);
  const disjoint = [rec("detail plan", ["detail"]), rec("workflow step", ["step"]), rec("intent", []), rec("plan step", [])];
  assert.deepStrictEqual(t.shortFormConflicts(disjoint), [], "disjoint short forms (a word inside another headword is fine)");
  assert.deepStrictEqual(t.shortFormConflicts([]), [], "no records");
}

const fieldViolations = (out) => out.filter((l) => !/disallowed bullet/.test(l));

// The entry gate (entries.js FIELDS) and the V3 row gate (intent-glossary.js FIELD_CELLS) apply it.
function entryForm() {
  const e = load("bin/lib/glossary-format/entries.js");
  for (const [name, term, s] of BAD) {
    const out = e.checkGlossaryFile(X.file("internal", [X.entry(term, "A term.", { shortForms: [s] })]));
    assert.ok(out.length > 0 && fieldViolations(out).length === out.length, `${name}: refused as a field: ${out}`);
  }
  for (const [name, term, s] of GOOD) {
    assert.deepStrictEqual(e.checkGlossaryFile(X.file("internal", [X.entry(term, "A term.", { shortForms: [s] })])), [], name);
  }
}

function intentRows() {
  const g = load("hooks/lib/intent-glossary.js");
  for (const [name, term, s] of BAD) {
    const vs = g.checkIntentGlossary(X.v3([X.v3Row(term, "user", "add", "A term.", [], [s])]));
    const fieldVs = vs.filter((v) => !/header/i.test(v.reason));
    assert.ok(fieldVs.length > 0 && fieldVs.length === vs.length, `${name}: ${JSON.stringify(vs)}`);
  }
  for (const [name, term, s] of GOOD) {
    assert.deepStrictEqual(g.checkIntentGlossary(X.v3([X.v3Row(term, "user", "add", "A term.", [], [s])])), [], name);
  }
}

// A Short forms change is a fields redefine: a V2 row cannot record it; a V3 row must state it.
// h: { opsOf, reasons, userFile } from the entrypoint.
function provenance(h) {
  const plain = X.entry("status line", "A line.");
  const withShort = X.entry("status line", "A line.", { shortForms: ["status"] });
  const ops = h.opsOf(h.userFile(plain), h.userFile(withShort));
  assert.deepStrictEqual(ops.map((o) => [o.term, o.operation, o.fieldsChanged]), [["status line", "redefine", true]]);
  assert.deepStrictEqual(h.reasons(ops, X.v2([X.v2Row("status line", "user", "redefine", "A line.")])),
    [["status line", "redefine", "fields-unrecorded"]]);
  assert.deepStrictEqual(h.reasons(ops, X.v3([X.v3Row("status line", "user", "redefine", "A line.", [], ["line"])])),
    [["status line", "redefine", "fields-mismatch"]]);
  assert.deepStrictEqual(h.reasons(ops, X.v3([X.v3Row("status line", "user", "redefine", "A line.", [], ["status"])])), []);
}

module.exports = { GOOD, BAD, spellingCheck, conflicts, entryForm, intentRows, provenance };
