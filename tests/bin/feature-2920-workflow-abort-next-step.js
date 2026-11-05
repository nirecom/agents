#!/usr/bin/env node
"use strict";
// Tests: bin/workflow/next-step, bin/workflow/lib/next-step/verdict.js, bin/workflow/lib/next-step/quiet-exits.js
// Tags: TL2, next-step, workflow-abort, quiet-layer, regression-2920, scope:issue-specific, pwsh-not-required
// #2920 S5-5: next-step answers an aborted session from its quiet layer — scenario A (abort-sentinel)
// sends it to /worktree-end until cleanup settles or a downstream adopts it, scenario B (adopt-auto / abort-cli) is done at
// once and names the heir. paused and workflow-off still win over the abort (order paused -> off -> abort).
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
  const a = X.mod("hooks/workflow-state/inheritance/adopt").adoptState({ heirSid: "ns-a-adopted-down", donorSid: "ns-a-adopted" });
  assert.strictEqual(a && a.ok, true, `adoptState: ${JSON.stringify(a)}`);
  const r = nextStep("ns-a-adopted");
  assert.deepStrictEqual([r.kv.ACTION, r.kv.REASON], ["done", "workflow-aborted"], r.out);
  assert.ok((r.kv.NEXT_HINT || "").includes("ns-a-adopted-down"), `NEXT_HINT must name the downstream: ${r.out}`);
  assert.ok(!/^workflow-aborted/.test(nextStep("ns-a-adopted-down").kv.REASON || ""), "the downstream is not aborted");
});
caseEnd();

caseBegin("scenario-b-heir-owns-cleanup", "bin/workflow/next-step");
for (const origin of ["adopt-auto", "abort-cli"]) {
  test(`S5-5: ${origin} -> done / workflow-aborted at once, naming the heir`, () => {
    const sid = `ns-b-${origin}`;
    seedAborted(sid, origin,{ heir_session_id: `heir-of-${origin}` });
    const r = nextStep(sid);
    assert.deepStrictEqual([r.kv.ACTION, r.kv.REASON], ["done", "workflow-aborted"], r.out);
    assert.ok((r.kv.NEXT_HINT || "").includes(`heir-of-${origin}`), `NEXT_HINT must name the heir: ${r.out}`);
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

caseBegin("verdict-size", "bin/workflow/lib/next-step/verdict.js");
test("S5-5: verdict.js stays within the 500-line HARD limit", () => {
  const text = fs.readFileSync(path.join(LIB, "verdict.js"), "utf8");
  const n = text.split("\n").length - (text.endsWith("\n") ? 1 : 0);
  assert.ok(n <= 500, `verdict.js has ${n} lines`);
});
caseEnd();
