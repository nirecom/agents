"use strict";
// Shared #2961 helpers for the plan presentation turn cases. A plan presentation turn is the turn
// whose stage is ready to be confirmed (the stage's pre-confirm audit admits a confirm); a mid-turn
// is one that wrote a plan the gate will still answer audit-wait / audit-block / proceed for.
// Requires WORKFLOW_STATE_DIR and WORKFLOW_PLANS_DIR pinned by the calling test before require.
const fs = require("fs");
const path = require("path");
const assert = require("node:assert/strict");
const R = require("../feature-2729-presentation-receipt/fixture");
const D = require("../feature-2853-pre-confirm-audit/driver");
const S = require("../../lib/pre-confirm-audit-settle");

const ROOT = R.ROOT;
const mod = (rel) => require(path.join(ROOT, rel));
const show = (x) => { try { return JSON.stringify(x); } catch (_) { return String(x); } };

// need(rel, name) -> the named export of a planned interface; fails the case naming what is missing.
function need(rel, name) {
  const m = R.tryRequire(rel);
  assert.ok(!m.__missing, `${rel} does not load yet: ${m.__missing}`);
  assert.ok(m[name] !== undefined, `${rel} has no export ${name}`);
  return m[name];
}

let tag = 9610;
const at = (stage, o) => R.sessionAt(stage || "outline", Object.assign({ tag: ++tag }, o || {}));

// workflowOff(sid) -> writes the session's WORKFLOW_OFF marker (session-markers isWorkflowOff).
function workflowOff(sid) {
  const dir = R.stateDirOf(sid);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, `${sid}.workflow-off`), "fixture: workflow off\n");
}

// corruptState(sid) -> overwrites the workflow state file with text that does not parse.
function corruptState(sid) {
  const p = mod("hooks/workflow-state/state-io").getStatePath(sid);
  fs.writeFileSync(p, "{ not json");
}

// withKeyThrow(fn) -> fn() while the plan-artifact key functions throw in this process (the
// in-process twin of tests/lib/artifact-key-throw-preload.js).
function withKeyThrow(fn) {
  const fp = mod("hooks/lib/diff-fingerprint");
  const saved = { computeArtifactKey: fp.computeArtifactKey, computeFreshnessKey: fp.computeFreshnessKey };
  for (const k of Object.keys(saved)) fp[k] = () => { throw new Error(`fixture: ${k} failed`); };
  try { return fn(); } finally { Object.assign(fp, saved); }
}

// withReadStateThrow(fn) -> fn() while the supervisor state reader throws, so acceptedOnError throws too.
function withReadStateThrow(fn) {
  const w = mod("hooks/lib/supervisor-state-writer");
  const saved = w.readState;
  w.readState = () => { throw new Error("fixture: readState failed"); };
  try { return fn(); } finally { w.readState = saved; }
}

// The ON duty sentence heads (hooks/lib/plan-link.js keeps them private).
const ON_HEAD = "End this turn's last text block with each line above as-is";
const ON_ONE_HEAD = "End this turn's last text block with the line above as-is";
const OFF_HEAD = "Show each line above once in this step's summary";
const OFF_ONE_HEAD = "Show the line above once in this step's summary";
const PUBLISH_HEAD = "This plan is not published yet";

module.exports = {
  R, D, S, ROOT, mod, show, need, at, workflowOff, corruptState, withKeyThrow, withReadStateThrow,
  ON_HEAD, ON_ONE_HEAD, OFF_HEAD, OFF_ONE_HEAD, PUBLISH_HEAD,
};
