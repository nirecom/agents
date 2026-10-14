"use strict";
// Shared #2650 fixture: sessions sitting at one plan stage, transcripts whose entries carry
// uuids, turn markers written through hooks/lib/turn-marker.js, and a Stop-hook runner.
// Used by the drivers of ../feature-2650-confirm-continuation.sh (incl. ./plan-gate.sh via
// gate-driver.js), ../feature-stop-guard-layer2/ and ../feature-2513-confirm-turn-split/ (samturn-driver.js).
// Requires WORKFLOW_STATE_DIR and WORKFLOW_PLANS_DIR pinned by the calling test.
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const F = require("../feature-2277-plan-approval-gate/fixture");

const ROOT = F.ROOT;
const STEP = { intent: "clarify_intent", outline: "outline", detail: "detail" };
const STAGES = ["intent", "outline", "detail"];
const SPAWN_PRELOAD = path.join(__dirname, "spawn-count-preload.js");
const PUBLISH_STUB = path.join(ROOT, "tests", "hooks", "feature-2513-confirm-turn-split", "publish-stub.js");
const BLOB = "https://example.invalid/test-owner/test-repo/blob/main/";
// Inside the pinned state dir, so the calling test's cleanup removes it.
const TDIR = path.join(F.STATE_DIR, "cc-transcripts");
fs.mkdirSync(TDIR, { recursive: true });

let seq = 0;
const hex = (n, w) => String(n).padStart(w, "0");
// uuidSid(prefix4) -> a UUID-shaped session id (plan-link accepts only UUIDs).
function uuidSid(tag) {
  seq += 1;
  return `2650${hex(tag || 0, 4)}-${hex(seq, 4)}-4aaa-8bbb-${hex(process.pid % 1e12, 12)}`;
}

// Transcript entries. `uuid` is optional on every builder; omitted, the entry carries none.
const U = (text, uuid) => Object.assign({ type: "user", message: { role: "user", content: text } }, uuid ? { uuid } : {});
const UMETA = (text, uuid) => Object.assign({ type: "user", isMeta: true, message: { role: "user", content: text } }, uuid ? { uuid } : {});
const STOPFB = (reason, uuid) => UMETA("Stop hook feedback:\n" + reason, uuid);
const A = (uuid, ...content) => Object.assign({ type: "assistant", message: { role: "assistant", content } }, uuid ? { uuid } : {});
const T = (text) => ({ type: "text", text });
const W = (file_path, id) => ({ type: "tool_use", id: id || "w1", name: "Write", input: { file_path, content: "rewritten" } });
const BASH = (command, id) => ({ type: "tool_use", id: id || "b1", name: "Bash", input: { command } });
const TR = (id, uuid) => Object.assign({ type: "user", message: { role: "user", content: [{ type: "tool_result", tool_use_id: id || "w1", content: "ok" }] } }, uuid ? { uuid } : {});
const echoOf = (stage) => `echo "<<WORKFLOW_CONFIRM_${stage.toUpperCase()}: approve the ${stage} plan>>"`;
const ECHO = (stage, id) => BASH(echoOf(stage), id || "e1");

// sessionAt(stage, opts) -> {sid, stage, step, plan, fwd, line, urlLine}: a session whose current
// step is the stage's step, every earlier gated stage approved, every plan up to the stage on disk.
// opts.approved: also record an approval of the stage itself at the current sha.
function sessionAt(stage, opts) {
  const o = opts || {};
  const sid = uuidSid(o.tag);
  const steps = { workflow_init: "complete", clarify_intent: "pending" };
  const approvals = [];
  F.writePlan(sid, "intent", o.body && stage === "intent" ? o.body : undefined);
  if (stage !== "intent") {
    Object.assign(steps, { clarify_intent: "complete", research: "complete", outline: "pending" });
    approvals.push({ step: "clarify_intent" });
    F.writePlan(sid, "outline", o.body && stage === "outline" ? o.body : undefined);
  }
  if (stage === "detail") {
    Object.assign(steps, { outline: "complete", detail: "pending" });
    approvals.push({ step: "outline" });
    F.writePlan(sid, "detail", o.body);
  }
  if (o.approved) approvals.push({ step: STEP[stage] });
  F.writeState(sid, steps, approvals);
  return Object.assign({ sid, stage, step: STEP[stage] }, linesFor(sid, stage));
}

// linesFor(sid, stage) -> the plan path and its plan-link lines (local and published forms).
function linesFor(sid, stage) {
  const plan = path.resolve(F.planPath(sid, stage));
  const fwd = plan.replace(/\\/g, "/");
  return {
    plan, fwd,
    line: `${stage}: \`${fwd}\` (no URL: plan-sync-off)`,
    url: BLOB + path.basename(plan),
    urlLine: `${stage}: ${BLOB + path.basename(plan)} (\`${fwd}\`)`,
  };
}

function turnMarker(sid, stage, absPath) {
  const { writeTurnMarker } = require(path.join(ROOT, "hooks/lib/turn-marker"));
  return writeTurnMarker(sid, { session_id: sid, absPath, suffix: stage, ts: Date.now() });
}

function stateDirOf(sid) {
  return require(path.join(ROOT, "hooks/workflow-state")).getSessionStateDir(sid);
}
const markPath = (sid, stage) => path.join(stateDirOf(sid), `${sid}.confirm-plan-continue-${stage}.json`);
const turnMarkersLeft = (sid) => {
  try { return fs.readdirSync(stateDirOf(sid)).filter((n) => n.startsWith(`${sid}.confirm-plan-turn-`)).length; } catch (_) { return 0; }
};
function readMark(sid, stage) {
  try { return JSON.parse(fs.readFileSync(markPath(sid, stage), "utf8")); } catch (_) { return null; }
}

function writeTranscript(sid, entries) {
  const tp = path.join(TDIR, `t-${sid}-${++seq}.jsonl`);
  fs.writeFileSync(tp, entries.map((e) => JSON.stringify(e)).join("\n") + "\n");
  return tp;
}

// tryRequire(rel) -> the module, or {__missing: message} when it does not load yet.
function tryRequire(rel) {
  try { return require(path.join(ROOT, rel)); } catch (e) { return { __missing: (e && (e.code || e.message)) || "load failed" }; }
}

// gateEnv(on) -> every CONFIRM_* pinned; `over` overrides single keys.
function gateEnv(over) {
  return Object.assign({ CONFIRM_INTENT: "on", CONFIRM_OUTLINE: "on", CONFIRM_DETAIL: "on", PLAN_LANG: "english", PLAN_SYNC_REMOTE_URL: "" }, over || {});
}

// noBashEnv(env) -> env with every PATH spelling pointed at an empty dir, so spawning "bash"
// (the gate probe) fails with ENOENT. The hook itself is spawned by absolute node path.
function noBashEnv(env) {
  for (const k of Object.keys(env)) if (/^path$/i.test(k)) delete env[k];
  const empty = path.join(TDIR, "empty-path");
  fs.mkdirSync(empty, { recursive: true });
  env.PATH = empty;
  return env;
}

// runStop(sid, tpath, opts) -> {rc, out, json, reason, ms, spawns}. opts.emptyPath breaks the probe. opts.env overrides gateEnv();
// opts.input merges into the hook input; opts.publish loads the publish stub; opts.count logs probes.
function runStop(sid, tpath, opts) {
  const o = opts || {};
  const env = Object.assign({}, process.env, gateEnv(o.env));
  delete env.CLAUDE_CODE_SESSION_ID;
  if (o.emptyPath) noBashEnv(env);
  const pre = (o.preloads || []).slice();
  let log = null;
  if (o.publish) { pre.push(PUBLISH_STUB); env.PLAN_SYNC_REMOTE_URL = "https://example.invalid/test-owner/test-repo.git"; }
  if (o.count) {
    log = path.join(TDIR, `spawns-${sid}-${++seq}.log`);
    env.CC_SPAWN_LOG = log;
    pre.push(SPAWN_PRELOAD);
  }
  // Forward slashes: NODE_OPTIONS treats a backslash inside double quotes as an escape.
  if (pre.length) env.NODE_OPTIONS = pre.map((p) => `--require "${p.replace(/\\/g, "/")}"`).join(" ");
  const input = Object.assign({ session_id: sid, transcript_path: tpath, hook_event_name: "Stop", stop_hook_active: false }, o.input || {});
  const t0 = Date.now();
  const r = spawnSync(process.execPath, [path.join(ROOT, "hooks/stop-confirm-plan-guard.js")], {
    input: JSON.stringify(input), env, encoding: "utf8", timeout: 60000, cwd: TDIR,
  });
  const ms = Date.now() - t0;
  const out = r.stdout || "";
  let json = {};
  try { json = out ? JSON.parse(out) : {}; } catch (_) { json = { unparsed: out }; }
  let spawns = null;
  if (log) { try { spawns = fs.readFileSync(log, "utf8").split("\n").filter(Boolean).length; } catch (_) { spawns = 0; } }
  return { rc: r.status, out, err: r.stderr || "", json, reason: typeof json.reason === "string" ? json.reason : "", ms, spawns };
}

const show = (x) => { try { return JSON.stringify(x); } catch (_) { return String(x); } };

module.exports = {
  F, ROOT, STEP, STAGES, BLOB, TDIR, SPAWN_PRELOAD, PUBLISH_STUB,
  uuidSid, U, UMETA, STOPFB, A, T, W, BASH, TR, ECHO, echoOf,
  sessionAt, linesFor, turnMarker, stateDirOf, markPath, readMark, turnMarkersLeft,
  writeTranscript, tryRequire, gateEnv, noBashEnv, runStop, show, check: F.check,
};
