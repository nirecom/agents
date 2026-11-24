"use strict";
// tests/bin/feature-3144-pm-review-cli.js
// Tests: bin/supervisor-write-audit-verdict, bin/review-rounds, bin/lib/codex-review-loop/review-rounds.js
// Tags: scope:issue-specific, TL2, pm-session, supervisor-audit, pm-review, security, cli, fail-closed
// #3144 C1 (S1-3, S1-4): the verdict CLI re-judges a caller whose sid differs from --session-id (the PM route),
// stamps its findings pm:<caller> and strips route-only reporters on the other route; review-rounds append
// --format pm-review writes the request row (round = max request/user round + 1, cap exit) and the PM verdict
// row only for the round / HEAD / PR of the last request row, writing --high at round CAP as AUTO_EXTEND.
// TL3 gap (what this test does NOT catch):
// - a real PM session's CLAUDE_CODE_SESSION_ID in its Bash tool (the test sets it on the spawned CLI)
// - a forge owner lookup (owner-stub-preload.js answers it through NODE_OPTIONS)
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { test, after } = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

delete process.env.CLAUDE_CODE_SESSION_ID;
delete process.env.WORKFLOW_SESSION_ID;
const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f3144c-"));
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(TMP, "transcripts");
fs.mkdirSync(process.env.CLAUDE_TRANSCRIPT_BASE_DIR);
after(() => { restore(); fs.rmSync(TMP, { recursive: true, force: true }); });

const X = require("../hooks/feature-3144-pm-review-writer/fixture");
const F = X.make(TMP);
require(X.PRELOAD).install();
const show = (v) => JSON.stringify(v);

// A fixture repo whose HEAD is the fingerprint a request row records.
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

// cli(bin, args, callerSid) -> {status, out, err}; the caller sid is the CLI's CLAUDE_CODE_SESSION_ID.
function cli(bin, args, callerSid) {
  const env = Object.assign({}, process.env, F.env(), {
    AGENTS_MAIN_ROOT: X.ROOT, NODE_OPTIONS: `--require ${X.PRELOAD.replace(/\\/g, "/")}`,
  });
  delete env.CLAUDE_CODE_SESSION_ID;
  delete env.WORKFLOW_SESSION_ID;
  if (callerSid) env.CLAUDE_CODE_SESSION_ID = callerSid;
  const r = spawnSync(process.execPath, [X.rel(bin), ...args.map(String)], { cwd: REPO, encoding: "utf8", timeout: 30000, env });
  return { status: r.status, out: r.stdout || "", err: (r.stderr || "") + (r.error ? String(r.error) : "") };
}
const VERDICT_BIN = "bin/supervisor-write-audit-verdict";
const verdict = (target, runId, caller, findingsFile) => cli(VERDICT_BIN, ["--session-id", target, "--audit-run-id", runId,
  "--verdict", "CONTINUE", "--verdict-summary", "fixture"].concat(findingsFile ? ["--findings-jsonl", findingsFile] : []), caller);
const rr = (target, args, caller) => cli("bin/review-rounds", ["append", "--session", target, "--format", "pm-review"].concat(args), caller);
const request = (target, pmSid, pr) => rr(target, ["--request", "--pm-sid", pmSid, "--pr", pr], target);
const pmVerdict = (target, pmSid, o) => rr(target, ["--round", o.round, "--fingerprint", o.fp, "--pr", o.pr, "--verdict", o.verdict]
  .concat(o.high ? ["--high"] : []), pmSid);
let nFile = 0;
function findingsFile(list) {
  nFile += 1;
  const p = path.join(TMP, `findings-${nFile}.jsonl`);
  fs.writeFileSync(p, list.map((f) => JSON.stringify(f)).join("\n") + "\n");
  return p;
}
const finding = (reporter, detail) => ({ categories: ["workflow"], severity: "notice", detail, reporter });
const phase = (sid) => X.sup().readState(sid).audit.audit_phase;

// world() -> a target with one assigned PM A (plus a second candidate B) and an armed pre-confirm run.
function world() {
  const A = F.pm("pm-a");
  const B = F.pm("pm-b");
  F.setOwners({ 3901: A, 3902: B });
  const sid = F.target([3901, 3902], { cwd: REPO });
  const run = F.arm(sid);
  return { A, B, sid, run };
}

caseBegin("C1 verdict CLI PM route stamps reporter pm:<caller> and adds one notice", "bin/supervisor-write-audit-verdict");
test("C1 verdict CLI: the destination PM settles the run; findings are re-stamped pm:<caller>", () => {
  const w = world();
  F.dest(w.sid, w.run, w.A.session_id);
  const before = F.findings(w.sid).length;
  const file = findingsFile([finding("supervisor-audit", "pm finding one"), finding("route:pm-dest", "pm finding two")]);
  const r = verdict(w.sid, w.run, w.A.session_id, file);
  assert.strictEqual(r.status, 0, `PM verdict accepted: ${r.out} ${r.err}`);
  assert.notStrictEqual(phase(w.sid), "pending", "the run is settled");
  const added = F.findings(w.sid).slice(before);
  const mine = added.filter((f) => /pm finding (one|two)/.test(f.detail));
  assert.strictEqual(mine.length, 2, show(added));
  for (const f of mine) assert.strictEqual(f.reporter, `pm:${w.A.session_id}`, `re-stamped: ${show(f)}`);
  const notes = added.filter((f) => !/pm finding/.test(f.detail));
  assert.strictEqual(notes.length, 1, `exactly one notice finding is added: ${show(added)}`);
  assert.strictEqual(notes[0].severity, "notice");
  assert.ok(notes[0].detail.includes(w.run) && notes[0].detail.includes("CONTINUE"), `notice names run and verdict: ${show(notes[0])}`);
});
caseEnd();

caseBegin("C1 verdict CLI PM route rejects a non-destination, a stale run and a forged caller sid", "bin/supervisor-write-audit-verdict");
test("C1 verdict CLI: block a non-destination candidate, an earlier run, no destination, metacharacter sids", () => {
  const w = world();
  F.dest(w.sid, w.run, w.A.session_id);
  const rows = [
    { name: "the other candidate B", caller: w.B.session_id },
    { name: "a non-candidate", caller: F.pm("stranger").session_id },
    { name: "caller sid with shell metacharacters", caller: `${w.A.session_id};x` },
  ];
  for (const t of rows) {
    const r = verdict(w.sid, w.run, t.caller);
    assert.notStrictEqual(r.status, 0, `${t.name} is rejected: ${r.out}`);
    assert.strictEqual(phase(w.sid), "pending", `${t.name} leaves the run pending`);
  }
  const noDest = world();
  const r1 = verdict(noDest.sid, noDest.run, noDest.A.session_id);
  assert.notStrictEqual(r1.status, 0, "no destination finding -> rejected");
  assert.strictEqual(phase(noDest.sid), "pending");
  const stale = world();
  F.dest(stale.sid, stale.run, stale.A.session_id);
  const run2 = F.arm(stale.sid);
  const r2 = verdict(stale.sid, stale.run, stale.A.session_id);
  assert.notStrictEqual(r2.status, 0, "a late verdict for the superseded run is rejected");
  assert.strictEqual(X.sup().readState(stale.sid).audit.audit_run_id, run2);
  assert.strictEqual(phase(stale.sid), "pending");
});
caseEnd();

caseBegin("C1 verdict CLI non-PM route strips pm:/route:/fallback reporters and keeps exit 3", "bin/supervisor-write-audit-verdict");
test("C1 verdict CLI: same-sid caller -> forged route reporters reset to supervisor-audit; CAS mismatch exit 3", () => {
  const w = world();
  const before = F.findings(w.sid).length;
  const forged = ["pm:" + w.A.session_id, "route:pm-dest", "user:pm-review-fallback", "route:anything"];
  const file = findingsFile(forged.map((rep, i) => finding(rep, `forged ${i}`)));
  for (const caller of [w.sid, null]) {
    const s = caller ? w : world();
    const r = verdict(s.sid, s.run, caller, file);
    assert.strictEqual(r.status, 0, `subagent route accepted (caller ${caller}): ${r.out} ${r.err}`);
    const added = F.findings(s.sid).slice(s === w ? before : 0).filter((f) => /^forged/.test(f.detail));
    assert.strictEqual(added.length, forged.length, show(added));
    for (const f of added) assert.strictEqual(f.reporter, "supervisor-audit", `reporter forgery removed: ${show(f)}`);
  }
  const c = world();
  const run2 = F.arm(c.sid);
  const r = verdict(c.sid, c.run, c.sid);
  assert.strictEqual(r.status, 3, `stale run id keeps the CAS exit 3: ${r.out} ${r.err}`);
  assert.strictEqual(X.sup().readState(c.sid).audit.audit_run_id, run2);
});
caseEnd();

caseBegin("C1 review-rounds pm-review request row round and cap exit", "bin/review-rounds");
test("C1 review-rounds request row: REQUESTED at max(request,user)+1 with HEAD and pr:<n>; cap writes nothing", () => {
  const w = world();
  F.dest(w.sid, w.run, w.A.session_id);
  const r1 = request(w.sid, w.A.session_id, 12);
  assert.strictEqual(r1.status, 0, `first request: ${r1.err}`);
  const rows1 = F.readRows(w.sid);
  assert.strictEqual(rows1.length, 1, show(rows1));
  const q = rows1[0];
  assert.deepStrictEqual([q.verdict, q.counter_round, q.source, q.run_id, q.fingerprint],
    ["REQUESTED", 1, `request:${w.A.session_id}`, "pr:12", HEAD], show(q));
  // A verdict row does not advance the round; a user row does.
  F.addRows(w.sid, [F.pmRow(1, "NOT_OK", w.A.session_id, 12, HEAD)]);
  const r2 = request(w.sid, w.A.session_id, 12);
  assert.strictEqual(r2.status, 0, r2.err);
  assert.strictEqual(F.readRows(w.sid).at(-1).counter_round, 2);
  // Round 2 == CAP, NOT_OK without AUTO_EXTEND -> cap exit, nothing written.
  F.addRows(w.sid, [F.pmRow(2, "NOT_OK", w.A.session_id, 12, HEAD)]);
  const n = F.readRows(w.sid).length;
  const r3 = request(w.sid, w.A.session_id, 12);
  assert.notStrictEqual(r3.status, 0, "round CAP without AUTO_EXTEND -> cap exit");
  assert.strictEqual(F.readRows(w.sid).length, n, "the cap exit writes no row");

  const u = world();
  F.addRows(u.sid, [F.reqRow(1, u.A.session_id, 12, HEAD), F.userRow(1, 12, HEAD)]);
  const ru = request(u.sid, u.A.session_id, 12);
  assert.strictEqual(ru.status, 0, ru.err);
  assert.strictEqual(F.readRows(u.sid).at(-1).counter_round, 2, "user row counts toward the round");

  const e = world();
  F.addRows(e.sid, [F.reqRow(1, e.A.session_id, 12, HEAD), F.pmRow(1, "NOT_OK", e.A.session_id, 12, HEAD),
    F.reqRow(2, e.A.session_id, 12, HEAD), F.pmRow(2, "AUTO_EXTEND", e.A.session_id, 12, HEAD)]);
  const re = request(e.sid, e.A.session_id, 12);
  assert.strictEqual(re.status, 0, `AUTO_EXTEND at CAP allows round 3: ${re.err}`);
  assert.strictEqual(F.readRows(e.sid).at(-1).counter_round, 3);
  F.addRows(e.sid, [F.pmRow(3, "AUTO_EXTEND", e.A.session_id, 12, HEAD)]);
  const ne = F.readRows(e.sid).length;
  assert.notStrictEqual(request(e.sid, e.A.session_id, 12).status, 0, "round 3 -> cap exit");
  assert.strictEqual(F.readRows(e.sid).length, ne);
});
caseEnd();

caseBegin("C1 review-rounds pm-review verdict row matches the last request row", "bin/review-rounds");
test("C1 review-rounds verdict row: written at the PM's round/HEAD/PR; mismatch, stale and second verdicts rejected", () => {
  const w = world();
  F.addRows(w.sid, [F.reqRow(1, w.A.session_id, 12, HEAD)]);
  const T = { round: 1, fp: HEAD, pr: 12, verdict: "OK" };
  const bad = [
    { name: "round mismatch", o: Object.assign({}, T, { round: 2 }) },
    { name: "fingerprint mismatch", o: Object.assign({}, T, { fp: X.FP.b }) },
    { name: "pr mismatch (recreated PR)", o: Object.assign({}, T, { pr: 13 }) },
    { name: "verdict REQUESTED", o: Object.assign({}, T, { verdict: "REQUESTED" }) },
    { name: "verdict AUTO_EXTEND given directly", o: Object.assign({}, T, { verdict: "AUTO_EXTEND" }) },
  ];
  for (const t of bad) {
    const r = pmVerdict(w.sid, w.A.session_id, t.o);
    assert.notStrictEqual(r.status, 0, `${t.name} rejected: ${r.out}`);
    assert.strictEqual(F.readRows(w.sid).length, 1, `${t.name} writes nothing`);
  }
  assert.notStrictEqual(pmVerdict(w.sid, w.B.session_id, T).status, 0, "non-destination candidate rejected");
  assert.notStrictEqual(pmVerdict(w.sid, w.sid, T).status, 0, "the target itself cannot write the PM verdict");
  const missing = rr(w.sid, ["--fingerprint", HEAD, "--pr", 12, "--verdict", "OK"], w.A.session_id);
  assert.notStrictEqual(missing.status, 0, "missing --round rejected");
  const ok = pmVerdict(w.sid, w.A.session_id, T);
  assert.strictEqual(ok.status, 0, `destination PM verdict: ${ok.err}`);
  const v = F.readRows(w.sid).at(-1);
  assert.deepStrictEqual([v.verdict, v.counter_round, v.fingerprint, v.run_id, v.source, v.writer_sid],
    ["OK", 1, HEAD, "pr:12", "pm", w.A.session_id], show(v));
  assert.notStrictEqual(pmVerdict(w.sid, w.A.session_id, T).status, 0, "a second verdict for the same round is rejected");
  assert.strictEqual(F.readRows(w.sid).length, 2);
  // A late OK for round 1 after the round-2 request row.
  F.addRows(w.sid, [F.reqRow(2, w.A.session_id, 12, X.FP.c)]);
  assert.notStrictEqual(pmVerdict(w.sid, w.A.session_id, Object.assign({}, T, { verdict: "NOT_OK" })).status, 0,
    "late verdict for the previous round rejected");
  // After the user row closed the round, no PM verdict is accepted.
  F.addRows(w.sid, [F.userRow(2, 12, X.FP.c)]);
  const n = F.readRows(w.sid).length;
  assert.notStrictEqual(pmVerdict(w.sid, w.A.session_id, { round: 2, fp: X.FP.c, pr: 12, verdict: "OK" }).status, 0);
  assert.strictEqual(F.readRows(w.sid).length, n);
});
caseEnd();

caseBegin("C1 review-rounds --high is AUTO_EXTEND only at round CAP", "bin/review-rounds");
test("C1 review-rounds --high: NOT_OK at round 1, AUTO_EXTEND at round 2 (CAP)", () => {
  const w = world();
  F.addRows(w.sid, [F.reqRow(1, w.A.session_id, 12, HEAD)]);
  assert.strictEqual(pmVerdict(w.sid, w.A.session_id, { round: 1, fp: HEAD, pr: 12, verdict: "NOT_OK", high: true }).status, 0);
  assert.strictEqual(F.readRows(w.sid).at(-1).verdict, "NOT_OK");
  F.addRows(w.sid, [F.reqRow(2, w.A.session_id, 12, X.FP.b)]);
  assert.strictEqual(pmVerdict(w.sid, w.A.session_id, { round: 2, fp: X.FP.b, pr: 12, verdict: "NOT_OK", high: true }).status, 0);
  assert.strictEqual(F.readRows(w.sid).at(-1).verdict, "AUTO_EXTEND");
  const v = world();
  F.addRows(v.sid, [F.reqRow(1, v.A.session_id, 12, HEAD), F.pmRow(1, "NOT_OK", v.A.session_id, 12, HEAD),
    F.reqRow(2, v.A.session_id, 12, X.FP.b)]);
  assert.strictEqual(pmVerdict(v.sid, v.A.session_id, { round: 2, fp: X.FP.b, pr: 12, verdict: "NOT_OK" }).status, 0);
  assert.strictEqual(F.readRows(v.sid).at(-1).verdict, "NOT_OK", "no --high at CAP stays NOT_OK");
});
caseEnd();

caseBegin("C1 review-rounds pm-review rejects shell metacharacters and a non-candidate --pm-sid", "bin/review-rounds");
test("C1 review-rounds malformed --pm-sid / --fingerprint / --pr / --round are rejected without a row", () => {
  const w = world();
  const badReq = [
    ["--request", "--pm-sid", `${w.A.session_id};id`, "--pr", 12],
    ["--request", "--pm-sid", "$(id)", "--pr", 12],
    ["--request", "--pm-sid", w.A.session_id, "--pr", "12&&id"],
    ["--request", "--pm-sid", w.A.session_id, "--pr", "-1"],
    ["--request", "--pm-sid", F.pm("stranger").session_id, "--pr", 12],
    ["--request", "--pm-sid", w.A.session_id],
  ];
  for (const a of badReq) {
    const r = rr(w.sid, a, w.sid);
    assert.notStrictEqual(r.status, 0, `rejected: ${show(a)}`);
    assert.strictEqual(F.readRows(w.sid).length, 0, `no row for ${show(a)}`);
  }
  F.addRows(w.sid, [F.reqRow(1, w.A.session_id, 12, HEAD)]);
  const badVerdict = [
    { round: "1;id", fp: HEAD, pr: 12, verdict: "OK" },
    { round: 0, fp: HEAD, pr: 12, verdict: "OK" },
    { round: 1, fp: `${HEAD}|id`, pr: 12, verdict: "OK" },
    { round: 1, fp: "`id`", pr: 12, verdict: "OK" },
    { round: 1, fp: HEAD, pr: "12 ;id", verdict: "OK" },
  ];
  for (const o of badVerdict) {
    const r = pmVerdict(w.sid, w.A.session_id, o);
    assert.notStrictEqual(r.status, 0, `rejected: ${show(o)}`);
    assert.strictEqual(F.readRows(w.sid).length, 1, `no row for ${show(o)}`);
  }
  F.setOwners({ 3901: "timeout", 3902: w.B });
  assert.notStrictEqual(request(w.sid, w.A.session_id, 12).status, 0, "undecidable owner -> request rejected");
  assert.strictEqual(F.readRows(w.sid).length, 1);
});
caseEnd();

// Kept here rather than in tests/bin/feature-2938-review-rounds.js, which is at its size limit.
caseBegin("C1 pm-review NON_APPROVED_VERDICT and caps match the codex-review-loop Parameters table", "bin/lib/codex-review-loop/review-rounds.js");
test("C1 Parameters table: a pm-review column with CAP 2, MAX_EXTENSIONS 1, NON_APPROVED_VERDICT NOT_OK", () => {
  const { NON_APPROVED_VERDICT } = require(X.rel("bin/lib/codex-review-loop/review-rounds.js"));
  assert.strictEqual(NON_APPROVED_VERDICT["pm-review"], "NOT_OK");
  const md = fs.readFileSync(X.rel("skills/_shared/codex-review-loop.md"), "utf8").split(/\r?\n/);
  const cells = (l) => l.split("|").slice(1, -1).map((c) => c.trim().replace(/^`|`$/g, ""));
  const head = md.findIndex((l) => /^\|\s*Parameter\s*\|/.test(l) && cells(l).includes("pm-review"));
  assert.ok(head >= 0, "a Parameters table has a pm-review column");
  const col = cells(md[head]).indexOf("pm-review");
  const rows = {};
  for (let i = head + 2; i < md.length && md[i].startsWith("|"); i += 1) rows[cells(md[i])[0]] = cells(md[i])[col];
  assert.strictEqual(rows.CAP, "2");
  assert.strictEqual(rows.MAX_EXTENSIONS, "1");
  assert.strictEqual(String(rows.NON_APPROVED_VERDICT).replace(/:$/, ""), NON_APPROVED_VERDICT["pm-review"]);
});
caseEnd();
