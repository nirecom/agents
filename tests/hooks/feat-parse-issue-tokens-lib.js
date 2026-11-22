"use strict";
// tests/hooks/feat-parse-issue-tokens-lib.js
// Tests: hooks/lib/parse-closes-issues.js
// Tags: TL1, TL2, scope:common, issue-tokens, parse, issue-2942
// #299: the token-splitting rule of bin/parse-issue-tokens moves into parseIssueTokens(text) in
// hooks/lib/parse-closes-issues.js; the CLI only calls it, so both answer the same for one table.

// TL3 gap: the real VS Code / Claude app title rendering is not observed; only the parsing the
// title hook relies on is checked here.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const assert = require("node:assert");
const { test, after } = require("node:test");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const restore = isolate();
after(() => restore());
const ROOT = path.resolve(__dirname, "..", "..");
const CLI = path.join(ROOT, "bin", "parse-issue-tokens");

// [label, input text, expected tokens]
const TABLE = [
  ["local", "#12", [{ number: 12 }]],
  ["short cross-repo", "repo#5", [{ number: 5, repo: "repo" }]],
  ["full cross-repo", "owner/repo#7", [{ number: 7, repo: "owner/repo" }]],
  ["mixed separators keep order", "#1, other#2\nowner/r#3  #4", [{ number: 1 }, { number: 2, repo: "other" }, { number: 3, repo: "owner/r" }, { number: 4 }]],
  ["junk is dropped", "please fix 3.2 42 # #x abc #9", [{ number: 9 }]],
  ["empty text", "", []],
  ["no hash at all", "fix the thing", []],
];

const show = (v) => JSON.stringify(v);
function parseIssueTokens() {
  const fn = require(path.join(ROOT, "hooks", "lib", "parse-closes-issues.js")).parseIssueTokens;
  assert.strictEqual(typeof fn, "function", "parseIssueTokens is not exported as a function");
  return fn;
}

caseBegin("cli-baseline-token-table", "hooks/lib/parse-closes-issues.js");
for (const [label, text, want] of TABLE) {
  test(`CLI baseline ${label}`, () => {
    const r = spawnSync(process.execPath, [CLI, text], { encoding: "utf8", timeout: 30000 });
    assert.strictEqual(r.status, 0, `status=${r.status} err=${r.stderr}`);
    assert.strictEqual((r.stdout || "").trim(), show(want));
  });
}
caseEnd();

caseBegin("lib-parse-issue-tokens-matches-cli-table", "hooks/lib/parse-closes-issues.js");
test("parseIssueTokens is exported as a function", () => parseIssueTokens());
for (const [label, text, want] of TABLE) {
  test(`lib ${label}`, () => assert.strictEqual(show(parseIssueTokens()(text)), show(want)));
}
caseEnd();

// #2942: a CLI flag named --issue also takes a bare N (`#` starts a shell comment); free text stays strict.
const LIB = () => require(path.join(ROOT, "hooks", "lib", "parse-closes-issues.js"));
function parseIssueFlagValue() {
  const fn = LIB().parseIssueFlagValue;
  assert.strictEqual(typeof fn, "function", "parseIssueFlagValue is not exported as a function");
  return fn;
}
// [label, flag value, expected ref or null]
const FLAG_TABLE = [
  ["bare N", "3127", { number: 3127 }],
  ["bare N with spaces is trimmed", " 42 ", { number: 42 }],
  ["#N", "#3127", { number: 3127 }],
  ["owner/repo#N", "nirecom/agents#3127", { number: 3127, repo: "nirecom/agents" }],
  ["repo#N", "agents#5", { number: 5, repo: "agents" }],
  ["zero", "0", null],
  ["leading zero", "007", null],
  ["negative", "-1", null],
  ["decimal", "3.2", null],
  ["digits then letters", "12abc", null],
  ["empty string", "", null],
  ["undefined", undefined, null],
  ["hash only", "#", null],
  ["word", "abc", null],
  ["#N with spaces is trimmed", " #12 ", { number: 12 }],
  ["#zero", "#0", null],
  ["#leading zero", "#007", null],
  ["#decimal", "#3.2", null],
  ["#digits then letters", "#12abc", null],
  ["owner/repo#zero", "o/r#0", null],
  ["owner/repo#decimal", "o/r#3.2", null],
  ["repo#digits then letters", "repo#12x", null],
  ["number", 42, null],
  ["null", null, null],
  ["three-part slug", "a/b/c#1", null],
  ["double hash", "##12", null],
];

caseBegin("parse-issue-flag-value-table", "hooks/lib/parse-closes-issues.js");
test("parseIssueFlagValue is exported as a function", () => parseIssueFlagValue());
for (const [label, value, want] of FLAG_TABLE) {
  test(`flag value ${label} (${show(value)}) -> ${show(want)}`, () => assert.deepStrictEqual(parseIssueFlagValue()(value), want, label));
}
caseEnd();

caseBegin("parse-issue-token-stays-strict", "hooks/lib/parse-closes-issues.js");
for (const [label, value] of [["bare N", "3127"], ["bare N with spaces", " 42 "]]) {
  test(`parseIssueToken still rejects ${label}`, () => {
    assert.strictEqual(LIB().parseIssueToken(value), null, label);
    assert.strictEqual(LIB().ISSUE_TOKEN_CLI_GUARD_RE.test(value.trim()), false, label);
  });
}
test("parseIssueTokens free text keeps only #-carrying words", () => {
  assert.strictEqual(show(LIB().parseIssueTokens("fix 3127 and #12")), show([{ number: 12 }]));
});
caseEnd();
