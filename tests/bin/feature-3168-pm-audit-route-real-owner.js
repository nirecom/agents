"use strict";
// Tests: bin/workflow/lib/next-step/pm-audit-route.js, bin/lib/pm-state/owner.js
// Tags: TL2, scope:issue-specific, issue-3168, pm-session, pre-confirm-audit, next-step-gate, batched-owner, pm-field
// #3168 end to end through the real owner chain: the plan stage gate (`next-step --gate --audit-route pm[:<tag>]`)
// resolves the owners of every closed issue with ONE gh owner read. Nothing between the gate and gh is stubbed
// (pmCandidatesOf -> decidedOwnersOf -> ownersOf -> resolveOwnersBatch -> readPmChains -> gh); only gh is the fake
// of tests/bin/feature-2941-pm-state-cli. A return to one gh call per issue fails the call count here.
// TL3 gap (what this test does NOT catch):
// - a real GitHub GraphQL endpoint answering the batched query within the gate's 4000 ms bound (the fake gh answers instantly).

const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { test, after } = require("node:test");
const assert = require("node:assert");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

delete process.env.CLAUDE_CODE_SESSION_ID;
const restore = isolate();
// The gate child must not load any owner stub: no preload may reach it through NODE_OPTIONS.
delete process.env.NODE_OPTIONS;
const D = require("../hooks/feature-2853-pre-confirm-audit/driver");
const P = require("../lib/pm-state-fixture");
const { ghEnv } = require("./feature-2941-pm-state-cli/gh-env");
const G = ghEnv("pm-3168-real-owner-gh-");
after(() => { G.restore(); restore(); });

const { X } = D;
const REPO = "example-owner/example-repo";
const at = (n) => `${REPO}#${n}`;
const own = (nums) => nums.map((number) => ({ number, repo: REPO }));
// Owner reads are the gh calls whose GraphQL reads issue nodes; nothing else the gate runs asks for projectItems.
const ownerReads = (qs) => qs.filter((q) => /issue\(number:\s*\d+/.test(q) && /projectItems/.test(q));
const numsIn = (q) => [...new Set((q.match(/issue\(number:\s*(\d+)/g) || []).map((m) => m.replace(/\D/g, "")))].sort();

// session(issues) -> an outline-stage session (audit unsettled) whose intent closes REPO#<n>.
function session(issues) {
  const s = X.sessionAt("outline", { audit: false });
  const refs = issues.map((n) => `- ${at(n)} fixture`).join("\n");
  X.F.writePlan(s.sid, "intent", `# Intent\n\n## Goal\n\nfixture goal\n\n## Issues\n\n${refs}\n\n## Constraints\n\nnone\n`);
  return s.sid;
}
function gate(sid, args) {
  const env = D.childEnv({}, {});
  delete env.NODE_OPTIONS;
  const r = spawnSync(process.execPath, [path.join(D.ROOT, "bin/workflow/next-step"), "--gate", "--session", sid].concat(args), {
    env, encoding: "utf8", timeout: 60000, cwd: X.TDIR,
  });
  return Object.assign({ rc: r.status, out: r.stdout || "", err: r.stderr || "" }, D.parseGate(r.stdout));
}
const runOf = (g) => (g.lines && g.lines.GATE_AUDIT_RUN_ID) || "";
// destOf(sid, runId, pmSid) -> whether a route:pm-dest finding of runId names pmSid.
function destOf(sid, runId, pmSid) {
  const st = require(path.join(D.ROOT, "hooks/lib/supervisor-state-writer")).readState(sid) || {};
  const fs0 = (st.audit && st.audit.findings) || [];
  return fs0.some((f) => f && f.reporter === "route:pm-dest" && String(f.detail || "").includes(runId) && JSON.stringify(f).includes(pmSid));
}
const show = (g, qs) => `rc=${g.rc}\nout=${g.out.slice(0, 1500)}\nerr=${g.err.slice(0, 800)}\ngh=${JSON.stringify(qs.map((q) => q.slice(0, 160)))}`;

const PM_A = P.uuid(0x31680a01);
const PM_B = P.uuid(0x31680b01);
P.seedPm(PM_A, P.pm({ tag: "PM-real-a", issues: own([3971, 3972, 3973, 3974, 3975]) }));
P.seedPm(PM_B, P.pm({ tag: "PM-real-b", issues: own([3976, 3977]) }));
G.setMap({
  [at(3971)]: { pm: "PM-real-a" }, [at(3972)]: { pm: "PM-real-a" }, [at(3973)]: { pm: "PM-real-a" },
  [at(3974)]: { pm: "PM-real-a" }, [at(3975)]: { pm: "PM-real-a" }, [at(3976)]: { pm: "PM-real-b" }, [at(3977)]: { pm: "PM-real-b" },
});
assert.ok(fs.existsSync(P.statePath(PM_A)) && fs.existsSync(P.statePath(PM_B)), "PM states seeded");

caseBegin("real-owner-chain-one-gh-read", "bin/lib/pm-state/owner.js");
test("R1 3 issues of one PM through the real owner chain: --audit-route pm arms with that PM, one gh owner read carries all 3", () => {
  const sid = session([3971, 3972, 3973]);
  const before = G.queries().length;
  const g = gate(sid, ["--audit-route", "pm"]);
  const qs = G.queries().slice(before);
  const reads = ownerReads(qs);
  assert.ok(runOf(g) !== "", `the gate armed a pm run: ${show(g, qs)}`);
  assert.ok(destOf(sid, runOf(g), PM_A), `the run's destination is PM-real-a: ${show(g, qs)}`);
  assert.strictEqual(reads.length, 1, `exactly one gh owner read (not one per issue): ${show(g, qs)}`);
  assert.deepStrictEqual(numsIn(reads[0]), ["3971", "3972", "3973"], `the one read carries every issue: ${show(g, qs)}`);
});
caseEnd();

caseBegin("real-owner-chain-pm-tag-pick", "bin/workflow/lib/next-step/pm-audit-route.js");
test("R2 4 issues of 2 PMs through the real owner chain: --audit-route pm:<B> arms with B, one gh owner read carries all 4", () => {
  const sid = session([3974, 3975, 3976, 3977]);
  const before = G.queries().length;
  const g = gate(sid, ["--audit-route", "pm:PM-real-b"]);
  const qs = G.queries().slice(before);
  const reads = ownerReads(qs);
  const run = runOf(g);
  assert.ok(run !== "", `the gate armed a pm run: ${show(g, qs)}`);
  assert.ok(destOf(sid, run, PM_B) && !destOf(sid, run, PM_A), `destination B only: ${show(g, qs)}`);
  assert.strictEqual(reads.length, 1, `exactly one gh owner read: ${show(g, qs)}`);
  assert.deepStrictEqual(numsIn(reads[0]), ["3974", "3975", "3976", "3977"], `the one read carries every issue: ${show(g, qs)}`);
});
caseEnd();

// The gate bound (GATE_OWNER_TIMEOUT_MS 4000) must reach the gh spawn; the hook bound (OWNER_TIMEOUT_MS 2000) must not.
// A gh answer slower than 2000 ms but well inside 4000 ms (spawn overhead included) tells the two apart.
const SLOW_GH_MS = 2500;
caseBegin("real-owner-chain-gate-timeout-bound", "bin/workflow/lib/next-step/pm-audit-route.js");
test("R3 a gh owner read slower than the hook bound and inside the gate bound: --audit-route pm still arms with the PM", () => {
  const sid = session([3971, 3972, 3973]);
  const before = G.queries().length;
  G.sleep(SLOW_GH_MS);
  const t0 = Date.now();
  let g;
  try { g = gate(sid, ["--audit-route", "pm"]); } finally { G.sleep(null); }
  const elapsed = Date.now() - t0;
  const qs = G.queries().slice(before);
  const reads = ownerReads(qs);
  assert.strictEqual(reads.length, 1, `exactly one gh owner read: ${show(g, qs)}`);
  assert.deepStrictEqual(numsIn(reads[0]), ["3971", "3972", "3973"], `the one read carries every issue: ${show(g, qs)}`);
  assert.ok(runOf(g) !== "", `the gate armed a pm run despite the slow gh (elapsed ${elapsed} ms): ${show(g, qs)}`);
  assert.ok(destOf(sid, runOf(g), PM_A), `the run's destination is PM-real-a: ${show(g, qs)}`);
  // Checked after the route: a bound that kills gh early also cuts elapsed short, and the route names that cause.
  assert.ok(elapsed >= SLOW_GH_MS, `the gh delay took effect (elapsed ${elapsed} ms): ${show(g, qs)}`);
});
caseEnd();
