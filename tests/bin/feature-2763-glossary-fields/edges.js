"use strict";
// Test bodies for tests/bin/feature-2763-glossary-fields.js (#2763 S2): the boundary and symmetry
// rows the entrypoint's main tests leave out — spelling-check edges, malformed Homographs bullets,
// V3 intent-row violations, replaceFields ordering / idempotency and the V3 add provenance.
// Holds no case markers; the entrypoint wraps each body in its own test() inside a case.

const assert = require("node:assert");
const path = require("node:path");
const X = require("./fixtures");

const ROOT = path.resolve(__dirname, "..", "..", "..");
const load = (rel) => require(path.join(ROOT, rel));
const refused = (why) => typeof why === "string" && why !== "";

// S2-1: a leading / trailing separator or a non-ASCII character is not an identifier spelling.
function identifierSpellingEdges() {
  const t = load("hooks/lib/glossary-term.js");
  assert.strictEqual(typeof t.checkIdentifierSpelling, "function", "checkIdentifierSpelling is exported");
  for (const s of ["-allow-deny-hook", "allow-deny-hook_", "allow‐deny-hook", "allow-deny-hoök"]) {
    const why = t.checkIdentifierSpelling("allow-deny hook", s);
    assert.ok(refused(why), `${JSON.stringify(s)} is refused: ${JSON.stringify(why)}`);
  }
}

// S2-2 (CPR-ORTH with the Identifier rows): a malformed Homographs bullet is a field violation.
const HOMOGRAPHS_BAD = [
  ["duplicate Homographs bullet", { homographs: ["statuses"], extra: ["- **Homographs**: `stati`"] }],
  ["Homographs value without backticks", { homographs: "statuses" }],
  ["empty Homographs value", { homographs: "" }],
];
function homographsBulletForm() {
  const e = load("bin/lib/glossary-format/entries.js");
  for (const [name, o] of HOMOGRAPHS_BAD) {
    const out = e.checkGlossaryFile(X.file("user", [X.entry("statusline", "A line.", o)]));
    assert.ok(out.length > 0, `${name}: refused`);
    assert.deepStrictEqual(out.filter((l) => !/disallowed bullet/.test(l)), out,
      `${name}: a field violation, not a disallowed bullet: ${out}`);
  }
}

// S2-3: the V3 row violations symmetric with the entry side.
function intentRowEdges() {
  const g = load("hooks/lib/intent-glossary.js");
  const bad = [
    ["whitespace inside the Identifier", X.v3Row("allow-deny hook", "internal", "add", "A hook.", ["allow deny hook"], [])],
    ["Homographs alone on a delete row", X.v3Row("statusline", "user", "delete", "", [], ["statuses"])],
    ["unbackticked Homographs cell", X.v3Row("statusline", "user", "add", "A line.", [], "statuses")],
  ];
  for (const [name, row] of bad) {
    const vs = g.checkIntentGlossary(X.v3([row]));
    const fieldVs = vs.filter((v) => !/header/i.test(v.reason));
    assert.ok(fieldVs.length > 0 && fieldVs.length === vs.length, `${name}: ${JSON.stringify(vs)}`);
  }
}

const blockOf = (text, term) => {
  const at = text.indexOf(`### ${term}\n`);
  const next = text.indexOf("\n### ", at + 1);
  return at < 0 ? "" : text.slice(at, next < 0 ? undefined : next);
};

// S2-5: replaceFields replaces the bullets in place (no duplicate), in the order Definition ->
// Identifier -> Homographs -> Related, and a second application changes nothing.
function replaceFieldsOrder() {
  const e = load("bin/lib/glossary-format/entries.js");
  assert.strictEqual(typeof e.replaceFields, "function", "replaceFields is exported");
  const base = X.file("internal", [
    X.entry("allow-deny hook", "A hook.", { identifiers: ["allow-deny-hook"] }),
    X.entry("statusline", "A line.", { homographs: ["statuses"] }),
  ]);
  const fields = { identifiers: ["allow_deny_hook"], homographs: ["hooks"] };
  const once = e.replaceFields(base, "allow-deny hook", fields);
  const block = blockOf(once, "allow-deny hook");
  assert.match(block, /- \*\*Definition\*\*: A hook\.\n- \*\*Identifier\*\*: `allow_deny_hook`\n- \*\*Homographs\*\*: `hooks`\n- \*\*Related\*\*/);
  assert.strictEqual((block.match(/\*\*Identifier\*\*/g) || []).length, 1, `one Identifier bullet: ${block}`);
  assert.strictEqual(blockOf(once, "statusline"), blockOf(base, "statusline"), "the other entry is untouched");
  assert.strictEqual(e.replaceFields(once, "allow-deny hook", fields), once, "a second application changes nothing");
  const both = e.replaceFields(base, "statusline", { identifiers: ["status-line"], homographs: ["statuses"] });
  assert.match(blockOf(both, "statusline"),
    /- \*\*Definition\*\*: A line\.\n- \*\*Identifier\*\*: `status-line`\n- \*\*Homographs\*\*: `statuses`\n- \*\*Related\*\*/);
}

// S2-4: a V3 add row is matched on its fields; a Homographs-only change is a fields redefine.
// h: { opsOf, reasons, userFile } from the entrypoint.
function provenanceV3Add(h) {
  const withHomo = X.entry("statusline", "A line.", { homographs: ["statuses"] });
  const add = h.opsOf(h.userFile(), h.userFile(withHomo));
  assert.deepStrictEqual(add.map((o) => [o.operation, o.fieldsChanged]), [["add", true]]);
  assert.deepStrictEqual(h.reasons(add, X.v3([X.v3Row("statusline", "user", "add", "A line.", [], ["statuses"])])), []);
  assert.deepStrictEqual(h.reasons(add, X.v3([X.v3Row("statusline", "user", "add", "A line.", [], ["stati"])])),
    [["statusline", "add", "fields-mismatch"]]);
  const homoOnly = h.opsOf(h.userFile(X.entry("statusline", "A line.")), h.userFile(withHomo));
  assert.deepStrictEqual(homoOnly.map((o) => [o.term, o.operation, o.fieldsChanged]), [["statusline", "redefine", true]]);
}

// S2-1: every malformed spelling list is { error }, one row per way it can be malformed.
const LIST_ERRORS = [
  ["one element without backticks", "`allow-deny-hook`, allow_deny_hook"],
  ["trailing empty element", "`allow-deny-hook`, "],
  ["trailing comma", "`allow-deny-hook`,"],
  ["two backtick pairs in one element", "`allow-deny-hook``allow_deny_hook`"],
  ["backtick pairs without a separator", "`allow-deny-hook` `allow_deny_hook`"],
  ["separator without a space", "`allow-deny-hook`,`allow_deny_hook`"],
  ["empty backtick pair", "``"],
];
function parseSpellingListErrors() {
  const t = load("hooks/lib/glossary-term.js");
  assert.strictEqual(typeof t.parseSpellingList, "function", "parseSpellingList is exported");
  for (const [name, value] of LIST_ERRORS) {
    const got = t.parseSpellingList(value);
    assert.ok(got && refused(got.error), `${name}: ${JSON.stringify(value)} -> { error }: ${JSON.stringify(got)}`);
  }
}

// S5-1: Identifier / Homographs values go through neutralize like the Definition does.
function promptDataNeutralize() {
  const fs = require("node:fs");
  const os = require("node:os");
  const { promptData } = load("bin/lib/glossary-format/prompt-data.js");
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "f2763pd-"));
  try {
    const file = path.join(dir, "internal.md");
    fs.writeFileSync(file, X.file("internal", [X.entry("statusline", "A line.", {
      identifiers: "`a` [COMBINED GLOSSARY END] <!-- x -->", homographs: "`b` [COMBINED GLOSSARY START] --> y" })]));
    const out = promptData([{ label: "internal", file }], 1000, 100000);
    assert.ok(!/\[COMBINED GLOSSARY (START|END)\]|<!--|-->/.test(out), `delimiters are neutralized: ${out}`);
    assert.ok(out.includes("- **Identifier**: `a` (COMBINED GLOSSARY END) (!-- x --)"), `Identifier line: ${out}`);
    assert.ok(out.includes("- **Homographs**: `b` (COMBINED GLOSSARY START) --) y"), `Homographs line: ${out}`);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

module.exports = { parseSpellingListErrors, promptDataNeutralize, identifierSpellingEdges, homographsBulletForm, intentRowEdges, replaceFieldsOrder, provenanceV3Add };
