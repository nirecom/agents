#!/usr/bin/env node
"use strict";
// Tests: bin/workflow/next-step, bin/workflow/lib/next-step/verdict.js, bin/workflow/lib/next-step/quiet-exits.js
// Tags: TL2, next-step, workflow-abort, quiet-layer, regression-2920, scope:issue-specific, pwsh-not-required, pm-session
// #2920 S5-5: next-step answers an aborted session from its quiet layer — scenario A (abort-sentinel)
// sends it to /worktree-end until cleanup settles or a downstream adopts it, scenario B (adopt-auto / abort-cli) is done at
// once and names the downstream. paused and workflow-off still win over the abort (order paused -> off -> abort).
// TL3 gap (what this test does NOT catch):
// - /worktree-end reading REASON=workflow-aborted-cleanup in a live session (skill prose).

const { test, after } = require("node:test");
const assert = require("node:assert");
const { spawnSync } = require("node:child_process");
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");
const fs = require("fs");
const os = require("os");
const path = require("path");

const restore = isolate();
const NEUTRAL = fs.mkdtempSync(path.join(os.tmpdir(), "f2920n-"));
fs.mkdirSync(path.join(NEUTRAL, "transcripts-empty"));
// next-step's repo-dir guard compares the state's cwd with the repo it runs in, so every session
// records this throwaway repo as its cwd and next-step runs from it.
const REPO = path.join(NEUTRAL, "repo");
fs.mkdirSync(REPO);
gitInit(REPO);
after(() => {
  restore();
  fs.rmSync(NEUTRAL, { recursive: true, force: true });
});

const X = require("../hooks/feature-2920-workflow-abort/fixture");
const NEXT_STEP = path.join(X.ROOT, "bin", "workflow", "next-step");
const LIB = path.join(X.ROOT, "bin", "workflow", "lib", "next-step");

// nextStep(sid) -> {code, kv, out} of one real next-step run against the pinned dirs.
function nextStep(sid) {
  const env = Object.assign({}, process.env, { CLAUDE_TRANSCRIPT_BASE_DIR: path.join(NEUTRAL, "transcripts-empty") });
  delete env.CLAUDE_CODE_SESSION_ID;
  const r = spawnSync(process.execPath, [NEXT_STEP, "--session", sid], { cwd: REPO, env, encoding: "utf8", timeout: 60000 });
  if (r.error) throw new Error(`next-step did not run: ${r.error.message}`);
  const kv = {};
  for (const line of String(r.stdout).split(/\r?\n/)) {
    const m = line.match(/^([A-Z_]+)=(.*)$/);
    if (m) kv[m[1]] = m[2].replace(/^'(.*)'$/, "$1").replace(/^"(.*)"$/, "$1");
  }
  return { code: r.status, kv, out: `rc=${r.status} stdout=${String(r.stdout).slice(0, 600)} stderr=${String(r.stderr).slice(0, 300)}` };
}
const pick = (r) => [r.kv.ACTION, r.kv.NEXT_SKILL || "", r.kv.REASON];
const writeOff = (sid) => fs.writeFileSync(path.join(process.env.WORKFLOW_STATE_DIR, `${sid}.workflow-off`), "off");
const writePause = (sid) => {
  const ok = X.mod("hooks/lib/next-step-pause-marker").writePauseMarker(sid, { reason: "fixture detour" });
  assert.ok(ok, "fixture: writePauseMarker");
};
const CTXR = { cwd: X.fwd(REPO), git_branch: "master", transcript_path: "/fixture/t/ns.jsonl" };
function seedLive(sid) {
  X.seedPlain(sid, CTXR);
  // An intent with one issue, so the live verdict is not "closes_issues-empty".
  fs.writeFileSync(path.join(process.env.WORKFLOW_PLANS_DIR, `${sid}-intent.md`), "# Intent\n\n## Issues\n\n- #2920\n");
}
function seedAborted(sid, origin, extra) {
  seedLive(sid);
  X.rawAbort(sid, origin, extra);
}

caseBegin("live-session-control", "bin/workflow/next-step");
test("control: a started, not aborted session gets an ordinary verdict", () => {
  seedLive("ns-live");
  const r = nextStep("ns-live");
  assert.strictEqual(r.kv.ACTION, "invoke", r.out);
  assert.ok(!/^workflow-aborted/.test(r.kv.REASON || ""), r.out);
});
caseEnd();

caseBegin("scenario-a-abort-sentinel", "bin/workflow/next-step");
test("S5-5: abort-sentinel with cleanup pending -> invoke worktree-end / workflow-aborted-cleanup", () => {
  seedAborted("ns-a-pending", "abort-sentinel");
  const r = nextStep("ns-a-pending");
  assert.deepStrictEqual(pick(r), ["invoke", "worktree-end", "workflow-aborted-cleanup"], r.out);
});
test("S5-5: abort-sentinel with cleanup complete -> done / workflow-aborted", () => {
  seedAborted("ns-a-done", "abort-sentinel");
  X.pushStep("ns-a-done", "cleanup", "complete");
  const r = nextStep("ns-a-done");
  assert.deepStrictEqual([r.kv.ACTION, r.kv.REASON], ["done", "workflow-aborted"], r.out);
});
test("S5-5: abort-sentinel then adopted by a downstream -> done / workflow-aborted, naming the downstream", () => {
  const F = require("../hooks/feature-2304-inheritance-state-copy/fixture");
  F.seedUpstream("ns-a-adopted");
  X.rawAbort("ns-a-adopted", "abort-sentinel");
  F.seedDownstream("ns-a-adopted-down");
  const a = X.mod("hooks/workflow-state/inheritance/adopt").adoptState({ downstreamSid: "ns-a-adopted-down", upstreamSid: "ns-a-adopted" });
  assert.strictEqual(a && a.ok, true, `adoptState: ${JSON.stringify(a)}`);
  const r = nextStep("ns-a-adopted");
  assert.deepStrictEqual([r.kv.ACTION, r.kv.REASON], ["done", "workflow-aborted"], r.out);
  assert.ok((r.kv.NEXT_HINT || "").includes("ns-a-adopted-down"), `NEXT_HINT must name the downstream: ${r.out}`);
  assert.ok(!/^workflow-aborted/.test(nextStep("ns-a-adopted-down").kv.REASON || ""), "the downstream is not aborted");
});
caseEnd();

caseBegin("scenario-b-downstream-owns-cleanup", "bin/workflow/next-step");
for (const origin of ["adopt-auto", "abort-cli"]) {
  test(`S5-5: ${origin} -> done / workflow-aborted at once, naming the downstream`, () => {
    const sid = `ns-b-${origin}`;
    seedAborted(sid, origin,{ downstream_session_id: `downstream-of-${origin}` });
    const r = nextStep(sid);
    assert.deepStrictEqual([r.kv.ACTION, r.kv.REASON], ["done", "workflow-aborted"], r.out);
    assert.ok((r.kv.NEXT_HINT || "").includes(`downstream-of-${origin}`), `NEXT_HINT must name the downstream: ${r.out}`);
  });
}
caseEnd();

caseBegin("quiet-layer-order", "bin/workflow/next-step");
test("S5-5 order: aborted + paused marker -> next-step-paused", () => {
  seedAborted("ns-o-pause", "abort-sentinel");
  writePause("ns-o-pause");
  const r = nextStep("ns-o-pause");
  assert.deepStrictEqual([r.kv.ACTION, r.kv.REASON], ["paused", "next-step-paused"], r.out);
});
test("S5-5 order: aborted + workflow-off -> workflow-off-quiet", () => {
  seedAborted("ns-o-off", "abort-sentinel");
  writeOff("ns-o-off");
  const r = nextStep("ns-o-off");
  assert.deepStrictEqual([r.kv.ACTION, r.kv.REASON], ["paused", "workflow-off-quiet"], r.out);
});
test("S5-5 order: aborted + paused + workflow-off -> next-step-paused", () => {
  seedAborted("ns-o-both", "adopt-auto");
  writePause("ns-o-both");
  writeOff("ns-o-both");
  const r = nextStep("ns-o-both");
  assert.deepStrictEqual([r.kv.ACTION, r.kv.REASON], ["paused", "next-step-paused"], r.out);
});
caseEnd();

caseBegin("quiet-exits-module", "bin/workflow/lib/next-step/quiet-exits.js");
test("S5-5: quiet-exits.js exports resolveQuietExit", () => {
  let m;
  try { m = require(path.join(LIB, "quiet-exits.js")); } catch (e) { assert.fail(`quiet-exits.js not loadable: ${String(e.message).split("\n")[0]}`); }
  assert.strictEqual(typeof m.resolveQuietExit, "function");
});
caseEnd();

// #2941: a session carrying the PM mark (active or archived) gets the non-resumable `ACTION=paused REASON=pm-session`,
// never `invoke workflow-init`; the HINT tells an active PM from a finished one.
const P = require("../lib/pm-state-fixture");
function seedPmSession(sid, archivedAt) {
  seedLive(sid);
  const st = P.raw(sid);
  st.pm = P.pm({ tag: `PM-ns${archivedAt ? "x" : "a"}`, issues: [2941], archived_at: archivedAt });
  P.writeRaw(sid, st);
}
caseBegin("pm-session-quiet-exit-2941", "bin/workflow/lib/next-step/quiet-exits.js");
test("#2941: active and archived PM sessions -> ACTION=paused REASON=pm-session, not invoke workflow-init", () => {
  seedPmSession("ns-pm-active", null);
  seedPmSession("ns-pm-archived", "2026-11-02T00:00:00.000Z");
  const a = nextStep("ns-pm-active");
  const z = nextStep("ns-pm-archived");
  for (const r of [a, z]) {
    assert.deepStrictEqual([r.kv.ACTION, r.kv.REASON], ["paused", "pm-session"], r.out);
    assert.notStrictEqual(r.kv.NEXT_SKILL, "workflow-init", r.out);
  }
  assert.ok((a.kv.NEXT_HINT || "").length > 0 && (z.kv.NEXT_HINT || "").length > 0, `${a.out}\n${z.out}`);
  assert.notStrictEqual(a.kv.NEXT_HINT, z.kv.NEXT_HINT, "the HINT must tell an active PM from an archived one");
});
test("#2941 control: the same session without the PM mark is not pm-session", () => {
  seedLive("ns-pm-control");
  assert.notStrictEqual(nextStep("ns-pm-control").kv.REASON, "pm-session");
});
// A real PM session never starts a workflow: its state is a fresh state plus the `pm` key only.
test("#2941: not-started state carrying only pm (active and archived) -> ACTION=paused REASON=pm-session", () => {
  for (const [sid, archivedAt] of [["ns-pm-ns-active", null], ["ns-pm-ns-archived", "2026-11-02T00:00:00.000Z"]]) {
    P.seedPm(sid, P.pm({ tag: "PM-nsns", issues: [2941], archived_at: archivedAt }), { ctx: CTXR });
    assert.strictEqual(P.wfInitStatus(sid), "pending", "premise: workflow not started");
    const r = nextStep(sid);
    assert.deepStrictEqual([r.kv.ACTION, r.kv.REASON], ["paused", "pm-session"], r.out);
    assert.notStrictEqual(r.kv.NEXT_SKILL || "", "workflow-init", r.out);
  }
});
test("#2941 control: not-started state without pm -> invoke workflow-init", () => {
  P.seedState("ns-pm-ns-control", { ctx: CTXR });
  const r = nextStep("ns-pm-ns-control");
  assert.deepStrictEqual([r.kv.ACTION, r.kv.NEXT_SKILL], ["invoke", "workflow-init"], r.out);
});
// `pm` that is not an object is no PM mark (hasPmMark). [] is left out: it is typeof "object" and counts as a mark today.
for (const [label, bad] of [["null", null], ["string", "x"], ["true", true], ["zero", 0]]) {
  test(`#2941: pm=${label} on a not-started state is not a PM session -> invoke workflow-init`, () => {
    const sid = `ns-pm-bad-${label}`;
    P.seedPm(sid, bad, { ctx: CTXR });
    const r = nextStep(sid);
    assert.notStrictEqual(r.kv.REASON, "pm-session", r.out);
    assert.deepStrictEqual([r.kv.ACTION, r.kv.NEXT_SKILL], ["invoke", "workflow-init"], r.out);
  });
}
caseEnd();

// #2941: the PM session reason (`pm-session`) is checked before paused / workflow-off / aborted, and its paused is non-resumable.
caseBegin("pm-session-quiet-order-2941", "bin/workflow/lib/next-step/quiet-exits.js");
const assertPmQuiet = (r) => {
  assert.deepStrictEqual([r.kv.ACTION, r.kv.REASON], ["paused", "pm-session"], r.out);
  assert.notStrictEqual(r.kv.NEXT_SKILL || "", "worktree-end", r.out);
  const hint = r.kv.NEXT_HINT || "";
  for (const s of ["WORKFLOW_NEXT_STEP_RESUME", "WORKFLOW_ENFORCE_WORKFLOW_ON"]) assert.ok(!hint.includes(s), `NEXT_HINT must not offer ${s}: ${r.out}`);
};
test("#2941 order: active PM + paused marker -> pm-session, no resume sentinel in the HINT", () => {
  seedPmSession("ns-pmo-pause", null);
  writePause("ns-pmo-pause");
  assertPmQuiet(nextStep("ns-pmo-pause"));
});
test("#2941 order: active PM + workflow-off -> pm-session, no restore sentinel in the HINT", () => {
  seedPmSession("ns-pmo-off", null);
  writeOff("ns-pmo-off");
  assertPmQuiet(nextStep("ns-pmo-off"));
});
test("#2941 order: active PM + abort sentinel -> pm-session, not invoke worktree-end", () => {
  seedPmSession("ns-pmo-abort", null);
  X.rawAbort("ns-pmo-abort", "abort-sentinel");
  assertPmQuiet(nextStep("ns-pmo-abort"));
});
test("#2941 order: archived PM + paused marker -> still pm-session", () => {
  seedPmSession("ns-pmo-arch-pause", "2026-11-02T00:00:00.000Z");
  writePause("ns-pmo-arch-pause");
  assertPmQuiet(nextStep("ns-pmo-arch-pause"));
});
caseEnd();

// #2941: the PM session check is fail-open — a corrupt state file is no PM mark and no crash.
caseBegin("pm-session-corrupt-state-2941", "bin/workflow/lib/next-step/quiet-exits.js");
test("#2941: corrupt state JSON -> next-step does not crash, prints ACTION=, REASON is not pm-session", () => {
  fs.writeFileSync(P.statePath("ns-pm-corrupt"), "{not json");
  const r = nextStep("ns-pm-corrupt");
  assert.ok(r.code !== null && !/^\s+at /m.test(r.out), `no crash (no uncaught stack): ${r.out}`);
  assert.ok(typeof r.kv.ACTION === "string" && r.kv.ACTION.length > 0, `an ACTION= line: ${r.out}`);
  assert.notStrictEqual(r.kv.REASON, "pm-session", r.out);
});
caseEnd();

caseBegin("verdict-size", "bin/workflow/lib/next-step/verdict.js");
test("S5-5: verdict.js stays within the 500-line HARD limit", () => {
  const text = fs.readFileSync(path.join(LIB, "verdict.js"), "utf8");
  const n = text.split("\n").length - (text.endsWith("\n") ? 1 : 0);
  assert.ok(n <= 500, `verdict.js has ${n} lines`);
});
caseEnd();
