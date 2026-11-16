#!/usr/bin/env node
// Test-only helper for tests/hooks/TL3-hook-reset-from-gate.sh (WORKFLOW_STATE_DIR is pinned by
// the caller):
//   node seed.js --seed <sid> <cwd> <prior-resets>  -> a session standing at review_security after
//                                                      <prior-resets> resets to write_code
//   node seed.js --reset-reasons <sid>              -> the recorded reset reasons, one per line
// Events are written at the stream level, as the writers store them, so the live hook reads a
// state no test code produced through the hook itself.
"use strict";

const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..", "..", "..");
const io = require(path.join(ROOT, "hooks", "workflow-state", "state-io"));
const STEPS = io.VALID_STEPS;
const GATED = ["clarify_intent", "outline", "detail"];
const CURRENT = "review_security";
const TARGET = "write_code";
const ORIGIN = "tl3-reset-from-gate";

const idx = (step) => {
  const i = STEPS.indexOf(step);
  if (i === -1) throw new Error(`seed: unknown step ${step}`);
  return i;
};
const st = (step, status, origin) => ({ kind: "step_status", step, status, provenance: "declared", origin: origin || ORIGIN });
const approval = (step) => ({
  kind: "plan_approval", step, source: "session-inherit", reason: "fixture approval",
  artifact_sha256: null, artifact_session_id: null, artifact_hash_status: "unknown",
  provenance: "declared", origin: ORIGIN,
});
function completeRange(from, to) {
  const out = [];
  for (let i = idx(from); i < idx(to); i++) {
    if (GATED.includes(STEPS[i])) out.push(approval(STEPS[i]));
    out.push(st(STEPS[i], "complete"));
  }
  return out;
}
// The batch hooks/workflow-mark/reset-handler.js writes for RESET_FROM_<target>.
function resetEvents(target, reason) {
  const t = idx(target);
  const out = [{ kind: "reset", from_step: target, reason, provenance: "declared", origin: "reset-sentinel" }];
  for (let i = 0; i < t; i++) out.push(st(STEPS[i], "complete", "reset-sentinel"));
  for (let i = t; i < STEPS.length; i++) {
    out.push({ kind: "step_annotations_cleared", step: STEPS[i], provenance: "declared", origin: "reset-sentinel" });
    out.push(st(STEPS[i], "pending", "reset-sentinel"));
  }
  return out;
}
const statePath = (sid) => path.join(process.env.WORKFLOW_STATE_DIR, `${sid}.json`);

function seed(sid, cwd, prior) {
  const events = completeRange("workflow_init", CURRENT);
  for (let n = 1; n <= prior; n++) {
    events.push(...resetEvents(TARGET, `tl3 prior reset ${n}`));
    events.push(...completeRange(TARGET, CURRENT));
  }
  const s = io.createInitialState(sid, { cwd: String(cwd).replace(/\\/g, "/"), git_branch: "feature/tl3-reset-from", transcript_path: "/fixture/tl3.jsonl" });
  s.deliverable_type = "wf-code";
  s.delivery_path = "pull_request";
  s.auto_merge_pr = "on";
  const t0 = Date.UTC(2026, 0, 1);
  s.events = events.map((e, i) => Object.assign({ at: new Date(t0 + i * 60000).toISOString() }, e, { seq: i + 1 }));
  fs.writeFileSync(statePath(sid), JSON.stringify(s, null, 2), "utf8");
}

function resetReasons(sid) {
  let s;
  try { s = JSON.parse(fs.readFileSync(statePath(sid), "utf8")); } catch (_e) { return "<no-state>"; }
  return (s.events || []).filter((e) => e.kind === "reset").map((e) => String(e.reason)).join("\n");
}

const [mode, sid, a, b] = process.argv.slice(2);
if (mode === "--seed") seed(sid, a, Number(b) || 0);
else if (mode === "--reset-reasons") process.stdout.write(resetReasons(sid));
else { console.error(`BAD_MODE:${mode}`); process.exit(2); }
