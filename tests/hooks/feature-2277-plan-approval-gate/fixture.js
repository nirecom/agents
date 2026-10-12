"use strict";
// Shared #2277 fixture builder: raw v2 state files + plan artifacts inside the pinned
// WORKFLOW_STATE_DIR / WORKFLOW_PLANS_DIR, and a PASS|name / FAIL|name|detail reporter.
// State is written raw (never through appendEvents) so an unapproved gated `complete`
// can be seeded without tripping the completion boundary the tests exercise.
// Used by the feature-2277 drivers under tests/hooks and tests/bin.

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const ROOT = path.resolve(__dirname, "..", "..", "..");
const STATE_DIR = process.env.WORKFLOW_STATE_DIR;
const PLANS_DIR = process.env.WORKFLOW_PLANS_DIR;
if (!STATE_DIR || !PLANS_DIR) {
  console.log("FAIL|fixture|WORKFLOW_STATE_DIR / WORKFLOW_PLANS_DIR must both be pinned");
  process.exit(0);
}

const SUFFIX = { clarify_intent: "intent", outline: "outline", detail: "detail" };
const PLAN_BODY = {
  intent: "# Intent\n\n## Goal\n\nfixture goal\n\n## Issues\n\n- #1 fixture\n\n## Constraints\n\nnone\n",
  outline: "# Outline\n\n## Approach\n\nfixture approach\n\n## Issues\n\n- #1 fixture\n",
  detail: "# Detail\n\n## Steps\n\nfixture steps\n\n## Issues\n\n- #1 fixture\n",
};

let counter = 0;
function newSid(tag) {
  counter += 1;
  return `f2277-${tag}-${process.pid}-${counter}`.replace(/[^A-Za-z0-9_-]/g, "-");
}

function planPath(sid, suffix) { return path.join(PLANS_DIR, `${sid}-${suffix}.md`); }
function writePlan(sid, suffix, body) {
  fs.writeFileSync(planPath(sid, suffix), body == null ? PLAN_BODY[suffix] : body);
}
function statePath(sid) { return path.join(STATE_DIR, `${sid}.json`); }

// The implementation's own hash (digestExcludes applied once #2277 lands); null when the
// step is not gated yet or the artifact is unreadable.
function implSha(sid, step) {
  try {
    const { computeArtifactSha } = require(path.join(ROOT, "hooks/workflow-state/completion-approval.js"));
    return computeArtifactSha(sid, step);
  } catch (_) { return null; }
}

// writeState(sid, steps, approvals): steps = {step: status}; approvals = [{step, source?, sha?}].
// sha "impl" (default) = the implementation's current hash; "stale" = a hash that cannot match.
// top (optional) = extra top-level keys, e.g. { closes_issues: [1] }.
function writeState(sid, steps, approvals, top) {
  const at = new Date().toISOString();
  const events = [];
  for (const [step, status] of Object.entries(steps || {})) {
    events.push({ kind: "step_status", step, status, at, provenance: "observed", origin: "test-fixture" });
  }
  for (const a of approvals || []) {
    const source = a.source || "confirm-sentinel";
    let sha = null;
    if (source === "confirm-sentinel") sha = a.sha === "stale" ? "0".repeat(64) : implSha(sid, a.step);
    events.push({
      kind: "plan_approval", step: a.step, source, reason: "fixture approval",
      artifact_sha256: sha, artifact_session_id: sha ? sid : null,
      artifact_hash_status: sha ? "recorded" : "not-applicable",
      at, provenance: "declared", origin: "test-fixture",
    });
  }
  events.forEach((e, i) => { e.seq = i + 1; });
  fs.writeFileSync(statePath(sid), JSON.stringify(Object.assign({
    version: 2, session_id: sid, created_at: at,
    session_start_context: { cwd: process.cwd(), git_branch: "feature/f2277-fixture" },
    workflow_type: "wf-code", events,
  }, top || {}), null, 2));
}

function writeCorrupt(sid) { fs.writeFileSync(statePath(sid), "{ this is not json"); }

function readStep(sid, step) {
  try {
    const s = require(path.join(ROOT, "hooks/workflow-state")).readState(sid);
    return (s && s.steps && s.steps[step] && s.steps[step].status) || "MISSING";
  } catch (e) { return "ERR:" + e.message; }
}

function rawEvents(sid) {
  try { return JSON.parse(fs.readFileSync(statePath(sid), "utf8")).events || []; } catch (_) { return null; }
}

// Spawns `node <file> ...args` with stdin; extraEnv overrides (e.g. a CONFIRM_*=off config root).
function runNode(file, args, input, extraEnv) {
  const r = spawnSync(process.execPath, [path.join(ROOT, file)].concat(args || []), {
    input: input || "", encoding: "utf8", timeout: 60000,
    env: Object.assign({}, process.env, extraEnv || {}),
  });
  return { code: r.status, out: r.stdout || "", err: r.stderr || "" };
}

// A config root whose .env carries the given lines (the off waiver is read from the FILE only).
function configRoot(name, lines) {
  const dir = path.join(path.dirname(STATE_DIR), "cfg-" + name);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, ".env"), lines.join("\n") + "\n");
  return dir;
}

const clip = (s) => String(s).replace(/[\r\n|]+/g, " ").slice(0, 240);
function check(name, ok, detail) {
  console.log(ok ? `PASS|${name}` : `FAIL|${name}|${clip(detail)}`);
}

module.exports = {
  ROOT, STATE_DIR, PLANS_DIR, SUFFIX, PLAN_BODY, newSid, planPath, writePlan, statePath,
  implSha, writeState, writeCorrupt, readStep, rawEvents, runNode, configRoot, check, clip,
};
