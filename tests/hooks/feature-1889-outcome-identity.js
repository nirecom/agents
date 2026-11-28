"use strict";
// Tests: hooks/lib/issue-identity.js, hooks/lib/final-report-schema.js, bin/render-final-report.js
// Tags: feature-1889, feature-3043, final-report, issue-identity, outcome, scope:issue-specific, TL1, TL2, pwsh-not-required
// #1889 / #3043: an outcome entry's identity is (issueNumber, repo normalized by the bag's homeRepo).
// The pure functions of hooks/lib/issue-identity.js are table-driven (TL1); renderFinalReport takes
// homeRepo as an input and lists only closed-state entries (TL1); the real renderer CLI reads the
// bag's homeRepo (TL2). A module the change has not landed yet fails its own case as NOT YET IMPLEMENTED.
// TL3 gap: a live /session-close run whose outcome bag was written by a real finalize against GitHub.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { after, test } = require("node:test");
const F = require("../lib/worktree-leftover-fixture");
const G = require("../lib/final-report-guard-fixture");

const ID_PATH = "hooks/lib/issue-identity.js";
const id = (name) => F.need(ID_PATH, name);
const S = require(F.rel("hooks/lib/final-report-schema.js"));
const TOKEN_RE = /<[A-Z][A-Z0-9_]+>/;
const NOT_RECORDED = "- (not recorded yet — /session-close writes issue outcomes)";

const restoreIsolation = isolate();
const SB = F.makeBase("f1889-");
after(() => {
  restoreIsolation();
  fs.rmSync(SB, { recursive: true, force: true });
});

const entry = (n, state, extra) => Object.assign({ issueNumber: n, state, historyEntry: true, issueClosed: true,
  sentinelsPosted: true, wipCleared: true }, extra || {});
const NOTES = { bugs: "- (none)", related: "- (none)", next: "- (none)" };
const render = (outcome, extra) => S.renderFinalReport("s1889", Object.assign({
  env: {}, outcome, closesIssues: [], notesSections: NOTES, supervisorState: null }, extra || {}));

// region(report, heading) -> the non-blank lines under heading, up to the next ### heading.
function region(report, heading) {
  const lines = String(report).split("\n");
  const start = lines.indexOf(heading);
  assert.ok(start >= 0, `heading ${heading} present:\n${report}`);
  const rest = lines.slice(start + 1);
  const end = rest.findIndex((l) => l.startsWith("### ") || l.startsWith("## "));
  return (end < 0 ? rest : rest.slice(0, end)).filter((l) => l.trim() !== "");
}
const closedList = (r) => region(r, "### Closed Issues");
const outcomeLines = (r) => region(r, "### Closed Issue Outcomes");

caseBegin("normalize-home-accepts-only-owner-repo", "hooks/lib/issue-identity.js");
test("normalize-home-accepts-only-owner-repo", () => {
  const normalizeHome = id("normalizeHome");
  const cases = [
    { name: "owner/repo kept", input: "o/r", want: "o/r" },
    { name: "letter case kept", input: "Owner/Repo", want: "Owner/Repo" },
    { name: "empty string", input: "", want: "" },
    { name: "undefined", input: undefined, want: "" },
    { name: "null", input: null, want: "" },
    { name: "number", input: 42, want: "" },
    { name: "repo without owner", input: "repo", want: "" },
    { name: "three segments", input: "o/r/x", want: "" },
    { name: "empty owner", input: "/r", want: "" },
    { name: "empty repo", input: "o/", want: "" },
    { name: "embedded newline", input: "o/r\nx", want: "" },
    { name: "placeholder token", input: "<OWNER_REPO>", want: "" },
  ];
  for (const { name, input, want } of cases) {
    assert.strictEqual(normalizeHome(input), want, `${name}: normalizeHome(${JSON.stringify(input)})`);
  }
});
caseEnd();

caseBegin("outcome-ref-and-key-table", "hooks/lib/issue-identity.js");
test("outcome-ref-and-key-table", () => {
  const outcomeRef = id("outcomeRef");
  const outcomeKey = id("outcomeKey");
  assert.deepStrictEqual(outcomeRef({ issueNumber: 42 }), { number: 42 });
  assert.deepStrictEqual(outcomeRef({ issueNumber: 42, issueRepo: "o/r" }), { number: 42, repo: "o/r" });
  const rows = [
    [{ issueNumber: 42 }, "o/r", "o/r#42", "no issueRepo, home known: the home repo"],
    [{ issueNumber: 42 }, "", "#42", "no issueRepo, no home: bare"],
    [{ issueNumber: 42 }, undefined, "#42", "no issueRepo, home undefined: bare, no throw"],
    [{ issueNumber: 42, issueRepo: "o/r" }, "o/r", "o/r#42", "issueRepo equal to home"],
    [{ issueNumber: 42, issueRepo: "O/R" }, "o/r", "o/r#42", "letter case is ignored"],
    [{ issueNumber: 42, issueRepo: "x" }, "o/r", "o/x#42", "r#N shorthand resolves to the home owner"],
    [{ issueNumber: 42, issueRepo: "a/b" }, "o/r", "a/b#42", "another repo keeps its own repo"],
    [{ issueNumber: 42, issueRepo: "o/r" }, "", "o/r#42", "no home: matched as written"],
  ];
  for (const [e, home, want, why] of rows) assert.strictEqual(outcomeKey(e, home), want, why);
  assert.notStrictEqual(outcomeKey({ issueNumber: 42 }, ""), outcomeKey({ issueNumber: 42, issueRepo: "o/r" }, ""),
    "without a home, #42 and o/r#42 are different keys (D1 degraded form)");
  assert.strictEqual(outcomeKey({ issueNumber: 42 }, "o/r"), outcomeKey({ issueNumber: 42, issueRepo: "o/r" }, "o/r"),
    "with home o/r, #42 and o/r#42 are the same key");
});
caseEnd();

caseBegin("outcome-label-table", "hooks/lib/issue-identity.js");
test("outcome-label-table", () => {
  const outcomeLabel = id("outcomeLabel");
  const rows = [
    [{ issueNumber: 42 }, "o/r", "#42"],
    [{ issueNumber: 42, issueRepo: "o/r" }, "o/r", "#42"],
    [{ issueNumber: 42, issueRepo: "O/R" }, "o/r", "#42"],
    [{ issueNumber: 42, issueRepo: "a/b" }, "o/r", "a/b#42"],
    [{ issueNumber: 42 }, "", "#42"],
    [{ issueNumber: 42, issueRepo: "a/b" }, "", "a/b#42"],
  ];
  for (const [e, home, want] of rows) assert.strictEqual(outcomeLabel(e, home), want, `${JSON.stringify(e)} home=${home}`);
});
caseEnd();

caseBegin("is-valid-outcome-entry-both-verdicts", "hooks/lib/issue-identity.js");
test("is-valid-outcome-entry-both-verdicts", () => {
  const isValid = id("isValidOutcomeEntry");
  const cases = [
    { name: "local number", input: { issueNumber: 42 }, want: true },
    { name: "owner/repo", input: { issueNumber: 42, issueRepo: "o/r" }, want: true },
    { name: "short repo", input: { issueNumber: 1, issueRepo: "r" }, want: true },
    { name: "full writer entry", input: entry(7, "succeeded"), want: true },
    { name: "null", input: null, want: false },
    { name: "undefined", input: undefined, want: false },
    { name: "string", input: "x", want: false },
    { name: "number", input: 42, want: false },
    { name: "empty object", input: {}, want: false },
    { name: "string issueNumber", input: { issueNumber: "42" }, want: false },
    { name: "zero issueNumber", input: { issueNumber: 0 }, want: false },
    { name: "negative issueNumber", input: { issueNumber: -1 }, want: false },
    { name: "fractional issueNumber", input: { issueNumber: 1.5 }, want: false },
    { name: "empty issueRepo", input: { issueNumber: 42, issueRepo: "" }, want: false },
    { name: "numeric issueRepo", input: { issueNumber: 42, issueRepo: 5 }, want: false },
    { name: "three-segment issueRepo", input: { issueNumber: 42, issueRepo: "o/r/x" }, want: false },
    { name: "newline in issueRepo", input: { issueNumber: 42, issueRepo: "o/r\nx" }, want: false },
    { name: "token issueRepo", input: { issueNumber: 42, issueRepo: "<TOKEN>" }, want: false },
    { name: "space in issueRepo", input: { issueNumber: 42, issueRepo: "o r/x" }, want: false },
  ];
  for (const { name, input, want } of cases) {
    assert.strictEqual(isValid(input), want, `${name}: isValidOutcomeEntry(${JSON.stringify(input)})`);
  }
});
caseEnd();

caseBegin("closed-states-frozen", "hooks/lib/issue-identity.js");
test("closed-states-frozen", () => {
  const CLOSED = id("CLOSED_STATES");
  assert.deepStrictEqual(Array.from(CLOSED), ["succeeded", "subsumed", "already_closed"]);
  assert.ok(Object.isFrozen(CLOSED), "CLOSED_STATES is frozen");
});
caseEnd();

caseBegin("pm-session-schema-reexports-identity", "hooks/lib/issue-identity.js");
test("pm-session-schema-reexports-identity", () => {
  const pm = require(F.rel("hooks/pm-session/schema.js"));
  for (const name of ["resolveRepo", "repoOf", "sameIssue", "toRef", "refLabel"]) {
    assert.strictEqual(pm[name], id(name), `hooks/pm-session/schema.js re-exports ${name} from ${ID_PATH}`);
  }
  assert.strictEqual(pm.resolveRepo({ number: 1, repo: "x" }, "o/r"), "o/x", "behavior unchanged");
  assert.strictEqual(pm.resolveRepo({ number: 1 }, ""), "", "no throw without a home");
});
caseEnd();

caseBegin("render-distinct-repos-stay-separate", "hooks/lib/final-report-schema.js");
test("render-distinct-repos-stay-separate", () => {
  const r = render({ issues: [entry(42, "succeeded", { issueRepo: "a/b" }), entry(42, "succeeded", { issueRepo: "c/d" })] },
    { homeRepo: "o/r" });
  assert.deepStrictEqual(closedList(r), ["- a/b#42", "- c/d#42"], r);
  const out = outcomeLines(r);
  assert.strictEqual(out.length, 2, out.join("\n"));
  assert.ok(out[0].startsWith("- a/b#42: succeeded"), out[0]);
  assert.ok(out[1].startsWith("- c/d#42: succeeded"), out[1]);
});
caseEnd();

caseBegin("render-mixed-bare-and-home-ref-is-one-entry-last-wins", "hooks/lib/final-report-schema.js");
test("render-mixed-bare-and-home-ref-is-one-entry-last-wins", () => {
  const r = render({ homeRepo: "o/r", issues: [entry(42, "failed"), entry(42, "succeeded", { issueRepo: "o/r" })] },
    { homeRepo: "o/r" });
  assert.deepStrictEqual(closedList(r), ["- #42"], r);
  const out = outcomeLines(r);
  assert.strictEqual(out.length, 1, `one Outcomes line for the one key:\n${out.join("\n")}`);
  assert.ok(out[0].startsWith("- #42: succeeded"), `the last entry wins: ${out[0]}`);
});
caseEnd();

caseBegin("render-without-home-keeps-bare-and-repo-ref-apart", "hooks/lib/final-report-schema.js");
test("render-without-home-keeps-bare-and-repo-ref-apart", () => {
  const r = render({ issues: [entry(42, "succeeded"), entry(42, "succeeded", { issueRepo: "o/r" })] });
  assert.deepStrictEqual(closedList(r), ["- #42", "- o/r#42"], r);
  assert.strictEqual(outcomeLines(r).length, 2, r);
});
caseEnd();

caseBegin("render-malformed-entries-skipped-with-count", "hooks/lib/final-report-schema.js");
test("render-malformed-entries-skipped-with-count", () => {
  const r = render({ issues: [entry("7", "succeeded"), entry(0, "succeeded"), entry(8, "succeeded", { issueRepo: "" }),
    entry(9, "succeeded")] }, { homeRepo: "o/r" });
  const out = outcomeLines(r);
  assert.ok(out.includes("- (3 malformed outcome entries skipped)"), out.join("\n"));
  assert.ok(out.some((l) => l.startsWith("- #9: succeeded")), out.join("\n"));
  assert.ok(!/#7\b|#0\b|#8\b|#undefined/.test(out.join("\n")), `no malformed entry is rendered:\n${out.join("\n")}`);
  assert.deepStrictEqual(closedList(r), ["- #9"], r);
});
caseEnd();

caseBegin("render-null-and-numberless-entries-skipped-rendering-continues", "hooks/lib/final-report-schema.js");
test("render-null-and-numberless-entries-skipped-rendering-continues", () => {
  const numberless = entry(1, "succeeded"); delete numberless.issueNumber;
  let r;
  assert.doesNotThrow(() => {
    r = render({ issues: [entry(11, "succeeded"), null, numberless, entry(12, "failed")] }, { homeRepo: "o/r" });
  }, "a null or issueNumber-less entry never aborts rendering");
  const out = outcomeLines(r);
  assert.ok(out.includes("- (2 malformed outcome entries skipped)"), out.join("\n"));
  assert.ok(out.some((l) => l.startsWith("- #11: succeeded")), `valid entry before the bad ones renders:\n${out.join("\n")}`);
  assert.ok(out.some((l) => l.startsWith("- #12: failed")), `valid entry after the bad ones renders:\n${out.join("\n")}`);
  assert.ok(!/#undefined|#null/.test(r), `no malformed entry is rendered:\n${r}`);
  assert.deepStrictEqual(closedList(r), ["- #11"], r);
});
caseEnd();

caseBegin("render-injected-issue-repo-is-malformed", "hooks/lib/final-report-schema.js");
test("render-injected-issue-repo-is-malformed", () => {
  const r = render({ issues: [entry(5, "succeeded", { issueRepo: "o/r\n### Fake Heading" }),
    entry(6, "succeeded", { issueRepo: "<TOKEN>" }), entry(10, "succeeded")] }, { homeRepo: "o/r" });
  assert.ok(!r.includes("### Fake Heading"), "a newline in issueRepo never opens a heading");
  assert.ok(!r.includes("<TOKEN>"), "a <TOKEN> in issueRepo never reaches the report");
  assert.ok(outcomeLines(r).includes("- (2 malformed outcome entries skipped)"), r);
  assert.deepStrictEqual(closedList(r), ["- #10"], r);
});
caseEnd();

caseBegin("render-closed-list-counts-only-closed-states", "hooks/lib/final-report-schema.js");
test("render-closed-list-counts-only-closed-states", () => {
  const r = render({ issues: [entry(1, "succeeded"), entry(2, "subsumed"), entry(3, "already_closed"),
    entry(4, "skipped_wf_meta"), entry(5, "failed")] }, { homeRepo: "o/r" });
  assert.deepStrictEqual(closedList(r), ["- #1", "- #2", "- #3"], r);
  const out = outcomeLines(r).join("\n");
  assert.match(out, /^- #4: /m, "skipped_wf_meta stays in Outcomes");
  assert.match(out, /^- #5: failed/m, "failed stays in Outcomes with its state");
});
caseEnd();

caseBegin("render-closes-issues-without-outcome-not-listed", "hooks/lib/final-report-schema.js");
test("render-closes-issues-without-outcome-not-listed", () => {
  const r = render({ issues: [entry(1, "succeeded")] }, { homeRepo: "o/r", closesIssues: [77] });
  assert.deepStrictEqual(closedList(r), ["- #1"], r);
  assert.ok(!r.includes("#77"), "a closes_issues number with no outcome entry is not reported as closed");
});
caseEnd();

caseBegin("render-no-outcome-reads-not-recorded-yet", "hooks/lib/final-report-schema.js");
test("render-no-outcome-reads-not-recorded-yet", () => {
  for (const outcome of [null, undefined]) {
    const r = render(outcome, { closesIssues: [3043] });
    assert.deepStrictEqual(outcomeLines(r), [NOT_RECORDED], r);
    assert.ok(!TOKEN_RE.test(NOT_RECORDED), "the wording never matches the stop guard token regex");
    assert.ok(!closedList(r).some((l) => /#\d/.test(l)), `nothing is listed as closed:\n${closedList(r).join("\n")}`);
  }
});
caseEnd();

// The real CLI: --session reads <sid>.control/issue-close-outcome.json and passes its homeRepo.
function renderCli(sid, outcome) {
  G.writeEnv(sid);
  G.writeControl(sid, "issue-close-outcome.json", outcome);
  return G.runRenderer(sid, SB);
}

caseBegin("cli-reads-outcome-home-repo", "bin/render-final-report.js");
test("cli-reads-outcome-home-repo", () => {
  const r = renderCli("c1889-home", { homeRepo: "o/r", issues: [entry(42, "succeeded"),
    entry(42, "succeeded", { issueRepo: "o/r" }), entry(43, "succeeded", { issueRepo: "a/b" })] });
  assert.strictEqual(r.rc, 0, r.err);
  assert.deepStrictEqual(closedList(r.out), ["- #42", "- a/b#43"], r.out);
});
caseEnd();

caseBegin("cli-invalid-home-repo-is-not-used", "bin/render-final-report.js");
test("cli-invalid-home-repo-is-not-used", () => {
  const r = renderCli("c1889-badhome", { homeRepo: "not a repo", issues: [entry(42, "succeeded"),
    entry(42, "succeeded", { issueRepo: "o/r" })] });
  assert.strictEqual(r.rc, 0, r.err);
  assert.deepStrictEqual(closedList(r.out), ["- #42", "- o/r#42"], `an invalid homeRepo does not normalize:\n${r.out}`);
});
caseEnd();

caseBegin("cli-old-bag-without-home-repo-renders", "bin/render-final-report.js");
test("cli-old-bag-without-home-repo-renders", () => {
  const r = renderCli("c1889-old", { issues: [entry(42, "succeeded"), entry(44, "failed")] });
  assert.strictEqual(r.rc, 0, r.err);
  assert.deepStrictEqual(closedList(r.out), ["- #42"], r.out);
  assert.match(outcomeLines(r.out).join("\n"), /^- #44: failed/m);
});
caseEnd();
