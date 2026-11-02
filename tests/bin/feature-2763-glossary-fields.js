"use strict";
// Tests: hooks/lib/glossary-term.js, bin/lib/glossary-format/entries.js, hooks/lib/intent-glossary.js, bin/lib/glossary-provenance.js, hooks/workflow-state/glossary-check/scope/sources.js, bin/lib/glossary-format/prompt-data.js
// Tags: TL2, glossary, glossary-fields, scope:issue-specific
// #2763 S2: the optional Identifier and Short forms fields of a glossary entry and of a V3 intent
// Glossary row — the shared spelling checks, the entry-form gate, the intent table parser, the
// provenance match (fields-mismatch / fields-unrecorded) and the term records of combinedGlossary.
// Text builders: feature-2763-glossary-fields/fixtures.js; Short forms bodies: short-forms.js.
// TL3 gap: the commit-time hooks that call these checks are driven by the review-doc-glossary and
// check-glossary-provenance suites, not here.
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");

const assert = require("node:assert");
const crypto = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { after, test } = require("node:test");
const X = require("./feature-2763-glossary-fields/fixtures");
const E = require("./feature-2763-glossary-fields/edges");
const S = require("./feature-2763-glossary-fields/short-forms");

const ROOT = path.resolve(__dirname, "..", "..");
const load = (rel) => require(path.join(ROOT, rel));
const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2763gf-"));
after(() => { restore(); fs.rmSync(TMP, { recursive: true, force: true }); });

caseBegin("glossary-term-spelling-checks", "hooks/lib/glossary-term.js");
test("parseSpellingList: empty, backticked list, unbackticked value", () => {
  const t = load("hooks/lib/glossary-term.js");
  assert.strictEqual(typeof t.parseSpellingList, "function", "parseSpellingList is exported");
  assert.deepStrictEqual(t.parseSpellingList(""), []);
  assert.deepStrictEqual(t.parseSpellingList("`allow-deny-hook`, `allow_deny_hook`"), ["allow-deny-hook", "allow_deny_hook"]);
  const bad = t.parseSpellingList("allow-deny-hook");
  assert.ok(bad && typeof bad.error === "string" && bad.error !== "", `unbackticked -> { error }: ${JSON.stringify(bad)}`);
});
test("parseSpellingList: each malformed list is { error }", E.parseSpellingListErrors);
test("checkIdentifierSpelling: same identKey passes; other key, whitespace and ReDoS input fail", () => {
  const t = load("hooks/lib/glossary-term.js");
  assert.strictEqual(typeof t.checkIdentifierSpelling, "function", "checkIdentifierSpelling is exported");
  for (const s of ["allow-deny-hook", "allow_deny_hook", "ALLOW_DENY_HOOK"]) {
    assert.ok(!t.checkIdentifierSpelling("allow-deny hook", s), `${s} passes`);
  }
  for (const s of ["allow-deny-hooks", "allow deny hook", "allow--deny-hook", ""]) {
    const why = t.checkIdentifierSpelling("allow-deny hook", s);
    assert.ok(typeof why === "string" && why !== "", `${JSON.stringify(s)} is refused: ${JSON.stringify(why)}`);
  }
  const start = process.hrtime.bigint();
  const why = t.checkIdentifierSpelling("allow-deny hook", "a-".repeat(50000) + "!");
  const ms = Number(process.hrtime.bigint() - start) / 1e6;
  assert.ok(typeof why === "string" && why !== "", "the ReDoS probe is refused");
  assert.ok(ms < 1000, `the ReDoS probe ends under 1000 ms (took ${ms} ms)`);
});
test("checkIdentifierSpelling refuses leading / trailing separators and non-ASCII", E.identifierSpellingEdges);
caseEnd();

caseBegin("glossary-term-short-forms", "hooks/lib/glossary-term.js");
test("checkShortFormSpelling: a proper word subsequence passes; order, headword, synonym, one-word term, empty fail", S.spellingCheck);
test("shortFormConflicts: headword, other short form and in-list duplicate overlaps; disjoint is empty", S.conflicts);
caseEnd();

const ALLOW_DENY = X.entry("allow-deny hook", "A hook.", { identifiers: ["allow-deny-hook", "allow_deny_hook"] });
const VALID_FILE = X.file("internal", [ALLOW_DENY, X.entry("status line", "A line.", { shortForms: ["status"] })]);
const fieldsViolations = (out) => out.filter((l) => !/disallowed bullet/.test(l));
const ENTRY_BAD = [
  ["duplicate Identifier bullet", { identifiers: ["allow-deny-hook"], extra: ["- **Identifier**: `allow_deny_hook`"] }],
  ["value without backticks", { identifiers: "allow-deny-hook" }],
  ["empty value", { identifiers: "" }],
  ["identKey mismatch", { identifiers: ["allow-deny-hooks"] }],
  ["whitespace inside the spelling", { identifiers: ["allow deny hook"] }],
];

caseBegin("glossary-entry-fields", "bin/lib/glossary-format/entries.js");
test("checkGlossaryFile accepts the Identifier and Short forms bullets", () => {
  const e = load("bin/lib/glossary-format/entries.js");
  assert.deepStrictEqual(e.checkGlossaryFile(VALID_FILE), []);
});
test("checkGlossaryFile refuses malformed Identifier values (not as a disallowed bullet)", () => {
  const e = load("bin/lib/glossary-format/entries.js");
  for (const [name, o] of ENTRY_BAD) {
    const out = e.checkGlossaryFile(X.file("internal", [X.entry("allow-deny hook", "A hook.", o)]));
    assert.ok(out.length > 0, `${name}: refused`);
    assert.deepStrictEqual(fieldsViolations(out), out, `${name}: a field violation, not a disallowed bullet: ${out}`);
  }
});
test("checkGlossaryFile refuses Short forms that are no proper word subsequence of the headword", S.entryForm);
test("entryFields and replaceFields", () => {
  const e = load("bin/lib/glossary-format/entries.js");
  assert.strictEqual(typeof e.entryFields, "function", "entryFields is exported");
  const [a, s] = e.parseGlossaryFile(VALID_FILE).entries;
  assert.deepStrictEqual(e.entryFields(a), { identifiers: ["allow-deny-hook", "allow_deny_hook"], shortForms: [] });
  assert.deepStrictEqual(e.entryFields(s), { identifiers: [], shortForms: ["status"] });
  assert.strictEqual(typeof e.replaceFields, "function", "replaceFields is exported");
  const set = e.replaceFields(VALID_FILE, "status line", { identifiers: ["status-line"], shortForms: [] });
  const block = set.slice(set.indexOf("### status line"));
  assert.match(block, /- \*\*Definition\*\*: A line\.\n- \*\*Identifier\*\*: `status-line`\n- \*\*Related\*\*/);
  assert.doesNotMatch(block, /Short forms/, "an empty Short forms field removes its bullet");
  const cleared = e.replaceFields(VALID_FILE, "allow-deny hook", { identifiers: [], shortForms: [] });
  assert.doesNotMatch(cleared.slice(0, cleared.indexOf("### status line")), /Identifier/, "empty fields remove the bullet");
  assert.deepStrictEqual(e.checkGlossaryFile(cleared), []);
});
test("checkGlossaryFile refuses malformed Short forms values (not as a disallowed bullet)", E.shortFormsBulletForm);
test("checkGlossaryFile refuses an unknown field bullet as a disallowed bullet", E.unknownFieldBullet);
test("replaceFields: no duplicate bullet, fixed order, idempotent", E.replaceFieldsOrder);
caseEnd();

const notHeader = (vs) => vs.filter((v) => !/header/i.test(v.reason));

caseBegin("intent-glossary-v3", "hooks/lib/intent-glossary.js");
test("V3 header is accepted and its rows carry the fields; V1 / V2 rows leave them undefined", () => {
  const g = load("hooks/lib/intent-glossary.js");
  const text = X.v3([X.v3Row("allow-deny hook", "internal", "add", "A hook.", ["allow-deny-hook"], []),
    X.v3Row("status line", "user", "redefine", "A line.", [], ["status"])]);
  assert.deepStrictEqual(g.checkIntentGlossary(text), []);
  const rows = g.parseIntentGlossary(text).rows;
  assert.deepStrictEqual(rows.map((r) => [r.term, r.definition, r.identifiers, r.shortForms]), [
    ["allow-deny hook", "A hook.", ["allow-deny-hook"], []],
    ["status line", "A line.", [], ["status"]],
  ]);
  const legacy = [X.v2([X.v2Row("statusline", "user", "add", "A line.")]),
    X.intent("| Term | Category | Definition |\n|---|---|---|\n| statusline | user | A line. |")];
  for (const t of legacy) {
    const [r] = g.parseIntentGlossary(t).rows;
    assert.strictEqual(r.identifiers, undefined);
    assert.strictEqual(r.shortForms, undefined);
  }
});
test("V3 rows: bad Identifier and fields on a delete row are violations", () => {
  const g = load("hooks/lib/intent-glossary.js");
  const bad = [
    ["identKey mismatch", X.v3Row("allow-deny hook", "internal", "add", "A hook.", ["allow-deny-hooks"], [])],
    ["unbackticked Identifier", X.v3Row("allow-deny hook", "internal", "add", "A hook.", "allow-deny-hook", [])],
    ["fields on a delete row", X.v3Row("allow-deny hook", "internal", "delete", "", ["allow-deny-hook"], [])],
  ];
  for (const [name, row] of bad) {
    const vs = g.checkIntentGlossary(X.v3([row]));
    assert.ok(notHeader(vs).length > 0 && notHeader(vs).length === vs.length, `${name}: ${JSON.stringify(vs)}`);
  }
});
test("V3 rows: Short forms that are no proper word subsequence are violations; good ones pass", S.intentRows);
test("V3 rows: whitespace in the Identifier and Short forms alone on a delete row are violations", E.intentRowEdges);
test("V3 table: a Short forms overlap between rows is a violation; an unknown sixth column is a header violation",
  require("./feature-2763-glossary-fields/intent-rows").tableShortForms);
caseEnd();

const USER = "docs/glossary/user.md";
const INTERNAL = "docs/glossary/internal.md";
const INTERNAL_TEXT = X.file("internal", [X.entry("kilo", "K.")]);
const userFile = (...entries) => X.file("user", entries);
function opsOf(baseUser, nextUser) {
  const p = load("bin/lib/glossary-provenance.js");
  const sets = (u) => p.readTermSets((f) => ({ [USER]: u, [INTERNAL]: INTERNAL_TEXT })[f], [USER, INTERNAL]);
  return p.computeOperations(sets(baseUser), sets(nextUser));
}
const reasons = (ops, intentText) => {
  const p = load("bin/lib/glossary-provenance.js");
  const rows = intentText ? load("hooks/lib/intent-glossary.js").parseIntentGlossary(intentText).rows : [];
  return p.matchOperations(ops, rows, []).unmatched.map((u) => [u.term, u.operation, u.reason]);
};
const PLAIN = X.entry("statusline", "A line.");
const WITH_ID = X.entry("statusline", "A line.", { identifiers: ["status-line"] });

caseBegin("provenance-fields", "bin/lib/glossary-provenance.js");
test("a fields-only change is a redefine op; without an intent row it is not-in-intent", () => {
  const ops = opsOf(userFile(PLAIN), userFile(WITH_ID));
  assert.deepStrictEqual(ops.map((o) => [o.term, o.operation, o.fieldsChanged]), [["statusline", "redefine", true]]);
  assert.deepStrictEqual(reasons(ops, null), [["statusline", "redefine", "not-in-intent"]]);
});
test("V3 redefine row: matching fields pass, other fields are fields-mismatch", () => {
  const ops = opsOf(userFile(PLAIN), userFile(WITH_ID));
  assert.strictEqual(ops.length, 1);
  assert.deepStrictEqual(reasons(ops, X.v3([X.v3Row("statusline", "user", "redefine", "A line.", ["status-line"], [])])), []);
  assert.deepStrictEqual(reasons(ops, X.v3([X.v3Row("statusline", "user", "redefine", "A line.", ["status_line"], [])])),
    [["statusline", "redefine", "fields-mismatch"]]);
});
test("V3 add row: matching fields pass, other fields are fields-mismatch; a Short forms-only change is a redefine",
  () => E.provenanceV3Add({ opsOf, reasons, userFile }));
test("Short forms provenance: redefine op, fields-unrecorded on V2, fields-mismatch on other V3 cells",
  () => S.provenance({ opsOf, reasons, userFile }));
test("V2 rows cannot carry a fields change: fields-unrecorded for redefine and add", () => {
  const redefine = opsOf(userFile(PLAIN), userFile(WITH_ID));
  assert.deepStrictEqual(reasons(redefine, X.v2([X.v2Row("statusline", "user", "redefine", "A line.")])),
    [["statusline", "redefine", "fields-unrecorded"]]);
  const add = opsOf(userFile(), userFile(X.entry("status line", "A line.", { shortForms: ["status"] })));
  assert.deepStrictEqual(add.map((o) => [o.operation, o.fieldsChanged]), [["add", true]]);
  assert.deepStrictEqual(reasons(add, X.v2([X.v2Row("status line", "user", "add", "A line.")])),
    [["status line", "add", "fields-unrecorded"]]);
});
test("V2 redefine of the Definition alone, fields untouched, still passes", () => {
  const ops = opsOf(userFile(WITH_ID), userFile(X.entry("statusline", "A new line.", { identifiers: ["status-line"] })));
  assert.deepStrictEqual(ops.map((o) => [o.operation, o.fieldsChanged]), [["redefine", false]]);
  assert.deepStrictEqual(reasons(ops, X.v2([X.v2Row("statusline", "user", "redefine", "A new line.")])), []);
});
test("opsFingerprint: a fields change moves the fingerprint; an untouched op keeps the old formula", () => {
  const p = load("bin/lib/glossary-provenance.js");
  const base = { term: "statusline", category: "user", operation: "redefine", definition: "A line." };
  const clearing = Object.assign({}, base, { fieldsChanged: true, fields: "" });
  const untouched = Object.assign({}, base, { fieldsChanged: false, fields: "" });
  assert.notStrictEqual(p.opsFingerprint([clearing]), p.opsFingerprint([untouched]));
  const old = crypto.createHash("sha256")
    .update([base.term, base.category, base.operation, base.definition].join("\u0000")).digest("hex");
  assert.strictEqual(p.opsFingerprint([untouched]), old);
});
caseEnd();

caseBegin("provenance-redefine-no-change-fields", "bin/lib/glossary-provenance.js");
test("checkIntentRows: a V3 row is redefine-no-change only when the Definition and the fields match",
  require("./feature-2763-glossary-fields/intent-rows").redefineNoChange);
caseEnd();

caseBegin("intent-rows-digest-fields", "hooks/workflow-state/glossary-check/scope/sources.js");
test("the intent-rows digest moves with the V3 fields; a V2 row keeps the old formula",
  require("./feature-2763-glossary-fields/intent-rows").rowsDigestFields);
caseEnd();

caseBegin("combined-glossary-records", "hooks/workflow-state/glossary-check/scope/sources.js");
test("combinedGlossary returns term records with the declared fields", () => {
  const repo = path.join(TMP, "repo").replace(/\\/g, "/");
  gitInit(repo);
  fs.mkdirSync(path.join(repo, "docs", "glossary"), { recursive: true });
  fs.writeFileSync(path.join(repo, USER), userFile(X.entry("status line", "A line.", { shortForms: ["status"] })));
  fs.writeFileSync(path.join(repo, INTERNAL), X.file("internal", [ALLOW_DENY]));
  const add = spawnSync("git", ["-C", repo, "add", "-A"], { encoding: "utf8" });
  assert.strictEqual(add.status, 0, add.stderr);
  const r = load("hooks/workflow-state/glossary-check/scope/sources.js").combinedGlossary({ repoDir: repo });
  assert.ok(r.ok, JSON.stringify(r));
  const byTerm = (t) => r.terms.filter((x) => x && x.term === t);
  // Short forms are a write-time declaration only: the drift records carry { term, identifiers }.
  assert.deepStrictEqual(byTerm("allow-deny hook"), [{ term: "allow-deny hook", identifiers: ["allow-deny-hook", "allow_deny_hook"] }]);
  assert.deepStrictEqual(byTerm("status line"), [{ term: "status line", identifiers: [] }]);
});
caseEnd();

// Plan S5-1: the reviewer's glossary data carries the two bullets (Related stays out). Kept in this
// JS entrypoint: a bash case may not target a .js file (block-case-markers language gate).
caseBegin("prompt-data-emits-identifier-and-short-forms", "bin/lib/glossary-format/prompt-data.js");
test("promptData emits Identifier and Short forms as written, no Related; a plain entry is unchanged", () => {
  const { promptData } = load("bin/lib/glossary-format/prompt-data.js");
  const withFields = path.join(TMP, "pd-internal.md");
  const plain = path.join(TMP, "pd-user.md");
  fs.writeFileSync(withFields, VALID_FILE);
  fs.writeFileSync(plain, INTERNAL_TEXT);
  const out = promptData([{ label: INTERNAL, file: withFields }, { label: USER, file: plain }], 1000, 100000);
  assert.strictEqual(out, [
    INTERNAL,
    "### allow-deny hook",
    "- **Definition**: A hook.",
    "- **Identifier**: `allow-deny-hook`, `allow_deny_hook`",
    "### status line",
    "- **Definition**: A line.",
    "- **Short forms**: `status`",
    USER,
    "### kilo",
    "- **Definition**: K.",
    "",
  ].join("\n"));
});
test("promptData neutralizes delimiters inside the Identifier and Short forms values", E.promptDataNeutralize);
caseEnd();
