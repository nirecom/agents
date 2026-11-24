"use strict";
// Tests: hooks/workflow-gate/user-verified-pm-review.js, hooks/workflow-gate.js, hooks/workflow-mark/pm-review-accepted-handler.js
// Tags: TL2, scope:issue-specific, pm-session, pm-review, user-verified, workflow-gate, sentinel, security, fail-closed
// #3144 C4 (S4): with an assigned PM, <<WORKFLOW_USER_VERIFIED>> passes only on the destination PM's OK in the last
// requested round for the current HEAD and PR, or on the user's row; a forge that does not answer passes only the
// user-pr-unconfirmed row tied to the last request's PR. The PR form of WORKFLOW_PM_REVIEW_ACCEPTED writes that row.
// The owner lookup and prForBranch are stubbed (owner-stub-preload.js); the rows are written straight from the S1-1 shapes.
// TL3 gap (what this test does NOT catch):
// - a real forge answering prForBranch, and the owner + PR lookups summed inside the real workflow-gate hook timeout
// - the real permissions.ask dialog in front of the sentinel
// - a forged row written straight into the control dir (the gap is exposed below as an xfail, not defended)
const { caseBegin, caseEnd, isolate, xfail } = require("../lib/harness");
const { test, after } = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

delete process.env.CLAUDE_CODE_SESSION_ID;
delete process.env.WORKFLOW_SESSION_ID;
const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f3144u-"));
const CFG = path.join(TMP, "cfg");
fs.mkdirSync(CFG);
fs.writeFileSync(path.join(CFG, ".env"), "");
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(TMP, "transcripts");
fs.mkdirSync(process.env.CLAUDE_TRANSCRIPT_BASE_DIR);
const FORGE_LOG = path.join(TMP, "forge.jsonl");
process.env.PM3144_FORGE_LOG = FORGE_LOG;
after(() => { restore(); fs.rmSync(TMP, { recursive: true, force: true }); });

const X = require("./feature-3144-pm-review-writer/fixture");
const F = X.make(TMP);
require(X.PRELOAD).install();
const show = (v) => JSON.stringify(v);

const REPO = path.join(TMP, "repo");
fs.mkdirSync(REPO);
const git = (...a) => spawnSync("git", a, { cwd: REPO, encoding: "utf8" });
git("init", "-q");
git("config", "core.hooksPath", "/dev/null");
git("config", "user.email", "fixture@example.invalid");
git("config", "user.name", "fixture");
fs.writeFileSync(path.join(REPO, "a.txt"), "a\n");
git("add", "a.txt");
git("commit", "-q", "-m", "fixture");
const HEAD = git("rev-parse", "HEAD").stdout.trim();
const OLD = X.FP.a;
const OPEN = (n) => ({ state: "OPEN", number: String(n) });
const UNKNOWN = { state: "UNKNOWN", number: "" };
const SENTINEL = "WORKFLOW_PM_REVIEW_ACCEPTED";
const forgeCalls = () => { try { return fs.readFileSync(FORGE_LOG, "utf8").split("\n").filter(Boolean).length; } catch (_) { return 0; } };

// judge(sid, pr) -> {pass, blocked, approved, forge}: the S4-1 check, run in process with prForBranch answering pr.
// pass means "neither blocked nor approved": the gate goes on to the TR5 audit, so approveFn must never fire here.
function judge(sid, pr) {
  process.env.PM3144_PR_STUB = JSON.stringify(pr);
  fs.rmSync(FORGE_LOG, { force: true });
  const fn = X.mod("hooks/workflow-gate/user-verified-pm-review.js").checkUserVerifiedPmReview;
  assert.strictEqual(typeof fn, "function", "checkUserVerifiedPmReview is exported");
  const STOP = {};
  let blocked = null;
  let approved = false;
  let ret;
  try {
    ret = fn(sid, REPO, { blockFn: (m) => { blocked = String(m); throw STOP; }, approveFn: () => { approved = true; throw STOP; } });
  } catch (e) { if (e !== STOP) throw e; }
  if (blocked === null && ret && ret.ok === false) blocked = String(ret.reason || "blocked");
  return { pass: blocked === null && !approved, blocked, approved, forge: forgeCalls() };
}
const passes = (r, what) => { assert.ok(r.pass, `${what}: expected pass ${show(r)}`); assert.ok(!r.approved, `${what}: approveFn skips TR5`); };
const blocks = (r, what) => assert.ok(r.blocked !== null && !r.approved, `${what}: expected block ${show(r)}`);

// world(owners) -> a target with PM A on #3911 (and B on #3912 when two), its rows empty.
function world(two) {
  const A = F.pm("pm-a");
  const B = F.pm("pm-b");
  F.setOwners(two ? { 3911: A, 3912: B } : { 3911: A });
  const sid = F.target(two ? [3911, 3912] : [3911], { cwd: REPO });
  return { A, B, sid };
}
const req = (r, pm, pr, fp) => F.reqRow(r, pm.session_id, pr, fp || HEAD);
const pmr = (r, v, pm, pr, fp) => F.pmRow(r, v, pm.session_id, pr, fp || HEAD);

caseBegin("3144 C4 no assigned PM passes without a forge call", "hooks/workflow-gate/user-verified-pm-review.js");
test("3144 C4: no assigned PM -> pass, prForBranch never called; an undecidable owner is not 'no PM'", () => {
  F.setOwners({ 3911: null });
  const none = F.target([3911], { cwd: REPO });
  const r = judge(none, OPEN(12));
  passes(r, "no PM");
  assert.strictEqual(r.forge, 0, "no forge call without a PM");
  F.setOwners({ 3911: "timeout" });
  blocks(judge(F.target([3911], { cwd: REPO }), OPEN(12)), "owner timeout with no rows (fail-closed, not 'no PM')");
});
caseEnd();

caseBegin("3144 C4 PM verdict truth table", "hooks/workflow-gate/user-verified-pm-review.js");
test("3144 C4: only the destination's OK in the last requested round for the current HEAD and PR passes", () => {
  const cases = [
    ["dest OK, last round, HEAD and PR match", false, (w) => [req(1, w.A, 12), pmr(1, "OK", w.A, 12)], OPEN(12), true],
    ["OK only in an earlier round, the last round has no PM row", false, (w) => [req(1, w.A, 12), pmr(1, "OK", w.A, 12), req(2, w.A, 12)], OPEN(12), false],
    ["ask-chosen destination B answers OK", true, (w) => [req(1, w.B, 12), pmr(1, "OK", w.B, 12)], OPEN(12), true],
    ["same HEAD, PR recreated (13 now)", false, (w) => [req(1, w.A, 12), pmr(1, "OK", w.A, 12)], OPEN(13), false],
    ["HEAD moved after the OK", false, (w) => [req(1, w.A, 12, OLD), pmr(1, "OK", w.A, 12, OLD)], OPEN(12), false],
    ["NOT_OK", false, (w) => [req(1, w.A, 12), pmr(1, "NOT_OK", w.A, 12)], OPEN(12), false],
    ["AUTO_EXTEND", false, (w) => [req(1, w.A, 12), pmr(1, "AUTO_EXTEND", w.A, 12)], OPEN(12), false],
    ["no rows", false, () => [], OPEN(12), false],
    ["OK written by a candidate that is not the destination", true, (w) => [req(1, w.A, 12), pmr(1, "OK", w.B, 12)], OPEN(12), false],
    ["OK with a PR other than the request's", false, (w) => [req(1, w.A, 12), pmr(1, "OK", w.A, 13)], OPEN(13), false],
    ["user row, HEAD and PR match", false, (w) => [req(1, w.A, 12), pmr(1, "NOT_OK", w.A, 12), F.userRow(2, 12, HEAD)], OPEN(12), true],
    ["user row on an old HEAD", false, (w) => [req(1, w.A, 12), F.userRow(2, 12, OLD)], OPEN(12), false],
    ["user row on another PR", false, (w) => [req(1, w.A, 12), F.userRow(2, 12, HEAD)], OPEN(13), false],
  ];
  for (const [name, two, rows, pr, want] of cases) {
    const w = world(two);
    F.addRows(w.sid, rows(w));
    (want ? passes : blocks)(judge(w.sid, pr), name);
  }
});
test("3144 C4: the block message names the Review request and the PM review sentinel", () => {
  const w = world(false);
  const r = judge(w.sid, OPEN(12));
  blocks(r, "no rows");
  assert.ok(/Review request/.test(r.blocked) && r.blocked.includes(SENTINEL), r.blocked);
});
caseEnd();

caseBegin("3144 C4 forge UNKNOWN passes only the user-pr-unconfirmed row of the requested PR", "hooks/workflow-gate/user-verified-pm-review.js");
test("3144 C4: forge UNKNOWN -> PM OK and user rows block; user-pr-unconfirmed passes only for the request's PR and HEAD", () => {
  const cases = [
    ["PM OK row", (w) => [req(1, w.A, 12), pmr(1, "OK", w.A, 12)], false],
    ["source=user row", (w) => [req(1, w.A, 12), F.userRow(2, 12, HEAD)], false],
    ["user-pr-unconfirmed, request PR and HEAD", (w) => [req(1, w.A, 12), F.userRow(2, 12, HEAD, true)], true],
    ["user-pr-unconfirmed, PR differs from the request", (w) => [req(1, w.A, 12), F.userRow(2, 13, HEAD, true)], false],
    ["user-pr-unconfirmed, old HEAD", (w) => [req(1, w.A, 12), F.userRow(2, 12, OLD, true)], false],
  ];
  for (const [name, rows, want] of cases) {
    const w = world(false);
    F.addRows(w.sid, rows(w));
    (want ? passes : blocks)(judge(w.sid, UNKNOWN), name);
  }
  const w = world(false);
  F.addRows(w.sid, [req(1, w.A, 12)]);
  const r = judge(w.sid, UNKNOWN);
  blocks(r, "UNKNOWN with no answer");
  assert.ok(r.blocked.includes("pm-review.pr-unconfirmed"), `the UNKNOWN block names the AskUserQuestion source: ${r.blocked}`);
});
test("3144 C4: forge answers -> a user-pr-unconfirmed row must also match the current PR", () => {
  const w = world(false);
  F.addRows(w.sid, [req(1, w.A, 12), F.userRow(2, 12, HEAD, true)]);
  blocks(judge(w.sid, OPEN(13)), "current PR 13, row pr:12");
});
caseEnd();

caseBegin("3144 C4 forged control-dir row exposure", "hooks/workflow-gate/user-verified-pm-review.js");
// Known gap (detail Risks: direct Write to the control dir): a row appended straight to the control dir is read like
// a CLI-written one. xfail keeps the exposure visible; XPASS means a defense landed and the wrapper must go.
xfail("3144 C4 (gap): a source=user row forged straight into the control dir is rejected", () => {
  const w = world(false);
  F.addRows(w.sid, [req(1, w.A, 12), F.userRow(2, 12, HEAD)]);
  blocks(judge(w.sid, OPEN(12)), "forged user row");
});
caseEnd();

caseBegin("3144 C4 workflow-gate calls the PM review check before the TR5 audit", "hooks/workflow-gate.js");
test("3144 C4: workflow-gate.js requires user-verified-pm-review and calls it inside uvHit before checkUserVerifiedAudit", () => {
  const src = fs.readFileSync(X.rel("hooks/workflow-gate.js"), "utf8");
  assert.ok(/require\(["']\.\/workflow-gate\/user-verified-pm-review["']\)/.test(src), "the module is required");
  const uv = src.indexOf("sentinelAnalysis.uvHit");
  const tr5 = src.indexOf("checkUserVerifiedAudit(sessionId");
  const call = src.search(/checkUserVerifiedPmReview\s*\(\s*sessionId/);
  assert.ok(uv >= 0 && tr5 > uv, "uvHit block and TR5 call located");
  assert.ok(call > uv && call < tr5, `call order: uvHit=${uv} pm-review=${call} tr5=${tr5}`);
});
caseEnd();

// mark(sid, body, pr) -> runs hooks/workflow-mark.js on the sentinel with prForBranch answering pr.
function mark(sid, body, pr) {
  const env = Object.assign({}, process.env, F.env(), { AGENTS_MAIN_ROOT: CFG, PM3144_PR_STUB: JSON.stringify(pr),
    NODE_OPTIONS: `--require "${X.PRELOAD.replace(/\\/g, "/")}"` });
  delete env.CLAUDE_CODE_SESSION_ID;
  const input = { tool_name: "Bash", session_id: sid, tool_input: { command: `echo "<<${SENTINEL}: ${body}>>"`, cwd: REPO }, tool_response: { exit_code: 0 } };
  const r = spawnSync(process.execPath, [X.rel("hooks/workflow-mark.js")], { input: JSON.stringify(input), encoding: "utf8", timeout: 60000, env, cwd: REPO });
  return (r.stdout || "") + (r.stderr || "");
}
const REASON = "the PM did not answer twice; the user chose the supervisor-audit";
// requestCli(sid, pm, pr) -> exit status of `bin/review-rounds append --format pm-review --request` as the workflow session.
function requestCli(sid, pm, pr) {
  const env = Object.assign({}, process.env, F.env(), { AGENTS_MAIN_ROOT: X.ROOT, CLAUDE_CODE_SESSION_ID: sid,
    NODE_OPTIONS: `--require "${X.PRELOAD.replace(/\\/g, "/")}"` });
  const r = spawnSync(process.execPath, [X.rel("bin/review-rounds"), "append", "--session", sid, "--format", "pm-review", "--request", "--pm-sid", pm.session_id, "--pr", String(pr)],
    { cwd: REPO, encoding: "utf8", timeout: 30000, env });
  return r.status;
}
const last = (sid) => F.readRows(sid).slice(-1)[0] || {};

caseBegin("3144 C4 PR-form sentinel handler writes the user row", "hooks/workflow-mark/pm-review-accepted-handler.js");
test("3144 C4 handler: PR match -> source=user at round+1 with HEAD and pr:<n>; the gate then passes", () => {
  const w = world(false);
  F.addRows(w.sid, [req(1, w.A, 12), pmr(1, "NOT_OK", w.A, 12)]);
  const out = mark(w.sid, `PR#12 ${REASON}`, OPEN(12));
  const row = last(w.sid);
  assert.strictEqual(F.readRows(w.sid).length, 3, `one row written: ${out}`);
  assert.deepStrictEqual([row.source, row.run_id, row.fingerprint, row.counter_round], ["user", "pr:12", HEAD, 2], show(row));
  passes(judge(w.sid, OPEN(12)), "gate after the user row");
});
test("3144 C4 handler: forge UNKNOWN -> user-pr-unconfirmed only for the last request's PR", () => {
  const w = world(false);
  F.addRows(w.sid, [req(1, w.A, 12)]);
  mark(w.sid, `PR#12 ${REASON}`, UNKNOWN);
  const row = last(w.sid);
  assert.deepStrictEqual([row.source, row.run_id, row.fingerprint], ["user-pr-unconfirmed", "pr:12", HEAD], show(row));
});
test("3144 C4 handler: no request row, another number, a PR mismatch or a metacharacter target writes nothing", () => {
  const cases = [
    ["UNKNOWN, no request row", () => [], `PR#12 ${REASON}`, UNKNOWN],
    ["UNKNOWN, request pr:12, sentinel PR#13", (w) => [req(1, w.A, 12)], `PR#13 ${REASON}`, UNKNOWN],
    ["forge says 13, sentinel PR#12", (w) => [req(1, w.A, 12)], `PR#12 ${REASON}`, OPEN(13)],
    ["metacharacter in the PR target", (w) => [req(1, w.A, 12)], `PR#12;id ${REASON}`, OPEN(12)],
    ["command substitution in the PR target", (w) => [req(1, w.A, 12)], `PR#$(id) ${REASON}`, OPEN(12)],
  ];
  for (const [name, rows, body, pr] of cases) {
    const w = world(false);
    F.addRows(w.sid, rows(w));
    const n = F.readRows(w.sid).length;
    const out = mark(w.sid, body, pr);
    assert.strictEqual(F.readRows(w.sid).length, n, `${name}: nothing written; ${out}`);
  }
});
test("3144 C4 handler: at round CAP without AUTO_EXTEND the user row keeps the round; the next request is a cap exit", () => {
  const w = world(false);
  F.addRows(w.sid, [req(1, w.A, 12), pmr(1, "NOT_OK", w.A, 12), req(2, w.A, 12), pmr(2, "NOT_OK", w.A, 12)]);
  mark(w.sid, `PR#12 ${REASON}`, OPEN(12));
  const row = last(w.sid);
  assert.deepStrictEqual([row.source, row.counter_round], ["user", 2], `round stays at CAP: ${show(row)}`);
  const n = F.readRows(w.sid).length;
  assert.notStrictEqual(requestCli(w.sid, w.A, 12), 0, "the following request is a cap exit");
  assert.strictEqual(F.readRows(w.sid).length, n, "the cap exit writes no row");
});
caseEnd();
