"use strict";
// tests/bin/feature-3043-session-targets.js
// Tests: bin/issue-close-session-targets.js
// Tags: feature-3043, feature-1889, issue-close-finalize, from-session, issue-identity, gh-stub, scope:issue-specific, TL2, pwsh-not-required
// #3043 (D2): `--session <sid> --owner-repo <r>` lists the intent's issues once per (repo, N) key
// and splits them by gh state into {closed, open, unknown}, each ref shown by the outcomeLabel rule.
// TL3 gap: a real `gh issue view` against GitHub is not exercised; gh is the stub from
// tests/lib/gh-state-stub.js, answering per issue.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const F = require("../lib/worktree-leftover-fixture");
const { makeGhStub } = require("../lib/gh-state-stub");

const CLI_REL = "bin/issue-close-session-targets.js";
const restore = isolate();
const BASE = F.makeBase("f3043st-");
process.on("exit", () => { restore(); fs.rmSync(BASE, { recursive: true, force: true }); });
const PLANS = process.env.WORKFLOW_PLANS_DIR;
const STATE = process.env.WORKFLOW_STATE_DIR;
const GH = makeGhStub(path.join(BASE, "stub"));

function writeIntent(sid, refs) {
  fs.writeFileSync(path.join(PLANS, `${sid}-intent.md`), `# Intent\n\n## Issues\n${refs.map((r) => `- ${r}`).join("\n")}\n`);
}
// A ref is printed as its label string; an object carrying `label` is read the same way.
const label = (x) => (typeof x === "string" ? x : x && x.label);
// targets(args, map) — one CLI run; returns { r, env, json } with each list as sorted labels.
function targets(args, map) {
  if (!fs.existsSync(F.rel(CLI_REL))) throw new Error(`NOT YET IMPLEMENTED: ${CLI_REL} does not exist`);
  const env = GH.env(map);
  const r = F.runNode([F.rel(CLI_REL), ...args], { cwd: BASE, env, timeout: 60000 });
  let json = null;
  try {
    const raw = JSON.parse(r.out.trim());
    json = Object.fromEntries(["closed", "open", "unknown"].map((k) => [k, (raw[k] || []).map(label).sort()]));
  } catch (_) { json = null; }
  return { r, env, json };
}
const show = (t) => `rc=${t.r.rc} out=${t.r.out.trim()} err=${t.r.err.trim()}`;
const asked = (t, n) => GH.calls(t.env).filter((a) => a.includes(String(n)));

caseBegin("session-targets-split-by-gh-state", "bin/issue-close-session-targets.js");
test("CLOSED / OPEN / failed lookups land in closed / open / unknown", () => {
  writeIntent("s3043a", ["#701", "#702", "#703"]);
  const t = targets(["--session", "s3043a", "--owner-repo", "o/r"], { 701: "CLOSED", 702: "OPEN", 703: "FAIL" });
  assert.equal(t.r.rc, 0, show(t));
  assert.deepEqual(t.json, { closed: ["#701"], open: ["#702"], unknown: ["#703"] }, show(t));
});
caseEnd();

caseBegin("session-targets-mixed-spelling-is-one-ref", "bin/issue-close-session-targets.js");
test("#42 and o/r#42 with home o/r are judged once and shown as #42", () => {
  writeIntent("s3043b", ["#42", "o/r#42"]);
  const t = targets(["--session", "s3043b", "--owner-repo", "o/r"], { 42: "CLOSED" });
  assert.equal(t.r.rc, 0, show(t));
  assert.deepEqual(t.json, { closed: ["#42"], open: [], unknown: [] }, show(t));
  assert.equal(asked(t, 42).length, 1, JSON.stringify(GH.calls(t.env)));
});
caseEnd();

caseBegin("session-targets-cross-repo-label-and-repo-flag", "bin/issue-close-session-targets.js");
test("x/y#9 is looked up with --repo x/y and shown as x/y#9", () => {
  writeIntent("s3043c", ["x/y#9"]);
  const t = targets(["--session", "s3043c", "--owner-repo", "o/r"], { "x/y#9": "OPEN" });
  assert.equal(t.r.rc, 0, show(t));
  assert.deepEqual(t.json, { closed: [], open: ["x/y#9"], unknown: [] }, show(t));
  const call = asked(t, 9)[0];
  assert.ok(call && call[call.indexOf("--repo") + 1] === "x/y", JSON.stringify(GH.calls(t.env)));
});
caseEnd();

caseBegin("session-targets-same-n-in-two-repos-are-two-refs", "bin/issue-close-session-targets.js");
test("#42 (home o/r) and x/y#42 are two refs, each looked up in its own repo", () => {
  writeIntent("s3043k", ["#42", "x/y#42"]);
  const t = targets(["--session", "s3043k", "--owner-repo", "o/r"], { "o/r#42": "CLOSED", "x/y#42": "OPEN" });
  assert.equal(t.r.rc, 0, show(t));
  assert.deepEqual(t.json, { closed: ["#42"], open: ["x/y#42"], unknown: [] }, show(t));
  const repos = asked(t, 42).map((a) => (a.includes("--repo") ? a[a.indexOf("--repo") + 1] : "")).sort();
  assert.deepEqual(repos, ["o/r", "x/y"], `one --repo o/r and one --repo x/y lookup: ${JSON.stringify(GH.calls(t.env))}`);
});
caseEnd();

caseBegin("session-targets-bad-owner-repo-keeps-spellings-apart", "bin/issue-close-session-targets.js");
test("a malformed --owner-repo reads as no home: #42 and o/r#42 stay two refs and the run continues", () => {
  writeIntent("s3043d", ["#42", "o/r#42"]);
  const t = targets(["--session", "s3043d", "--owner-repo", "nope"], { 42: "CLOSED" });
  assert.equal(t.r.rc, 0, show(t));
  assert.deepEqual(t.json, { closed: ["#42", "o/r#42"], open: [], unknown: [] }, show(t));
  const bare = asked(t, 42).find((a) => !a.includes("--repo"));
  assert.ok(bare, `the bare #42 is looked up without --repo: ${JSON.stringify(GH.calls(t.env))}`);
});
caseEnd();

caseBegin("session-targets-shorthand-without-home-is-unknown", "bin/issue-close-session-targets.js");
test("r2#5 without --owner-repo cannot be resolved: unknown, and gh is not asked", () => {
  writeIntent("s3043e", ["r2#5"]);
  const t = targets(["--session", "s3043e"], { 5: "CLOSED" });
  assert.equal(t.r.rc, 0, show(t));
  assert.deepEqual(t.json, { closed: [], open: [], unknown: ["r2#5"] }, show(t));
  assert.equal(asked(t, 5).length, 0, JSON.stringify(GH.calls(t.env)));
});
caseEnd();

caseBegin("session-targets-no-issues-is-all-empty", "bin/issue-close-session-targets.js");
test("a session without intent issues prints three empty lists", () => {
  const t = targets(["--session", "s3043none", "--owner-repo", "o/r"], {});
  assert.equal(t.r.rc, 0, show(t));
  assert.deepEqual(t.json, { closed: [], open: [], unknown: [] }, show(t));
  assert.equal(GH.calls(t.env).length, 0);
});
caseEnd();

caseBegin("session-targets-invalid-session-touches-nothing", "bin/issue-close-session-targets.js");
test("a traversal --session asks gh nothing and writes no state", () => {
  writeIntent("s3043f", ["#701"]);
  const before = fs.readdirSync(STATE).sort();
  const t = targets(["--session", "../s3043f", "--owner-repo", "o/r"], { 701: "CLOSED" });
  assert.equal(GH.calls(t.env).length, 0, JSON.stringify(GH.calls(t.env)));
  assert.deepEqual(fs.readdirSync(STATE).sort(), before, "no state file appears");
  assert.ok(!(t.json && t.json.closed.length), `no target is reported for an invalid session: ${show(t)}`);
});
caseEnd();

caseBegin("session-targets-unreadable-intent-fails-without-gh", "bin/issue-close-session-targets.js");
test("an intent that exists but cannot be read exits 1 with one stderr line, no stdout, and no gh call", () => {
  fs.mkdirSync(path.join(PLANS, "s3043u-intent.md"), { recursive: true });
  const t = targets(["--session", "s3043u", "--owner-repo", "o/r"], { 701: "CLOSED" });
  assert.equal(t.r.rc, 1, show(t));
  assert.equal(t.r.out, "", show(t));
  const lines = t.r.err.split(/\r?\n/).filter(Boolean);
  assert.equal(lines.length, 1, show(t));
  assert.match(lines[0], /^issue-close-session-targets: could not read closes_issues: /, show(t));
  assert.equal(GH.calls(t.env).length, 0, JSON.stringify(GH.calls(t.env)));
});
caseEnd();
