"use strict";
// Shared fixture for the #2698 Stop-hook suites (tests/hooks/feature-2698-*.js): one temp dir per
// scene holds the workflow state and the plans (both pins point at it), seeding runs in a child
// process with the same env the hook sees, and hooks run for real with the Stop input on stdin.

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const REPO = path.resolve(__dirname, "..", "..", "..");
const fwd = (p) => String(p).replace(/\\/g, "/");
const lib = (rel) => fwd(path.join(REPO, rel));

// sceneDir(root, name) -> a fresh dir that is both WORKFLOW_STATE_DIR and WORKFLOW_PLANS_DIR.
function sceneDir(root, name) {
  const d = path.join(root, name);
  fs.mkdirSync(d, { recursive: true });
  fs.mkdirSync(path.join(d, "transcripts-empty"), { recursive: true });
  return d;
}

// envFor(dir, lang) — the env every child gets: both pins, no inherited session, no live
// transcript fallback, the language and enforcement switches pinned.
function envFor(dir, lang = "english") {
  const env = { ...process.env };
  delete env.CLAUDE_CODE_SESSION_ID;
  delete env.CLAUDECODE;
  for (const k of Object.keys(env)) if (/^(CONFIRM_|ENFORCE_|AUTO_MERGE_)/.test(k)) delete env[k];
  env.WORKFLOW_STATE_DIR = dir;
  env.WORKFLOW_PLANS_DIR = dir;
  env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(dir, "transcripts-empty");
  env.CONV_LANG = lang;
  env.ENFORCE_WORKFLOW = "on";
  env.ENFORCE_WORKTREE = "on";
  return env;
}

// nodeEval(dir, code, args) -> stdout; throws with stderr when the child fails. Under -e the
// first argument lands at argv[1], so a placeholder keeps args at argv[2..] as in a script.
function nodeEval(dir, code, args = [], lang) {
  const r = spawnSync(process.execPath, ["-e", code, "--", "eval", ...args], {
    encoding: "utf8", env: envFor(dir, lang), cwd: dir, timeout: 30000,
  });
  if (r.status !== 0) throw new Error(`fixture child failed (${r.status}): ${r.stderr}`);
  return r.stdout;
}

// glossaryRepo(dir) -> a throwaway git repo inside the scene dir that the #2529 glossary_check
// record of clarify_intent binds to (hooks disabled per fixture-isolation).
function glossaryRepo(dir) {
  const repo = path.join(dir, "glossary-repo");
  if (fs.existsSync(path.join(repo, ".git"))) return repo;
  fs.mkdirSync(repo, { recursive: true });
  for (const args of [["init", "-q"], ["config", "core.hooksPath", "/dev/null"]]) {
    const r = spawnSync("git", args, { cwd: repo, encoding: "utf8" });
    if (r.status !== 0) throw new Error(`git ${args.join(" ")} failed: ${r.stderr}`);
  }
  return repo;
}

// seedStarted(dir, sid) — workflow_init and clarify_intent complete (approved, glossary_check
// recorded), so next-step's current step is research and ACTION=invoke.
function seedStarted(dir, sid) {
  nodeEval(dir, `
const wf = require(${JSON.stringify(lib("hooks/workflow-state/state-io.js"))});
const sid = process.argv[2];
wf.markStep(sid, "workflow_init", "complete");
require(${JSON.stringify(lib("tests/lib/plan-approval-fixture.js"))}).approveLive(sid, "clarify_intent");
require(${JSON.stringify(lib("tests/lib/glossary-check-record.js"))})
  .completeWithRecord(sid, "clarify_intent", process.argv[3], wf.markStep);`, [sid, fwd(glossaryRepo(dir))]);
}

// markSteps(dir, sid, [[step, status], ...]) — real markStep calls, in order.
function markSteps(dir, sid, pairs) {
  nodeEval(dir, `
const wf = require(${JSON.stringify(lib("hooks/workflow-state/state-io.js"))});
for (const [s, st] of JSON.parse(process.argv[3])) wf.markStep(process.argv[2], s, st);`, [sid, JSON.stringify(pairs)]);
}

// backdateStep(dir, sid, step, msAgo) — moves the step's events into the past (a stall).
function backdateStep(dir, sid, step, msAgo) {
  const p = path.join(dir, `${sid}.json`);
  const s = JSON.parse(fs.readFileSync(p, "utf8"));
  const at = new Date(Date.now() - msAgo).toISOString();
  for (const e of s.events || []) if (e.step === step) e.at = at;
  fs.writeFileSync(p, JSON.stringify(s));
}

// seedSup(dir, sid, {alert, audit}) — a supervisor state built from createEmptyState with the
// given alert / audit fields merged over it.
function seedSup(dir, sid, patch = {}) {
  nodeEval(dir, `
const w = require(${JSON.stringify(lib("hooks/lib/supervisor-state-writer.js"))});
const s = require(${JSON.stringify(lib("hooks/lib/supervisor-state-schema.js"))});
const fs = require("fs");
const sid = process.argv[2];
const p = JSON.parse(process.argv[3]);
const st = s.createEmptyState(sid);
if (p.alert) Object.assign(st.alert, p.alert);
if (p.audit) st.audit = Object.assign(st.audit || {}, p.audit);
if (p.layer1) Object.assign(st.layer1, p.layer1);
fs.writeFileSync(w.getStatePath(sid, { forWrite: true }), JSON.stringify(st));`, [sid, JSON.stringify(patch)]);
}

// readSup(dir, sid) -> the supervisor state as the writer reads it (null when absent).
function readSup(dir, sid) {
  const out = nodeEval(dir, `
const w = require(${JSON.stringify(lib("hooks/lib/supervisor-state-writer.js"))});
process.stdout.write(JSON.stringify(w.readState(process.argv[2])));`, [sid]);
  return JSON.parse(out);
}

const U = (text, extra = {}) => ({ type: "user", message: { role: "user", content: text }, ...extra });
const R = () => ({ type: "user", message: { role: "user", content: [{ type: "tool_result", tool_use_id: "t1", content: "ok" }] } });
const A = (...content) => ({ type: "assistant", message: { role: "assistant", content } });
const T = (text) => ({ type: "text", text });
const TU = (name, input = {}) => ({ type: "tool_use", id: "t1", name, input });

// stopInput(dir, sid, entries) -> the Stop hook input; entries null = no transcript at all.
// last_assistant_message is the last text block, so the flush wait settles at once.
function stopInput(dir, sid, entries, name = "t") {
  const input = { session_id: sid, hook_event_name: "Stop", stop_hook_active: false, transcript_path: "" };
  if (!entries) return input;
  const p = path.join(dir, `${name}-${sid}.jsonl`);
  fs.writeFileSync(p, entries.map((e) => JSON.stringify(e)).join("\n") + "\n");
  let last = "";
  for (const e of entries) if (e.type === "assistant") for (const c of e.message.content) if (c.type === "text") last = c.text;
  input.transcript_path = fwd(p);
  input.last_assistant_message = last;
  return input;
}

// The canonical dialog / non-dialog transcripts.
const DIALOG = () => [U("Where is this function called from?"), A(TU("Grep")), R(), A(T("It is called from line 12 of hooks/a.js."))];
const NON_DIALOG = () => [U("Run the research step."), A(TU("Bash", { command: "ls" })), R(), A(T("The research is done."))];

// runHook(rel, dir, input, lang) -> {status, stdout, stderr, json} for the real hook on stdin.
function runHook(rel, dir, input, lang) {
  const r = spawnSync(process.execPath, [path.join(REPO, rel)], {
    input: JSON.stringify(input), encoding: "utf8", env: envFor(dir, lang), cwd: dir, timeout: 60000,
  });
  let json = null;
  try { json = JSON.parse(String(r.stdout || "").trim().split("\n").filter(Boolean).pop() || "null"); } catch (_e) { json = null; }
  return { status: r.status, stdout: r.stdout || "", stderr: r.stderr || "", json };
}

const tmpRoot = (tag) => fs.mkdtempSync(path.join(os.tmpdir(), `f2698-${tag}-`));
const rmRoot = (root) => { try { fs.rmSync(root, { recursive: true, force: true }); } catch (_e) { /* Windows */ } };

module.exports = {
  REPO, lib, sceneDir, envFor, nodeEval, seedStarted, markSteps, backdateStep, seedSup, readSup,
  U, R, A, T, TU, stopInput, DIALOG, NON_DIALOG, runHook, tmpRoot, rmRoot,
};
