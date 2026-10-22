"use strict";
// Fixture for tests/hooks/feature-2297-readopt-and-upstream-cwd.js — not a test on its own.
// Builds one main repo with two linked worktrees (W1, W2 at the same commit, so a W1/W2 pair is a
// SIBLING with equal content) plus an unrelated repo, and seeds upstream/downstream state files.
// A module the change has not landed yet is reported as NOT YET IMPLEMENTED, never as a crash.
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { gitInit } = require("../../lib/harness");

const ROOT_DIR = path.resolve(__dirname, "..", "..", "..");
const rel = (p) => path.join(ROOT_DIR, p);

function git(args, cwd) {
  const r = spawnSync("git", args, { cwd, encoding: "utf8", timeout: 60000 });
  if (r.status !== 0) throw new Error(`git ${args.join(" ")} failed: ${r.stderr || r.error}`);
  return r.stdout;
}

function makeRepo(dir) {
  fs.mkdirSync(dir, { recursive: true });
  gitInit(dir);
  git(["-C", dir, "config", "user.email", "test@example.com"]);
  git(["-C", dir, "config", "user.name", "Test"]);
  git(["-C", dir, "config", "core.autocrlf", "false"]);
  fs.writeFileSync(path.join(dir, "README.md"), "fixture\n");
  git(["-C", dir, "add", "README.md"]);
  git(["-C", dir, "commit", "-q", "--no-verify", "-m", "initial"]);
  return dir;
}

function addWorktree(main, dir, branch) {
  git(["-C", main, "worktree", "add", "-q", "-b", branch, dir]);
  return dir;
}

// The whole sandbox: CONFIRM_* pinned on through a decoy AGENTS_MAIN_ROOT, a neutral cwd, an empty
// transcript base, and the repo layout. Every path is resolved once so states and the code under
// test compare identical strings.
function makeSandbox() {
  const base = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "f2297-")));
  const p = (...xs) => path.join(base, ...xs);
  for (const d of ["cfg", "cwd", "transcripts"]) fs.mkdirSync(p(d));
  fs.writeFileSync(p("cfg", ".env"), "CONFIRM_INTENT=on\nCONFIRM_OUTLINE=on\nCONFIRM_DETAIL=on\n");
  process.env.AGENTS_MAIN_ROOT = p("cfg");
  process.env.CLAUDE_TRANSCRIPT_BASE_DIR = p("transcripts");
  delete process.env.CLAUDE_PROJECT_DIR;
  const M = makeRepo(p("main"));
  const W1 = addWorktree(M, p("wt1"), "feature/wt1");
  const W2 = addWorktree(M, p("wt2"), "feature/wt2");
  const W3 = addWorktree(M, p("wt3"), "feature/wt3");
  const O = makeRepo(p("other"));
  return { base, NEUTRAL: p("cwd"), M, W1, W2, W3, O };
}

function tryRequire(relPath) {
  try {
    return require(rel(relPath));
  } catch (e) {
    if (e && e.code === "MODULE_NOT_FOUND" && String(e.message).includes(path.basename(relPath))) return null;
    throw e;
  }
}

// need(relPath, name) — the export, or a NOT YET IMPLEMENTED error that names what is missing.
function need(relPath, name) {
  const m = tryRequire(relPath);
  if (!m) throw new Error(`NOT YET IMPLEMENTED: ${relPath} does not exist`);
  if (typeof m[name] !== "function") throw new Error(`NOT YET IMPLEMENTED: ${relPath} does not export ${name}`);
  return m[name];
}

const io = () => require(rel("hooks/workflow-state/state-io"));
const approvals = () => require(rel("tests/lib/plan-approval-fixture"));

// An upstream with a context-independent AND a worktree-dependent completion, so full and degraded
// adoptions are told apart by write_tests / branching_complete alone. Gated steps are approved.
function seedUpstream(sid, cwd) {
  const s = io();
  s.writeState(sid, s.createInitialState(sid, { cwd, git_branch: "feature/up" }));
  s.markStep(sid, "workflow_init", "complete");
  approvals().approveLive(sid, "clarify_intent");
  s.markStep(sid, "clarify_intent", "complete");
  s.markStep(sid, "research", "complete");
  s.markStep(sid, "branching_complete", "complete");
  s.markStep(sid, "write_tests", "complete");
  return sid;
}

function seedDownstream(sid, cwd) {
  const s = io();
  s.writeState(sid, s.createInitialState(sid, { cwd, git_branch: "feature/up" }));
  return sid;
}

// What EnterWorktree leaves behind (hooks/postuse-native-worktree-record.js): the projected cwd moves.
function enterWorktree(sid, wt) {
  io().appendEvents(sid, [{
    kind: "worktree", transition: "entered", git_branch: "feature/up", cwd: wt,
    worktree_path: wt, path_source: "tool_input", provenance: "observed", origin: "worktree-postuse",
  }]);
}

function adopt(down, up) {
  const { adoptState } = require(rel("hooks/workflow-state/inheritance/adopt"));
  return adoptState({ heirSid: down, donorSid: up });
}

const statePath = (sid) => io().getStatePath(sid);
const bytes = (sid) => fs.readFileSync(statePath(sid), "utf8");
const statusOf = (sid, step) => {
  const st = io().readState(sid);
  return (st && st.steps && st.steps[step] && st.steps[step].status) || "pending";
};
const lastSeqOf = (sid, kind) => {
  const evs = (io().readRawState(sid) || {}).events || [];
  const hit = evs.filter((e) => e.kind === kind).pop();
  return hit ? hit.seq : null;
};

// The classification name, whichever key the result carries it under.
function classOf(r) {
  if (typeof r === "string") return r;
  if (!r || typeof r !== "object") return String(r);
  return r.classification || r.class || r.kind || r.verdict || r.cwd_class || null;
}

function runNode(argv, env, cwd) {
  const r = spawnSync(process.execPath, argv, {
    cwd, encoding: "utf8", timeout: 60000, env: Object.assign({}, process.env, env || {}),
  });
  return { rc: r.status, out: r.stdout || "", err: r.stderr || "" };
}

module.exports = {
  ROOT_DIR, rel, makeSandbox, tryRequire, need, io, approvals, seedUpstream, seedDownstream,
  enterWorktree, adopt, statePath, bytes, statusOf, lastSeqOf, classOf, runNode,
};
