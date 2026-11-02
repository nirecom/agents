"use strict";
// Shared #2875 / #322 fixture: real repos, live linked worktrees, and the leftover directory a
// failed `git worktree remove` (WE-11) leaves behind — a directory whose `.git` gitlink still
// names an admin dir that `git worktree prune` has since removed, or that a later
// `git worktree add` of the same basename has reused for another worktree.
// Not a test on its own. A module the change has not landed yet is reported as NOT YET
// IMPLEMENTED, never as a crash, so a red case names the missing symbol.

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { gitInit } = require("./harness");

const ROOT = path.resolve(__dirname, "..", "..");
const rel = (p) => path.join(ROOT, p);

function git(args, cwd) {
  const r = spawnSync("git", args, { cwd, encoding: "utf8", timeout: 60000 });
  if (r.status !== 0) throw new Error(`git ${args.join(" ")} failed: ${r.stderr || r.error}`);
  return r.stdout;
}

function makeBase(prefix) {
  return fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), prefix)));
}

function makeRepo(dir) {
  fs.mkdirSync(dir, { recursive: true });
  gitInit(dir);
  git(["-C", dir, "config", "user.email", "test@example.com"]);
  git(["-C", dir, "config", "user.name", "Test"]);
  git(["-C", dir, "config", "core.autocrlf", "false"]);
  git(["-C", dir, "config", "commit.gpgsign", "false"]);
  fs.writeFileSync(path.join(dir, "README.md"), "fixture\n");
  git(["-C", dir, "add", "README.md"]);
  git(["-C", dir, "commit", "-q", "--no-verify", "-m", "initial"]);
  return dir;
}

function addWorktree(main, dir, branch) {
  git(["-C", main, "worktree", "add", "-q", "-b", branch, dir]);
  return dir;
}

// WE-11 failure: the worktree directory survives, but `git worktree prune` (run while the
// directory was out of sight) removes its admin dir. With `reuseAt`, a second worktree of the
// same basename is then added elsewhere, so git hands it the freed admin dir name.
function makeLeftover(main, dir, branch, opts = {}) {
  addWorktree(main, dir, branch);
  const hidden = `${dir}.hidden`;
  fs.renameSync(dir, hidden);
  git(["-C", main, "worktree", "prune"]);
  fs.renameSync(hidden, dir);
  let reuser = null;
  if (opts.reuseAt) {
    if (path.basename(opts.reuseAt) !== path.basename(dir)) {
      throw new Error("makeLeftover: reuseAt must share the leftover's basename");
    }
    reuser = addWorktree(main, opts.reuseAt, `${branch}-reuse`);
  }
  return { leftover: dir, reuser };
}

// The admin dir a gitlink names, read the way the fixture wrote it.
function gitlinkTarget(dir) {
  const raw = fs.readFileSync(path.join(dir, ".git"), "utf8");
  const m = /^gitdir:\s*(.+?)\s*$/m.exec(raw);
  return m ? m[1] : null;
}

function writeGitlink(dir, target) {
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, ".git"), `gitdir: ${target}\n`);
}

// Lexical path comparison (drive-letter case, separators, trailing slash).
function samePath(a, b) {
  const n = (v) => (typeof v === "string" ? v.replace(/\\/g, "/").replace(/\/+$/, "").toLowerCase() : v);
  return n(a) === n(b);
}

function tryRequire(relPath) {
  try {
    return require(rel(relPath));
  } catch (e) {
    if (e && e.code === "MODULE_NOT_FOUND" && String(e.message).includes(path.basename(relPath))) return null;
    throw e;
  }
}

// need(relPath, name) — the export, or a NOT YET IMPLEMENTED error naming what is missing.
function need(relPath, name) {
  const m = tryRequire(relPath);
  if (!m) throw new Error(`NOT YET IMPLEMENTED: ${relPath} does not exist`);
  if (typeof m[name] !== "function" && m[name] === undefined) {
    throw new Error(`NOT YET IMPLEMENTED: ${relPath} does not export ${name}`);
  }
  return m[name];
}

const io = () => require(rel("hooks/workflow-state/state-io"));

function seedState(sid, cwd) {
  const s = io();
  s.writeState(sid, s.createInitialState(sid, { cwd, git_branch: "feature/fixture" }));
  return sid;
}

// What EnterWorktree leaves behind (hooks/postuse-native-worktree-record.js): the projected cwd moves.
function enterWorktree(sid, wt) {
  io().appendEvents(sid, [{
    kind: "worktree", transition: "entered", git_branch: "feature/fixture", cwd: wt,
    worktree_path: wt, path_source: "tool_input", provenance: "observed", origin: "worktree-postuse",
  }]);
}

function runNode(argv, opts = {}) {
  const r = spawnSync(process.execPath, argv, {
    cwd: opts.cwd, input: opts.input, encoding: "utf8", timeout: opts.timeout || 60000,
    env: opts.env || process.env,
  });
  return { rc: r.status, out: r.stdout || "", err: r.stderr || "", error: r.error };
}

module.exports = {
  ROOT, rel, git, makeBase, makeRepo, addWorktree, makeLeftover, gitlinkTarget, writeGitlink,
  samePath, tryRequire, need, io, seedState, enterWorktree, runNode,
};
