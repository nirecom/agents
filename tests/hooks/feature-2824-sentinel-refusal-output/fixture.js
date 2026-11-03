"use strict";
// Fixture for tests/hooks/feature-2824-sentinel-refusal-output.js. The entry calls isolate() first,
// so WORKFLOW_STATE_DIR / WORKFLOW_PLANS_DIR are pinned and CLAUDE_CODE_SESSION_ID is unset before
// any hook runs. make() pins the config (CONFIRM_* on) and an empty transcript base dir.

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { gitInit } = require("../../lib/harness");
const O = require("../../lib/workflow-mark-output");

function make() {
  const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2824-refusal-"));
  const CFG = path.join(TMP, "cfg");
  const REPO = path.join(TMP, "repo");
  const HOME = path.join(TMP, "home");
  for (const d of [CFG, HOME, path.join(TMP, "transcripts")]) fs.mkdirSync(d);
  gitInit(REPO);
  process.env.AGENTS_MAIN_ROOT = CFG;
  process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(TMP, "transcripts");
  for (const k of ["CONFIRM_INTENT", "CONFIRM_OUTLINE", "CONFIRM_DETAIL", "WORKFLOW_SESSION_ID", "CLAUDE_PROJECT_DIR", "CONV_LANG"]) {
    delete process.env[k];
  }
  const show = (v) => JSON.stringify(v);
  const F = require("../feature-2709-approval-bypass-closure/fixture").make({ TMP, CFG, eq: assert.deepStrictEqual, ok: assert.ok, show });
  F.setConfig("on", "on", "on");

  let n = 0;
  const nextSid = (tag) => `f2824-${tag}-${++n}`;
  const statePath = (sid) => path.join(process.env.WORKFLOW_STATE_DIR, `${sid}.json`);
  const raw = (sid) => { try { return fs.readFileSync(statePath(sid), "utf8"); } catch (_) { return ""; } };
  function seedInit(tag) {
    const sid = nextSid(tag);
    F.S.markStep(sid, "workflow_init", "complete");
    return sid;
  }
  // corruptState(tag) -> sid whose state file is not JSON: the state writer throws inside a handler,
  // which reaches the handler's "failed to write state" catch.
  function corruptState(tag) {
    const sid = nextSid(tag);
    fs.writeFileSync(statePath(sid), "{not json");
    return sid;
  }
  // mark(sid, command, {exitCode, agentId, noSession, toolUseId, projectDir}) -> {code, stdout, stderr}.
  // projectDir pins CLAUDE_PROJECT_DIR, so a repo-evidence check reads that repo and never the
  // state's recorded cwd (the test runner's own checkout).
  function mark(sid, command, o = {}) {
    const env = { USER: "tester-2824", USERNAME: "tester-2824", LOGNAME: "tester-2824" };
    if (o.noSession) Object.assign(env, { HOME, USERPROFILE: HOME });
    if (o.projectDir) env.CLAUDE_PROJECT_DIR = o.projectDir;
    const p = { sid: o.noSession ? null : sid, cwd: REPO, exitCode: o.exitCode, agentId: o.agentId, toolUseId: o.toolUseId };
    return O.runMark(O.bashPayload(command, p), { env, cwd: o.noSession ? TMP : REPO });
  }

  // Each row collects its failures; check() throws them together so one run names every miss.
  const misses = [];
  const record = (label, why) => { if (why) misses.push(`${label}: ${why}`); };
  function guard(label, fn) {
    try { record(label, fn()); } catch (e) { record(label, e.message); }
  }
  // expectUnapplied(label, sid, command, pattern, opts) — strong channel and state bytes unchanged.
  function expectUnapplied(label, sid, command, pattern, o = {}) {
    const before = raw(sid);
    const r = mark(sid, command, o);
    if (raw(sid) !== before) record(label, "state changed by a refused sentinel");
    guard(label, () => O.unappliedFailure(r, pattern));
    return r;
  }
  function expectInfo(label, sid, command, pattern, o = {}) {
    const r = mark(sid, command, o);
    guard(label, () => O.infoFailure(r, pattern));
    return r;
  }
  function expectSilent(label, sid, command, o = {}) {
    guard(label, () => O.silentFailure(mark(sid, command, o)));
  }
  function check() {
    const all = misses.splice(0);
    if (all.length > 0) throw new Error(`${all.length} miss(es):\n  ${all.join("\n  ")}`);
  }
  const cleanup = () => fs.rmSync(TMP, { recursive: true, force: true });
  return { TMP, CFG, REPO, HOME, F, nextSid, seedInit, corruptState, raw, mark, record, expectUnapplied, expectInfo, expectSilent, check, cleanup };
}

module.exports = { make };
