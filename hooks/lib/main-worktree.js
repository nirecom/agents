"use strict";
// Main worktree of the repository holding <dir>: the common dir minus its trailing `.git`,
// accepted only when that entry's own `.git` directory is the common dir. A
// --separate-git-dir repository, a bare repository and a non-git directory resolve to null.
// Never asks git for a toplevel, and needs no worktree listing (a failing listing must not
// hide the main worktree from its callers).

const fs = require("fs");
const path = require("path");
const childProcess = require("child_process");

const { normalizeCwd } = require("./path-normalize");

const GIT_TIMEOUT_MS = 20000;

const GIT_REPO_ENV = ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_COMMON_DIR"];

// No `env` option is passed: an explicit environment marks a worker-started child
// (tests/bin/feature-2561-worker-child-roots.sh), so the inherited repository-selecting
// variables are lifted out of this process only while the synchronous call runs.
function withoutGitRepoEnv(run) {
  const held = {};
  for (const name of GIT_REPO_ENV) {
    if (!Object.prototype.hasOwnProperty.call(process.env, name)) continue;
    held[name] = process.env[name];
    delete process.env[name];
  }
  try {
    return run();
  } finally {
    Object.assign(process.env, held);
  }
}

function git(args, workDir) {
  // Looked up per call, not destructured at load: this module outlives a re-required caller.
  const res = withoutGitRepoEnv(() => childProcess.spawnSync("git", args, {
    cwd: workDir,
    shell: false,
    encoding: "utf8",
    timeout: GIT_TIMEOUT_MS,
    windowsHide: true,
    maxBuffer: 8 * 1024 * 1024,
  }));
  if (res.error || res.status !== 0) return null;
  return String(res.stdout === null || res.stdout === undefined ? "" : res.stdout);
}

function toAbsDir(input) {
  if (typeof input !== "string") return null;
  const trimmed = input.trim();
  if (trimmed === "") return null;
  const normalized = normalizeCwd(trimmed) || trimmed;
  if (!path.isAbsolute(normalized)) return null;
  const abs = path.normalize(normalized);
  try {
    if (!fs.statSync(abs).isDirectory()) return null;
  } catch (_e) {
    return null;
  }
  return abs;
}

function realOrNull(p) {
  try {
    return fs.realpathSync(normalizeCwd(p) || p);
  } catch (_e) {
    return null;
  }
}

function samePathString(a, b) {
  if (process.platform === "win32") return a.toLowerCase() === b.toLowerCase();
  return a === b;
}

// Porcelain blocks of the repository holding <dir>: [{ path, bare }], or null.
function worktreeListOf(dir) {
  const abs = toAbsDir(dir);
  if (abs === null) return null;
  const listing = git(["-C", abs, "worktree", "list", "--porcelain"], abs);
  if (listing === null) return null;
  const blocks = [];
  let cur = null;
  for (const line of listing.split(/\r?\n/)) {
    const m = /^worktree (.+)$/.exec(line);
    if (m !== null) {
      cur = { path: m[1], bare: false };
      blocks.push(cur);
    } else if (cur !== null && line === "bare") {
      cur.bare = true;
    }
  }
  return blocks;
}

const TRUE_VALUES = new Set(["true", "yes", "on", "1"]);

function coreBareIsTrue(commonDir) {
  let text = "";
  try {
    text = fs.readFileSync(path.join(commonDir, "config"), "utf8");
  } catch (_e) {
    return true;
  }
  let inCore = false;
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    const section = /^\[\s*([^\]\s"]+)[^\]]*\]/.exec(line);
    if (section !== null) {
      inCore = section[1].toLowerCase() === "core";
      continue;
    }
    if (!inCore) continue;
    const kv = /^bare(?:\s*=\s*([^;#]*))?\s*(?:[;#].*)?$/i.exec(line);
    if (kv === null) continue;
    const value = kv[1] === undefined ? "true" : kv[1].trim().toLowerCase();
    if (TRUE_VALUES.has(value)) return true;
  }
  return false;
}

// Mirrors git's own main-worktree rule (the porcelain first entry is the common dir with
// its trailing `/.git` removed, flagged `bare` from core.bare) without listing worktrees.
function mainWorktreeOf(dir) {
  const abs = toAbsDir(dir);
  if (abs === null) return null;
  const out = git(["-C", abs, "rev-parse", "--path-format=absolute", "--git-common-dir"], abs);
  if (out === null) return null;
  const reported = out.trim();
  if (reported === "") return null;
  const commonAbs = path.normalize(normalizeCwd(reported) || reported);
  if (path.basename(commonAbs) !== ".git") return null;
  const commonReal = realOrNull(commonAbs);
  if (commonReal === null || coreBareIsTrue(commonReal)) return null;
  const entry = path.dirname(commonAbs);
  const dotGit = path.join(entry, ".git");
  let isDir = false;
  try {
    isDir = fs.lstatSync(dotGit).isDirectory();
  } catch (_e) {
    isDir = false;
  }
  if (!isDir) return null;
  const dotGitReal = realOrNull(dotGit);
  if (dotGitReal === null || !samePathString(dotGitReal, commonReal)) return null;
  return realOrNull(entry);
}

module.exports = { mainWorktreeOf, worktreeListOf };
