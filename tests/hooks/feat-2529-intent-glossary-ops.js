#!/usr/bin/env node
"use strict";
// Tests: hooks/lib/intent-glossary.js
// Tags: TL1, hooks, lib, glossary, intent, schema, scope:issue-specific
// #2529 T2 — the intent.md `## Glossary` table gains an Operation column
// (`| Term | Category | Operation | Definition |`, Operation = add / delete / redefine).
// The old 3-column table still parses, every row as `add` (legacy: true). checkIntentGlossary
// BLOCKs an out-of-range Operation, a duplicate term+operation, a wrong cell count, a session
// delete/redefine, an empty Definition on add/redefine, and a same-category delete + add pair
// (`use-redefine`); a category move, a single redefine, a rename and an empty-definition
// delete pass.

const { caseBegin, caseEnd } = require("../lib/harness");
const path = require("path");
const { after, test } = require("node:test");
const { noNewFailures } = require("../lib/case-verdict");

const ROOT = path.resolve(__dirname, "..", "..");
const totals = { passed: 0, failed: 0 };
const failureCount = () => totals.failed;
after(() => process.stdout.write(`Total: ${totals.passed} passed, ${totals.failed} failed\n`));

function check(name, fn) {
  try {
    fn();
    totals.passed++;
    process.stdout.write(`PASS: ${name}\n`);
  } catch (e) {
    totals.failed++;
    process.stdout.write(`FAIL: ${name} — ${e && e.message ? e.message : e}\n`);
  }
}
function eq(actual, expected, label) {
  const a = JSON.stringify(actual);
  const b = JSON.stringify(expected);
  if (a !== b) throw new Error(`${label}: expected ${b}, got ${a}`);
}
function ok(cond, label) { if (!cond) throw new Error(label); }
function lib() { return require(path.join(ROOT, "hooks/lib/intent-glossary.js")); }

const V1_HEADER = "| Term | Category | Definition |\n|---|---|---|\n";
const V2_HEADER = "| Term | Category | Operation | Definition |\n|---|---|---|---|\n";
// Line number of the first table row in doc(): # Intent, blank, ## Issues, blank, - #1, blank,
// ## Glossary, blank, header, separator -> the first row is line 11.
const FIRST_ROW = 11;

function doc(table) {
  return `# Intent\n\n## Issues\n\n- #1 fixture\n\n## Glossary\n\n${table}\n## Goal\n\nx\n`;
}
function v2(rows) { return doc(V2_HEADER + rows.map((r) => `| ${r.join(" | ")} |`).join("\n") + "\n"); }
function blocks(text) { return lib().checkIntentGlossary(text); }
function show(v) { return JSON.stringify(v.map((x) => `${x.lineNumber}:${x.reason}`)); }
function blockedAt(text, line, re, label) {
  const v = blocks(text);
  ok(v.some((x) => x.lineNumber === line && re.test(x.reason)), `${label}: no ${re} at line ${line} (got ${show(v)})`);
}
function passes(text, label) { const v = blocks(text); eq(v.length, 0, `${label} violations ${show(v)}`); }

// ============================================================================
caseBegin("t2-operations-exported", "hooks/lib/intent-glossary.js");
test("t2-operations-exported", () => noNewFailures(failureCount, () => {
  check("T2 OPERATIONS is exported as [add, delete, redefine]", () => {
    eq(Array.from(lib().OPERATIONS || []), ["add", "delete", "redefine"], "OPERATIONS");
  });
}));
caseEnd();

// ============================================================================
caseBegin("t2-v1-table-reads-as-add", "hooks/lib/intent-glossary.js");
const V1_DOC = doc(V1_HEADER + "| alpha | user | The first term. |\n| scratch | session | A session word. |\n");
test("t2-v1-table-reads-as-add", () => noNewFailures(failureCount, () => {
  check("T2 a V1 3-column table still passes the format check (control)", () => passes(V1_DOC, "V1"));
  check("T2 every V1 row parses as operation add with legacy: true", () => {
    const rows = lib().parseIntentGlossary(V1_DOC).rows;
    eq(rows.map((r) => [r.term, r.category, r.operation, r.definition, r.legacy]),
      [["alpha", "user", "add", "The first term.", true], ["scratch", "session", "add", "A session word.", true]], "rows");
  });
}));
caseEnd();

// ============================================================================
caseBegin("t2-v2-table-reads-three-operations", "hooks/lib/intent-glossary.js");
const V2_DOC = v2([
  ["beta", "user", "add", "A new term."],
  ["omega", "user", "delete", ""],
  ["alpha", "internal", "redefine", "A sharper definition."],
]);
test("t2-v2-table-reads-three-operations", () => noNewFailures(failureCount, () => {
  check("T2 a V2 table with add / delete (empty Definition) / redefine passes", () => passes(V2_DOC, "V2"));
  check("T2 V2 rows parse term / category / operation / definition, not legacy", () => {
    const rows = lib().parseIntentGlossary(V2_DOC).rows;
    eq(rows.map((r) => [r.term, r.category, r.operation, r.definition, r.cellCount, r.lineNumber]), [
      ["beta", "user", "add", "A new term.", 4, FIRST_ROW],
      ["omega", "user", "delete", "", 4, FIRST_ROW + 1],
      ["alpha", "internal", "redefine", "A sharper definition.", 4, FIRST_ROW + 2],
    ], "rows");
    ok(rows.every((r) => !r.legacy), `legacy flags: ${JSON.stringify(rows.map((r) => r.legacy))}`);
  });
}));
caseEnd();

// ============================================================================
caseBegin("t2-row-blocks", "hooks/lib/intent-glossary.js");
// expected: { line, re } = blockedAt at that line; { anyRe } = some violation matches; "pass" = no violation.
const blockCases = [
  { group: "T2 an Operation outside add / delete / redefine is a BLOCK", name: "rename",
    input: v2([["beta", "user", "rename", "A new term."]]), expected: { line: FIRST_ROW, re: /Operation/ } },
  { group: "T2 an Operation outside add / delete / redefine is a BLOCK", name: "case variant",
    input: v2([["beta", "user", "Add", "A new term."]]), expected: { line: FIRST_ROW, re: /Operation/ } },
  { group: "T2 an Operation outside add / delete / redefine is a BLOCK", name: "empty",
    input: v2([["beta", "user", "", "A new term."]]), expected: { line: FIRST_ROW, re: /Operation/ } },
  { group: "T2 the same term with the same operation twice is a BLOCK (case-insensitive)", name: "add twice",
    input: v2([["beta", "user", "add", "One."], ["Beta", "internal", "add", "Two."]]), expected: { line: FIRST_ROW + 1, re: /duplicate/i } },
  { group: "T2 a same-category delete + add pair is a BLOCK naming use-redefine", name: "delete-first",
    input: v2([["alpha", "user", "delete", ""], ["alpha", "user", "add", "A rewritten definition."]]), expected: { anyRe: /use-redefine/ } },
  { group: "T2 a same-category delete + add pair is a BLOCK naming use-redefine", name: "add-first",
    input: v2([["alpha", "user", "add", "A rewritten definition."], ["alpha", "user", "delete", ""]]), expected: { anyRe: /use-redefine/ } },
  { group: "T2 a row whose cell count does not match the header is a BLOCK", name: "3 cells in a V2 table",
    input: v2([["beta", "user", "A new term."]]), expected: { line: FIRST_ROW, re: /cell/ } },
  { group: "T2 a row whose cell count does not match the header is a BLOCK", name: "5 cells in a V2 table",
    input: v2([["beta", "user", "add", "A new term.", "extra"]]), expected: { line: FIRST_ROW, re: /cell/ } },
  { group: "T2 a row whose cell count does not match the header is a BLOCK", name: "4 cells in a V1 table",
    input: doc(V1_HEADER + "| beta | user | add | A new term. |\n"), expected: { line: FIRST_ROW, re: /cell/ } },
  { group: "T2 a session-category delete or redefine is a BLOCK; session add passes", name: "session delete",
    input: v2([["scratch", "session", "delete", ""]]), expected: { line: FIRST_ROW, re: /session/ } },
  { group: "T2 a session-category delete or redefine is a BLOCK; session add passes", name: "session redefine",
    input: v2([["scratch", "session", "redefine", "Another meaning."]]), expected: { line: FIRST_ROW, re: /session/ } },
  { group: "T2 a session-category delete or redefine is a BLOCK; session add passes", name: "session add",
    input: v2([["scratch", "session", "add", "A session word."]]), expected: "pass" },
  { group: "T2 an empty Definition on add or redefine is a BLOCK", name: "add",
    input: v2([["beta", "user", "add", ""]]), expected: { line: FIRST_ROW, re: /Definition/ } },
  { group: "T2 an empty Definition on add or redefine is a BLOCK", name: "redefine",
    input: v2([["alpha", "user", "redefine", ""]]), expected: { line: FIRST_ROW, re: /Definition/ } },
];
function judgeCase(c) {
  if (c.expected === "pass") return passes(c.input, c.name);
  if (c.expected.anyRe) {
    const v = blocks(c.input);
    return ok(v.some((x) => c.expected.anyRe.test(x.reason)), `${c.name} violations ${show(v)}`);
  }
  return blockedAt(c.input, c.expected.line, c.expected.re, c.name);
}
test("t2-row-blocks", () => noNewFailures(failureCount, () => {
  for (const c of blockCases) check(`${c.group} [${c.name}]`, () => judgeCase(c));
}));
caseEnd();

// ============================================================================
caseBegin("t2-row-passes", "hooks/lib/intent-glossary.js");
const passCases = [
  { group: "T2 a category move (delete and add in different categories) passes", name: "move",
    input: v2([["omega", "user", "delete", ""], ["omega", "internal", "add", "The last term."]]), expected: "pass" },
  { group: "T2 a single same-category redefine passes", name: "redefine",
    input: v2([["alpha", "user", "redefine", "A rewritten definition."]]), expected: "pass" },
  { group: "T2 a rename (delete one term, add another) passes", name: "rename",
    input: v2([["old name", "user", "delete", ""], ["new name", "user", "add", "The renamed term."]]), expected: "pass" },
  { group: "T2 the same term under different operations is not a duplicate", name: "delete+add across categories",
    input: v2([["omega", "user", "delete", ""], ["omega", "internal", "add", "Moved."]]), expected: "pass" },
];
test("t2-row-passes", () => noNewFailures(failureCount, () => {
  for (const c of passCases) check(`${c.group} [${c.name}]`, () => judgeCase(c));
}));
caseEnd();

// ============================================================================
// #2529 C2 inflow: a Term holding a shell-active character never reaches a copyable command.
// A `|` inside a cell is written escaped (`\|`); splitRow unescapes it into the Term.
caseBegin("t2-term-forbidden-character", "hooks/lib/intent-glossary.js");
const FORBIDDEN_GROUP = "T2 a Term with a forbidden character is a BLOCK";
const termCases = [
  ["$(x)", "bad$(x)term"], ["backtick", "bad`x`term"], ["double quote", "bad\"term"], ["backslash", "bad\\term"],
  ["semicolon", "bad;term"], ["pipe", "bad\\|term"], ["ampersand", "bad&term"], ["equals", "bad=term"],
  ["less-than", "bad<term"], ["greater-than", "bad>term"],
].map(([name, cell]) => ({ group: FORBIDDEN_GROUP, name,
  input: v2([[cell, "user", "add", "A hostile term."]]), expected: { line: FIRST_ROW, re: /forbidden character/ } }))
  .concat([{ group: FORBIDDEN_GROUP, name: "safe term (control)",
    input: v2([["user's glossary-term_2", "user", "add", "A safe term."]]), expected: "pass" }]);
test("t2-term-forbidden-character", () => noNewFailures(failureCount, () => {
  for (const c of termCases) check(`${c.group} [${c.name}]`, () => judgeCase(c));
}));
caseEnd();
