"use strict";
// tests/hooks/feature-3144-pm-review-writer.js
// Tests: hooks/lib/pm-review-writer.js
// Tags: scope:issue-specific, TL2, pm-session, supervisor-audit, pm-review, security, table-driven, fail-closed
// #3144 C1: who may write a review verdict for a workflow session. pmCandidatesOf asks the decided owner of
// each closed issue; judgePmWrite admits only the candidate recorded as the destination, on a pending
// pre-confirm run (audit) or on the round / HEAD / PR of the last request row (pm-review); judgeRequestWrite
// admits the workflow session's own request while the round cap (CAP 2, one extension) allows it.
// TL3 gap (what this test does NOT catch):
// - a real forge answering the owner lookup (common.ownersOf is stubbed by owner-stub-preload.js)
// - a real PM session writing through the CLIs; tests/bin/feature-3144-pm-review-cli.js drives those
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { test, after } = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

delete process.env.CLAUDE_CODE_SESSION_ID;
const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f3144w-"));
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(TMP, "transcripts");
fs.mkdirSync(process.env.CLAUDE_TRANSCRIPT_BASE_DIR);
after(() => { restore(); fs.rmSync(TMP, { recursive: true, force: true }); });

const X = require("./feature-3144-pm-review-writer/fixture");
const F = X.make(TMP);
require(X.PRELOAD).install();
const W = X.W;
const show = (v) => JSON.stringify(v);
const sids = (r) => ((r && r.cands) || []).map((c) => c.session_id).sort();

caseBegin("C1 constants carry the S1-1 literal values", "hooks/lib/pm-review-writer.js");
test("C1 constants: reporters, row sources and the PR run-id prefix", () => {
  const w = W();
  assert.strictEqual(w.REPORTER_DEST, "route:pm-dest");
  assert.strictEqual(w.REPORTER_FALLBACK, "user:pm-review-fallback");
  assert.strictEqual(w.SOURCE_REQUEST_PREFIX, "request:");
  assert.strictEqual(w.SOURCE_USER, "user");
  assert.strictEqual(w.SOURCE_USER_PR_UNCONFIRMED, "user-pr-unconfirmed");
  assert.strictEqual(w.SOURCE_PM, "pm");
  assert.strictEqual(w.PR_RUN_PREFIX, "pr:");
  const d = w.destFinding("run-0007", "11111111-2222-4333-8444-555555555555");
  assert.strictEqual(d.reporter, "route:pm-dest");
  assert.ok(String(d.detail).includes("run-0007"), `the destination finding names its run: ${show(d)}`);
  assert.strictEqual(w.fallbackFinding("run-0007").reporter, "user:pm-review-fallback");
  const { validateFinding } = X.mod("hooks/lib/supervisor-state-schema.js");
  for (const f of [d, w.fallbackFinding("run-0007")]) assert.ok(validateFinding(f).ok, `valid finding: ${show(f)}`);
});
caseEnd();

caseBegin("C1 pmCandidatesOf truth table", "hooks/lib/pm-review-writer.js");
// #3168: decided candidates survive a partial failure (still decided:false). A whole failure (throw) gives 0 candidates. One ownersOf call.
test("C1 pmCandidatesOf: decided owners only; a partial failure keeps the decided candidates undecided", () => {
  const A = F.pm("pm-a");
  const B = F.pm("pm-b");
  const H = F.pm("pm-held");
  const rows = [
    { name: "one ref, owner A", refs: [3901], owners: { 3901: A }, decided: true, cands: [A] },
    { name: "two refs, owners A and B", refs: [3901, 3902], owners: { 3901: A, 3902: B }, decided: true, cands: [A, B] },
    { name: "two refs, both A", refs: [3901, 3902], owners: { 3901: A, 3902: A }, decided: true, cands: [A] },
    { name: "no owner anywhere", refs: [3901], owners: { 3901: null }, decided: true, cands: [] },
    { name: "A plus a timeout", refs: [3901, 3902], owners: { 3901: A, 3902: "timeout" }, decided: false, cands: [A] },
    { name: "board has no pm field", refs: [3901], owners: { 3901: "absent" }, decided: false, cands: [] },
    { name: "owner lookup throws", refs: [3901, 3902], owners: { 3901: A, 3902: "throw" }, decided: false, cands: [] },
    { name: "field unset, a local holder", refs: [3901], owners: { 3901: null }, holders: { 3901: [H] }, decided: false, cands: [] },
  ];
  for (const r of rows) {
    F.setOwners(r.owners, r.holders);
    const sid = F.target(r.refs);
    F.clearLog();
    const got = W().pmCandidatesOf(sid);
    assert.strictEqual(got.decided, r.decided, `${r.name}: decided ${show(got)}`);
    assert.deepStrictEqual(sids(got), [...new Set(r.cands.map((c) => c.session_id))].sort(), `${r.name}: cands ${show(got)}`);
    if (!r.decided) assert.ok(typeof got.reason === "string" && got.reason !== "", `${r.name}: a reason is given`);
    assert.ok(!sids(got).includes(H.session_id), `${r.name}: a local holder is never a candidate`);
    const calls = F.batchCalls();
    assert.strictEqual(calls.length, 1, `${r.name}: one ownersOf call for every ref: ${show(F.ownerCalls())}`);
    assert.deepStrictEqual([...calls[0].ns].sort(), r.refs.map(String).sort(), `${r.name}: the call carries each ref`);
  }
});
caseEnd();

// world(over) -> a target with one issue, its candidates and an armed pre-confirm run with a destination.
function world(over) {
  const o = over || {};
  const A = F.pm("pm-a");
  const B = F.pm("pm-b");
  F.setOwners(o.owners ? o.owners(A, B) : { 3910: A });
  const sid = F.target([3910]);
  const runId = F.arm(sid, o.cause);
  if (o.dest !== false) F.dest(sid, runId, (o.destPm || A).session_id);
  return { A, B, sid, runId };
}
const audit = (w, caller, extra) => W().judgePmWrite(Object.assign({ callerSid: caller, targetSid: w.sid, kind: "audit", runId: w.runId }, extra || {}));

caseBegin("C1 judgePmWrite kind=audit truth table", "hooks/lib/pm-review-writer.js");
test("C1 judgePmWrite audit: only the recorded destination writes a pending pre-confirm run", () => {
  const t = [];
  let w = world();
  t.push(["destination PM on its pending run", audit(w, w.A.session_id), true]);
  t.push(["empty caller", audit(w, ""), false]);
  t.push(["caller is the audited session", audit(w, w.sid), false]);
  t.push(["empty target", W().judgePmWrite({ callerSid: w.A.session_id, targetSid: "", kind: "audit", runId: w.runId }), false]);
  t.push(["a non-candidate", audit(w, w.B.session_id), false]);
  t.push(["another run id", audit(w, w.A.session_id, { runId: "run-9999" }), false]);
  w = world({ owners: (A, B) => ({ 3910: A, 3911: B }) });
  t.push(["destination among two candidates", audit(w, w.A.session_id), true]);
  t.push(["the other candidate (not the destination)", audit(w, w.B.session_id), false]);
  w = world({ dest: false });
  t.push(["no destination recorded", audit(w, w.A.session_id), false]);
  w = world();
  F.setOwners({ 3910: w.B });
  t.push(["destination no longer the owner", audit(w, w.A.session_id), false]);
  t.push(["new owner that is not the destination", audit(w, w.B.session_id), false]);
  w = world();
  F.setOwners({ 3910: "timeout" }, { 3910: [w.A] });
  t.push(["owner timeout, local holder equals the destination", audit(w, w.A.session_id), false]);
  F.setOwners({ 3910: null }, { 3910: [w.A] });
  t.push(["owner unset, local holder equals the destination", audit(w, w.A.session_id), false]);
  w = world();
  F.settle(w.sid, w.runId);
  t.push(["settled run", audit(w, w.A.session_id), false]);
  w = world({ cause: "step-complete:write_code" });
  t.push(["cause is not pre-confirm", audit(w, w.A.session_id), false]);
  w = world();
  F.fallback(w.sid, w.runId);
  t.push(["the user chose the conventional audit for this run", audit(w, w.A.session_id), false]);
  for (const [name, r, want] of t) {
    assert.strictEqual(!!(r && r.ok), want, `${name}: ${show(r)}`);
    if (!want) assert.ok(r && typeof r.reason === "string" && r.reason !== "", `${name}: a refusal carries a reason`);
  }
  w = world();
  assert.strictEqual(audit(w, w.A.session_id).pmSid, w.A.session_id, "ok names the PM");
});
caseEnd();

// review(rowsOf, owners) -> a target with pm-review rows; rowsOf(A, B) builds them.
function review(rowsOf, owners) {
  const A = F.pm("pm-a");
  const B = F.pm("pm-b");
  F.setOwners(owners ? owners(A, B) : { 3920: A, 3921: B });
  const sid = F.target([3920, 3921]);
  F.addRows(sid, rowsOf(A, B));
  return { A, B, sid };
}
const verdict = (w, caller, target) => W().judgePmWrite({ callerSid: caller, targetSid: w.sid, kind: "pm-review", target });
const T1 = { round: 1, fingerprint: X.FP.a, pr: 12 };

caseBegin("C1 judgePmWrite kind=pm-review truth table", "hooks/lib/pm-review-writer.js");
test("C1 judgePmWrite pm-review: one verdict per request round, on its round, HEAD and PR", () => {
  const req1 = (A) => [F.reqRow(1, A.session_id, 12, X.FP.a)];
  const t = [];
  let w = review(req1);
  t.push(["destination PM on the requested round", verdict(w, w.A.session_id, T1), true]);
  t.push(["other candidate", verdict(w, w.B.session_id, T1), false]);
  t.push(["the workflow session itself", verdict(w, w.sid, T1), false]);
  t.push(["HEAD differs from the request", verdict(w, w.A.session_id, Object.assign({}, T1, { fingerprint: X.FP.b })), false]);
  t.push(["PR differs from the request", verdict(w, w.A.session_id, Object.assign({}, T1, { pr: 13 })), false]);
  t.push(["round differs from the request", verdict(w, w.A.session_id, Object.assign({}, T1, { round: 2 })), false]);
  t.push(["no review target", verdict(w, w.A.session_id, undefined), false]);
  t.push(["target missing the fingerprint", verdict(w, w.A.session_id, { round: 1, pr: 12 }), false]);
  w = review((A) => req1(A).concat([F.pmRow(1, "OK", A.session_id, 12, X.FP.a)]));
  t.push(["second verdict on the same round", verdict(w, w.A.session_id, T1), false]);
  w = review((A) => req1(A).concat([F.userRow(1, 12, X.FP.a)]));
  t.push(["verdict after the user row", verdict(w, w.A.session_id, T1), false]);
  w = review((A) => req1(A).concat([F.pmRow(1, "NOT_OK", A.session_id, 12, X.FP.a), F.reqRow(2, A.session_id, 12, X.FP.b)]));
  t.push(["late OK for the previous round", verdict(w, w.A.session_id, T1), false]);
  t.push(["verdict on the new round", verdict(w, w.A.session_id, { round: 2, fingerprint: X.FP.b, pr: 12 }), true]);
  w = review(() => []);
  t.push(["no request row at all", verdict(w, w.A.session_id, T1), false]);
  w = review((A, B) => [F.reqRow(1, B.session_id, 12, X.FP.a)]);
  t.push(["request addressed to B, A writes", verdict(w, w.A.session_id, T1), false]);
  t.push(["request addressed to B, B writes", verdict(w, w.B.session_id, T1), true]);
  w = review(req1, (A) => ({ 3920: "timeout", 3921: null }));
  t.push(["undecidable owner", verdict(w, w.A.session_id, T1), false]);
  for (const [name, r, want] of t) assert.strictEqual(!!(r && r.ok), want, `${name}: ${show(r)}`);
});
caseEnd();

caseBegin("C1 judgeRequestWrite truth table with the round cap", "hooks/lib/pm-review-writer.js");
test("C1 judgeRequestWrite: the session itself, a decided candidate, and a round the cap allows", () => {
  const req = (w, caller, pmSid) => W().judgeRequestWrite({ callerSid: caller, targetSid: w.sid, pmSid });
  const t = [];
  let w = review(() => []);
  t.push(["first request to a candidate", req(w, w.sid, w.A.session_id), true]);
  t.push(["caller is not the target", req(w, w.A.session_id, w.A.session_id), false]);
  t.push(["pmSid is not a candidate", req(w, w.sid, X.uuid()), false]);
  t.push(["empty pmSid", req(w, w.sid, ""), false]);
  t.push(["pmSid with shell metacharacters", req(w, w.sid, `${w.A.session_id};rm -rf /`), false]);
  w = review(() => [], () => ({ 3920: "timeout", 3921: null }));
  t.push(["undecidable owner", req(w, w.sid, w.A.session_id), false]);
  // #3168: even on a partial failure (3920=A, 3921=timeout) a request to the decided candidate A is accepted; B, not a candidate, is refused.
  w = review(() => [], (A) => ({ 3920: A, 3921: "timeout" }));
  t.push(["partial candidates, request to the decided A", req(w, w.sid, w.A.session_id), true]);
  t.push(["partial candidates, request to B (not decided)", req(w, w.sid, w.B.session_id), false]);
  w = review((A) => [F.reqRow(1, A.session_id, 12, X.FP.a)]);
  t.push(["round 1 -> 2 (below CAP)", req(w, w.sid, w.A.session_id), true]);
  w = review((A) => [F.reqRow(1, A.session_id, 12, X.FP.a), F.reqRow(2, A.session_id, 12, X.FP.b), F.pmRow(2, "NOT_OK", A.session_id, 12, X.FP.b)]);
  t.push(["round CAP with a plain NOT_OK", req(w, w.sid, w.A.session_id), false]);
  w = review((A) => [F.reqRow(1, A.session_id, 12, X.FP.a), F.reqRow(2, A.session_id, 12, X.FP.b), F.pmRow(2, "AUTO_EXTEND", A.session_id, 12, X.FP.b)]);
  t.push(["round CAP with the destination's AUTO_EXTEND", req(w, w.sid, w.A.session_id), true]);
  w = review((A, B) => [F.reqRow(1, A.session_id, 12, X.FP.a), F.reqRow(2, A.session_id, 12, X.FP.b), F.pmRow(2, "AUTO_EXTEND", B.session_id, 12, X.FP.b)]);
  t.push(["round CAP with AUTO_EXTEND written by a non-destination", req(w, w.sid, w.A.session_id), false]);
  w = review((A) => [F.reqRow(1, A.session_id, 12, X.FP.a), F.reqRow(2, A.session_id, 12, X.FP.b), F.pmRow(2, "AUTO_EXTEND", A.session_id, 12, X.FP.b), F.reqRow(3, A.session_id, 12, X.FP.c)]);
  t.push(["round 3 (the extension is used)", req(w, w.sid, w.A.session_id), false]);
  w = review((A) => [F.reqRow(1, A.session_id, 12, X.FP.a), F.userRow(2, 12, X.FP.a)]);
  t.push(["a user row moved the round to CAP", req(w, w.sid, w.A.session_id), false]);
  for (const [name, r, want] of t) assert.strictEqual(!!(r && r.ok), want, `${name}: ${show(r)}`);
});
caseEnd();

caseBegin("C1 malformed review targets are refused", "hooks/lib/pm-review-writer.js");
test("C1 judgePmWrite pm-review: shell metacharacters or wrong types in the target are refused", () => {
  const w = review((A) => [F.reqRow(1, A.session_id, 12, X.FP.a)]);
  for (const [name, target] of [
    ["round with ;", { round: "1;x", fingerprint: X.FP.a, pr: 12 }],
    ["fingerprint with $()", { round: 1, fingerprint: `${X.FP.a}$(x)`, pr: 12 }],
    ["pr with a backtick", { round: 1, fingerprint: X.FP.a, pr: "12`x`" }],
    ["pr with a pipe", { round: 1, fingerprint: X.FP.a, pr: "12|x" }],
    ["round 0", { round: 0, fingerprint: X.FP.a, pr: 12 }],
    ["negative pr", { round: 1, fingerprint: X.FP.a, pr: -12 }],
  ]) {
    const r = verdict(w, w.A.session_id, target);
    assert.strictEqual(!!(r && r.ok), false, `${name}: ${show(r)}`);
  }
  const bad = W().judgePmWrite({ callerSid: `${w.A.session_id}&&x`, targetSid: w.sid, kind: "pm-review", target: T1 });
  assert.strictEqual(!!(bad && bad.ok), false, `caller sid with && : ${show(bad)}`);
});
caseEnd();
