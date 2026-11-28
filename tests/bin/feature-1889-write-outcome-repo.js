"use strict";
// tests/bin/feature-1889-write-outcome-repo.js
// Tests: bin/issue-close-write-outcome.js, bin/lib/issue-state.js
// Tags: feature-1889, feature-3043, issue-close-finalize, outcome, issue-identity, gh-stub, scope:issue-specific, TL2, pwsh-not-required
// #1889 / #3043: the --session-id writer keys entries by (repo, N), stores the primary's repo and
// the bag's homeRepo, and adds an intent sibling as subsumed only when gh reports it CLOSED.
// TL3 gap: a real `gh issue view` against GitHub (auth, rate limits, a transferred issue) is
// not exercised; gh is a node-binary stub on PATH that answers per issue from GH_STUB_MAP.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const F = require("../lib/worktree-leftover-fixture");

const WRITE = F.rel("bin/issue-close-write-outcome.js");
const HOME_UNKNOWN = "issue-close-write-outcome: home repo unknown; #N and owner/repo#N are matched as written";
const { makeGhStub } = require("../lib/gh-state-stub");

const restore = isolate();
const BASE = F.makeBase("f1889wo-");
process.on("exit", () => { restore(); fs.rmSync(BASE, { recursive: true, force: true }); });
const PLANS = process.env.WORKFLOW_PLANS_DIR;
const GH = makeGhStub(path.join(BASE, "stub"));
const ghEnv = GH.env;
const ghCalls = GH.calls;

function writeIntent(sid, refs) {
  fs.writeFileSync(path.join(PLANS, `${sid}-intent.md`), `# Intent\n\n## Issues\n${refs.map((r) => `- ${r}`).join("\n")}\n`);
}
const outFile = (name) => path.join(BASE, `${name}.json`);
const STATES = ["succeeded", "written_by_step_6h", "succeeded", "succeeded", "succeeded"];
// session(sid, file, flags, N, env) — one --session-id write; flags go between --out-file and <N>.
const session = (sid, file, flags, n, env) =>
  F.runNode([WRITE, "--session-id", sid, "--out-file", file, ...flags, String(n), ...STATES], { cwd: BASE, env, timeout: 60000 });
function bag(file) {
  try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch (_) { return { issues: [] }; }
}
const entries = (b, n) => (b.issues || []).filter((e) => e && e.issueNumber === n);
const show = (r, file) => `rc=${r.rc} err=${r.err.trim()} bag=${JSON.stringify(bag(file))}`;

caseBegin("session-mode-stores-issue-repo-and-home-repo", "bin/issue-close-write-outcome.js");
test("--issue-repo lands on the primary entry, --owner-repo becomes the bag homeRepo", () => {
  const f = outFile("t1"); const env = ghEnv({});
  const r = session("s1889a", f, ["--issue-repo", "a/b", "--owner-repo", "o/r"], 42, env);
  assert.equal(r.rc, 0, show(r, f));
  const b = bag(f);
  assert.equal(b.homeRepo, "o/r", show(r, f));
  const e = entries(b, 42);
  assert.equal(e.length, 1, show(r, f));
  assert.equal(e[0].issueRepo, "a/b");
  assert.equal(e[0].state, "succeeded");
});
caseEnd();

caseBegin("session-mode-without-home-warns-and-writes", "bin/issue-close-write-outcome.js");
test("a missing or malformed --owner-repo prints the home-unknown line once and still writes", () => {
  for (const flags of [[], ["--owner-repo", "not-a-repo"]]) {
    const f = outFile(`t2-${flags.length}`); const env = ghEnv({});
    const r = session("s1889b", f, flags, 42, env);
    assert.equal(r.rc, 0, show(r, f));
    assert.equal(r.err.split(/\r?\n/).filter((l) => l === HOME_UNKNOWN).length, 1, show(r, f));
    assert.ok(!bag(f).homeRepo, `homeRepo must read as empty: ${show(r, f)}`);
    assert.equal(entries(bag(f), 42).length, 1, show(r, f));
  }
});
caseEnd();

caseBegin("upsert-matches-by-composite-key", "bin/issue-close-write-outcome.js");
test("same N in another repo is a separate entry; the home repo spelled out replaces the bare one", () => {
  const f = outFile("t3"); const env = ghEnv({});
  for (const flags of [["--issue-repo", "a/b"], [], ["--issue-repo", "O/R"]]) {
    const r = session("s1889c", f, [...flags, "--owner-repo", "o/r"], 42, env);
    assert.equal(r.rc, 0, show(r, f));
  }
  const e = entries(bag(f), 42);
  assert.equal(e.length, 2, `a/b#42 and o/r#42 expected: ${JSON.stringify(e)}`);
  assert.deepEqual(e.map((x) => String(x.issueRepo || "").toLowerCase()).sort(), ["a/b", "o/r"]);
});
caseEnd();

caseBegin("bare-primary-and-home-ref-sibling-are-one-entry", "bin/issue-close-write-outcome.js");
test("primary #42 and intent o/r#42 (gh CLOSED) leave exactly one entry for 42", () => {
  const f = outFile("t4"); const env = ghEnv({ 42: "CLOSED" });
  writeIntent("s1889d", ["o/r#42"]);
  const r = session("s1889d", f, ["--owner-repo", "o/r"], 42, env);
  assert.equal(r.rc, 0, show(r, f));
  const e = entries(bag(f), 42);
  assert.equal(e.length, 1, show(r, f));
  assert.equal(e[0].state, "succeeded", "the primary entry survives, not a subsumed copy");
});
caseEnd();

caseBegin("cross-repo-primary-and-home-sibling-same-n-are-two-entries", "bin/issue-close-write-outcome.js");
test("primary a/b#42 and intent o/r#42 (gh CLOSED) leave both entries", () => {
  const f = outFile("t4b"); const env = ghEnv({ "o/r#42": "CLOSED", 42: "CLOSED" });
  writeIntent("s1889d2", ["o/r#42"]);
  const r = session("s1889d2", f, ["--issue-repo", "a/b", "--owner-repo", "o/r"], 42, env);
  assert.equal(r.rc, 0, show(r, f));
  const e = entries(bag(f), 42);
  assert.equal(e.length, 2, `a/b#42 (primary) and o/r#42 (sibling) expected: ${show(r, f)}`);
  const byRepo = Object.fromEntries(e.map((x) => [String(x.issueRepo || "").toLowerCase(), x.state]));
  assert.equal(byRepo["a/b"], "succeeded", JSON.stringify(e));
  assert.equal(byRepo["o/r"] || byRepo[""], "subsumed", JSON.stringify(e));
});
caseEnd();

caseBegin("sibling-closed-subsumed-open-skipped", "bin/issue-close-write-outcome.js");
test("a CLOSED sibling is written as subsumed, an OPEN sibling gets no entry; re-running adds nothing", () => {
  const f = outFile("t5"); const env = ghEnv({ 702: "CLOSED", 703: "OPEN" });
  writeIntent("s1889e", ["#701", "#702", "#703"]);
  for (let i = 0; i < 2; i++) {
    const r = session("s1889e", f, ["--owner-repo", "o/r"], 701, env);
    assert.equal(r.rc, 0, show(r, f));
  }
  const b = bag(f);
  assert.equal(entries(b, 701).length, 1, JSON.stringify(b));
  assert.equal(entries(b, 702).length, 1, JSON.stringify(b));
  assert.equal(entries(b, 702)[0].state, "subsumed");
  assert.equal(entries(b, 703).length, 0, `OPEN #703 must not be written: ${JSON.stringify(b)}`);
  const asked = ghCalls(env).map((a) => a.find((x) => /^[0-9]+$/.test(x)));
  assert.ok(asked.includes("702") && asked.includes("703"), `gh asked: ${JSON.stringify(ghCalls(env))}`);
  assert.ok(!asked.includes("701"), "the primary is not looked up");
});
caseEnd();

caseBegin("sibling-state-failure-writes-nothing", "bin/issue-close-write-outcome.js");
test("gh failing for a sibling writes no entry and names it on stderr", () => {
  const f = outFile("t6"); const env = ghEnv({ 702: "FAIL" });
  writeIntent("s1889f", ["#701", "#702"]);
  const r = session("s1889f", f, ["--owner-repo", "o/r"], 701, env);
  assert.equal(r.rc, 0, show(r, f));
  assert.equal(entries(bag(f), 702).length, 0, show(r, f));
  assert.ok(r.err.includes("issue-close-write-outcome: state check failed for #702; no entry written"), r.err);
  assert.ok(ghCalls(env).length >= 1, "gh was asked (case is not vacuous)");
});
caseEnd();

caseBegin("cross-repo-sibling-passes-repo-flag", "bin/issue-close-write-outcome.js");
test("an intent x/y#702 sibling is looked up with --repo x/y and keeps its repo", () => {
  const f = outFile("t7"); const env = ghEnv({ "x/y#702": "CLOSED" });
  writeIntent("s1889g", ["#701", "x/y#702"]);
  const r = session("s1889g", f, ["--owner-repo", "o/r"], 701, env);
  assert.equal(r.rc, 0, show(r, f));
  const call = ghCalls(env).find((a) => a.includes("702"));
  assert.ok(call, `gh not asked about 702: ${JSON.stringify(ghCalls(env))}`);
  assert.equal(call[call.indexOf("--repo") + 1], "x/y", JSON.stringify(call));
  const e = entries(bag(f), 702);
  assert.equal(e.length, 1, show(r, f));
  assert.equal(e[0].state, "subsumed");
  assert.equal(String(e[0].issueRepo || "").toLowerCase(), "x/y");
});
caseEnd();

caseBegin("shorthand-sibling-without-home-is-not-looked-up", "bin/issue-close-write-outcome.js");
test("r2#702 without a home repo cannot be resolved: no gh call, no entry, a stderr line", () => {
  const f = outFile("t8"); const env = ghEnv({ 702: "CLOSED" });
  writeIntent("s1889h", ["#701", "r2#702"]);
  const r = session("s1889h", f, [], 701, env);
  assert.equal(r.rc, 0, show(r, f));
  assert.ok(r.err.includes(HOME_UNKNOWN), `home-unknown line expected (case not vacuous): ${r.err}`);
  assert.equal(entries(bag(f), 702).length, 0, show(r, f));
  assert.equal(ghCalls(env).filter((a) => a.includes("702")).length, 0, JSON.stringify(ghCalls(env)));
  assert.ok(/state check failed for \S*702; no entry written/.test(r.err), r.err);
});
caseEnd();

caseBegin("fixed-modes-keep-bag-home-repo", "bin/issue-close-write-outcome.js");
test("--non-github matches by the bag's homeRepo and never rewrites it", () => {
  const f = outFile("t9");
  fs.writeFileSync(f, JSON.stringify({ homeRepo: "o/r", issues: [{ issueNumber: 42, state: "failed", historyEntry: "failed",
    issueClosed: "failed", sentinelsPosted: "failed", wipCleared: "failed" }] }));
  const run = (json) => F.runNode([WRITE, "--non-github", json, f], { cwd: BASE, env: ghEnv({}) });
  let r = run(JSON.stringify([{ number: 42, repo: "x/y" }]));
  assert.equal(r.rc, 0, show(r, f));
  assert.equal(entries(bag(f), 42).length, 2, `x/y#42 is not o/r#42: ${show(r, f)}`);
  r = run(JSON.stringify([{ number: 42, repo: "o/r" }]));
  assert.equal(r.rc, 0, show(r, f));
  const e = entries(bag(f), 42);
  assert.equal(e.length, 2, `o/r#42 replaces the bare #42: ${show(r, f)}`);
  assert.ok(e.every((x) => x.state === "skipped-non-github"), JSON.stringify(e));
  assert.equal(bag(f).homeRepo, "o/r");
});
caseEnd();

// The --session <sid> --empty bag lives at the control-dir path, not at --out-file.
const controlBag = (sid) => {
  const { controlPath } = require(F.rel("hooks/workflow-state/state-io/control-dir"));
  const p = controlPath(sid, "issue-close-outcome.json", { forWrite: true });
  fs.mkdirSync(path.dirname(p), { recursive: true });
  return p;
};
const runEmpty = (sid) => F.runNode([WRITE, "--session", sid, "--empty"], { cwd: BASE, env: ghEnv({}), timeout: 60000 });

caseBegin("empty-mode-keeps-a-bag-with-recorded-entries", "bin/issue-close-write-outcome.js");
test("--empty on a bag holding one entry leaves the file byte-identical and names what it kept", () => {
  const f = controlBag("s1889k");
  const before = JSON.stringify({ homeRepo: "o/r", issues: [{ issueNumber: 42, issueRepo: "o/r", state: "succeeded" }] });
  fs.writeFileSync(f, before);
  const r = runEmpty("s1889k");
  assert.equal(r.rc, 0, show(r, f));
  assert.equal(fs.readFileSync(f, "utf8"), before, "the recorded bag is not rewritten");
  assert.ok(r.err.includes("issue-close-write-outcome: --empty kept 1 recorded outcome entries"), r.err);
});
caseEnd();

caseBegin("empty-mode-writes-the-empty-bag-when-nothing-is-recorded", "bin/issue-close-write-outcome.js");
test("--empty with no bag, an empty bag, or an unparsable file writes { issues: [] }", () => {
  const want = JSON.stringify({ issues: [] }, null, 2) + "\n";
  for (const [sid, seed] of [["s1889l", null], ["s1889m", '{"issues": []}'], ["s1889n", "{not json"]]) {
    const f = controlBag(sid);
    if (seed !== null) fs.writeFileSync(f, seed);
    const r = runEmpty(sid);
    assert.equal(r.rc, 0, `${sid}: ${show(r, f)}`);
    assert.equal(fs.readFileSync(f, "utf8"), want, `${sid}: the empty bag in table form`);
    assert.ok(!r.err.includes("--empty kept"), `${sid}: nothing is kept: ${r.err}`);
  }
});
caseEnd();

caseBegin("issue-state-maps-gh-answer", "bin/lib/issue-state.js");
test("issueState returns CLOSED / OPEN / null and resolves the repo through the home repo", () => {
  const issueState = F.need("bin/lib/issue-state.js", "issueState");
  const env = ghEnv({ 1: "CLOSED", 2: "OPEN", 3: "FAIL", "x/y#4": "CLOSED", "o/r2#5": "OPEN" });
  GH.withEnv(env, () => {
    assert.equal(issueState({ number: 1 }, "o/r"), "CLOSED");
    assert.equal(issueState({ number: 2 }, "o/r"), "OPEN");
    assert.equal(issueState({ number: 3 }, "o/r"), null);
    assert.equal(issueState({ number: 4, repo: "x/y" }, "o/r"), "CLOSED");
    assert.equal(issueState({ number: 5, repo: "r2" }, "o/r"), "OPEN");
    const before = ghCalls(env).length;
    assert.equal(issueState({ number: 6, repo: "r2" }, ""), null);
    assert.equal(ghCalls(env).length, before, "a shorthand repo without a home asks gh nothing");
  });
  const repoOf = (n) => { const a = ghCalls(env).find((x) => x.includes(String(n))); return a && a[a.indexOf("--repo") + 1]; };
  assert.equal(repoOf(4), "x/y");
  assert.equal(String(repoOf(5)).toLowerCase(), "o/r2");
  const c = ghCalls(env)[0];
  assert.deepEqual(c.slice(0, 3), ["issue", "view", "1"], JSON.stringify(c));
  assert.ok(c.includes("--json") && c.includes("state"), JSON.stringify(c));
});
caseEnd();
