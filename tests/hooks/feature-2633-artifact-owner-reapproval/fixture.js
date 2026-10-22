"use strict";
// Fixture builder for tests/hooks/feature-2633-artifact-owner-reapproval.js: raw v5 state files
// and plan artifacts inside the pinned WORKFLOW_STATE_DIR / WORKFLOW_PLANS_DIR, a CONFIRM_*
// config root (the off waiver is read from $AGENTS_MAIN_ROOT/.env only), and a reporter.
// State is written raw so a downstream state carrying upstream_session_id can be seeded even
// while the state writer still rejects that key.

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..", "..", "..");
const SUFFIX = { clarify_intent: "intent", outline: "outline", detail: "detail" };

// plan-link accepts only a UUID (or YYYYMMDD-HHMMSS) session id, so every fixture sid is a UUID.
function newSid() { return crypto.randomUUID(); }
function plansDir() { return process.env.WORKFLOW_PLANS_DIR; }
function planPath(sid, suffix, dir) { return path.join(dir || plansDir(), `${sid}-${suffix}.md`); }

function body(suffix, tag, worktreePath) {
  if (suffix === "intent") {
    return `# Intent ${tag}\n\n## Goal\n\ngoal ${tag}\n\n## Issues\n\n- #4242 upstream issue\n\n` +
      `## worktrees\n\n- repo: owner/fixture-${tag}\n  worktree_path: ${worktreePath || "/nonexistent/wt-" + tag}\n`;
  }
  if (suffix === "outline") return `# Outline ${tag}\n\n## Adopted approach\n\napproach ${tag}\n`;
  return `# Detail ${tag}\n\n## Phase 1\n\nphase ${tag}\n\n## Files to modify\n\n- \`hooks/from-${tag}.js\`\n`;
}

function writePlan(sid, suffix, text, dir) {
  const p = planPath(sid, suffix, dir);
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, text == null ? body(suffix, sid) : text);
  return p;
}

function sha(text) { return crypto.createHash("sha256").update(text).digest("hex"); }

// approvalEvent(step, ownerSid, recordedSha, extra) — a raw confirm-sentinel plan_approval event.
function approvalEvent(step, ownerSid, recordedSha, extra) {
  return Object.assign({
    kind: "plan_approval", step, source: "confirm-sentinel", reason: "fixture approval",
    artifact_sha256: recordedSha, artifact_session_id: ownerSid,
    artifact_hash_status: recordedSha ? "recorded" : "uncomputable-at-record",
    provenance: "declared", origin: "test-fixture",
  }, extra || {});
}

function revokeEvent(step) {
  return { kind: "plan_approval_revoked", step, reason: "fixture revoke", provenance: "declared", origin: "test-fixture" };
}

function statusEvent(step, status) {
  return { kind: "step_status", step, status, provenance: "observed", origin: "test-fixture" };
}

// writeState(sid, top, events) — a raw v5 state file; top = extra top-level keys
// (e.g. { upstream_session_id: U }). seq is 1-based and contiguous.
function writeState(sid, top, events) {
  const at = new Date().toISOString();
  const evs = (events || []).map((e, i) => Object.assign({ at }, e, { seq: i + 1 }));
  const state = Object.assign({
    version: 5, session_id: sid, created_at: at,
    session_start_context: { cwd: process.cwd(), git_branch: "feature/f2633-fixture" },
    events: evs,
  }, top || {});
  const p = path.join(process.env.WORKFLOW_STATE_DIR, `${sid}.json`);
  fs.writeFileSync(p, JSON.stringify(state, null, 2));
  return p;
}

// configRoot(name, lines) — a directory whose .env carries the CONFIRM_* lines.
function configRoot(name, lines) {
  const dir = path.join(path.dirname(process.env.WORKFLOW_STATE_DIR), "cfg-" + name);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, ".env"), lines.join("\n") + "\n");
  return dir;
}

function load(rel) { return require(path.join(ROOT, rel)); }

// Reporter: check() prints PASS/FAIL lines and remembers any failure for the exit code.
let failures = 0;
const clip = (s) => String(s).replace(/[\r\n]+/g, " ").slice(0, 300);
function check(name, ok, detail) {
  if (ok) console.log(`PASS: ${name}`);
  else { failures += 1; console.log(`FAIL: ${name} — ${clip(detail)}`); }
}
// run(name, fn) — a thrown error is one FAIL carrying the error code / message.
function run(name, fn) {
  try { fn(); } catch (e) { check(name + " (threw)", false, (e && (e.code ? e.code + " " : "") + e.message) || e); }
}
function failureCount() { return failures; }

function samePath(a, b) {
  const n = (p) => path.resolve(String(p || "")).replace(/\\/g, "/").toLowerCase();
  return typeof a === "string" && n(a) === n(b);
}

module.exports = {
  ROOT, SUFFIX, newSid, plansDir, planPath, body, writePlan, sha, approvalEvent, revokeEvent,
  statusEvent, writeState, configRoot, load, check, run, failureCount, samePath, clip,
};
