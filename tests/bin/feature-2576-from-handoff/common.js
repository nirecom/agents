"use strict";
// Shared fixture of feature-2576-from-handoff.js: isolated state/plans dirs, a scratch HOME and an
// empty transcript base, the PASS/FAIL tally, and the --from / buildUpstreamView probes.

const { isolate } = require("../../lib/harness");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const restore = isolate();
const SCRATCH = fs.mkdtempSync(path.join(os.tmpdir(), "f2576-"));
function cleanup() {
  restore();
  fs.rmSync(SCRATCH, { recursive: true, force: true });
}

const ROOT = path.resolve(__dirname, "..", "..", "..");
const mod = (rel) => require(path.join(ROOT, rel));
const fx = require("../../lib/state-handoff-record-fixture");
const STATE_DIR = process.env.WORKFLOW_STATE_DIR;
const PLANS_DIR = process.env.WORKFLOW_PLANS_DIR;
const HOME = fs.mkdtempSync(path.join(SCRATCH, "home-"));
const TBASE = fs.mkdtempSync(path.join(SCRATCH, "transcripts-"));
const CLI = path.join(ROOT, "bin", "resume-session-detect");

const totals = { passed: 0, failed: 0, skipped: 0 };
function check(name, fn) {
  let why = null;
  try {
    const r = fn();
    if (typeof r === "string") why = r;
  } catch (e) {
    why = e && e.message ? e.message : String(e);
  }
  if (why === null) {
    totals.passed += 1;
    process.stdout.write(`PASS: ${name}\n`);
  } else {
    totals.failed += 1;
    process.stdout.write(`FAIL: ${name} — ${why}\n`);
  }
}
const show = (v) => (v === undefined ? "undefined" : JSON.stringify(v));
function eq(got, want, what) {
  if (JSON.stringify(got) !== JSON.stringify(want)) throw new Error(`${what || "value"}: want=${show(want)} got=${show(got)}`);
}
const slash = (p) => String(p).replace(/\\/g, "/");

// Every child runs from a neutral cwd with no inherited session id and an empty transcript base.
function spawnNode(args, extraEnv) {
  const env = Object.assign({}, process.env, { HOME, USERPROFILE: HOME, CLAUDE_TRANSCRIPT_BASE_DIR: TBASE }, extraEnv || {});
  delete env.CLAUDE_CODE_SESSION_ID;
  if (extraEnv && extraEnv.CLAUDE_CODE_SESSION_ID) env.CLAUDE_CODE_SESSION_ID = extraEnv.CLAUDE_CODE_SESSION_ID;
  return spawnSync(process.execPath, args, { cwd: HOME, env, encoding: "utf8", timeout: 60000 });
}
function parseOut(run) {
  try { return JSON.parse(run.stdout); } catch (e) { throw new Error(`stdout is not one JSON record (${e.message}): ${show(run.stdout)} stderr=${show(run.stderr)}`); }
}
function fromView(up, heir) {
  const run = spawnNode([CLI, "--from", up], heir ? { CLAUDE_CODE_SESSION_ID: heir } : null);
  return { run, d: parseOut(run) };
}

// A session-upstream with a live state file and an intent artifact. clarify_intent is left
// pending: completing it needs a glossary-check record, which this view does not depend on.
function seedActive(sid) {
  fx.makeState(sid, "/fixture/f2576/repo");
  fs.writeFileSync(path.join(PLANS_DIR, `${sid}-intent.md`), "**Title:** handoff donor\n");
}
function seedHeir(sid) {
  const io = mod("hooks/workflow-state/state-io");
  io.writeState(sid, io.createInitialState(sid, { cwd: "/fixture/f2576/repo", git_branch: "feature/donor" }));
}
const plant = (p, body) => {
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, body);
};

module.exports = {
  cleanup, SCRATCH, ROOT, mod, fx, STATE_DIR, PLANS_DIR, TBASE, CLI, totals,
  check, show, eq, slash, spawnNode, parseOut, fromView, seedActive, seedHeir, plant,
};
