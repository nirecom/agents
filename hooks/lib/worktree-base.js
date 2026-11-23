"use strict";
// Single owner of the worktree base (#1610). Unset/blank WORKTREE_BASE_DIR means each repo's
// own <mainDir>/.claude/worktrees; an explicit value is one base shared by every repo,
// resolved against the home directory (never the CWD) so main, linked worktree and worker agree.

const os = require("os");
const path = require("path");

const { mainWorktreeOf } = require("./main-worktree");
const { normalizeCwd } = require("./path-normalize");
// Module object, not destructured: callers' tests stub realResolve on it.
const prf = require("./path-real-fold");

const IN_REPO_BASE_REL = ".claude/worktrees";

function readConfiguredBase() {
  try {
    const { classifyConfigFlag } = require("./config-flag");
    return String(classifyConfigFlag("WORKTREE_BASE_DIR", "").value || "").trim();
  } catch (_e) {
    return String(process.env.WORKTREE_BASE_DIR || "").trim();
  }
}

// Explicit value -> absolute path. Windows drive-relative (`C:wt`) and root-relative (`\wt`)
// forms are pinned to a drive root so the answer never depends on a per-drive CWD.
function absolutizeExplicit(raw) {
  const home = os.homedir();
  let v = raw;
  if (v === "~" || v.startsWith("~/") || v.startsWith("~\\")) v = path.join(home, v.slice(1));
  v = normalizeCwd(v) || v;
  if (process.platform === "win32") {
    const driveRel = /^([A-Za-z]):(?![\\/])(.*)$/.exec(v);
    if (driveRel) return path.resolve(`${driveRel[1].toUpperCase()}:\\`, driveRel[2]);
    if (/^[\\/](?![\\/])/.test(v)) return path.resolve(`${home.slice(0, 2)}\\`, v.slice(1));
  }
  return path.isAbsolute(v) ? path.resolve(v) : path.resolve(home, v);
}

// -> absolute explicit base, or null when WORKTREE_BASE_DIR is unset/blank.
function explicitWorktreeBase() {
  const raw = readConfiguredBase();
  return raw === "" ? null : absolutizeExplicit(raw);
}

// -> { ok: true, base, mainDir, source: "explicit"|"default" } | { ok: false, reason }
function resolveWorktreeBase(repoDir) {
  const input = typeof repoDir === "string" && repoDir.trim() !== "" ? repoDir.trim() : process.cwd();
  const normalized = normalizeCwd(input) || input;
  const abs = path.resolve(normalized);
  const mainDir = mainWorktreeOf(abs);
  if (!mainDir) return { ok: false, reason: `cannot resolve the main worktree of ${abs}` };
  const explicit = explicitWorktreeBase();
  if (explicit !== null) return { ok: true, base: explicit, mainDir, source: "explicit" };
  return { ok: true, base: path.join(mainDir, ...IN_REPO_BASE_REL.split("/")), mainDir, source: "default" };
}

// True only strictly below the real <mainDir>/.claude/worktrees (the base itself excluded). A base
// a link redirects elsewhere is refused, and every resolution error refuses (fail-closed, #3138).
function isInRepoBase(target, mainDir) {
  if (typeof target !== "string" || target === "" || typeof mainDir !== "string" || mainDir === "") return false;
  try {
    const main = normalizeCwd(mainDir) || mainDir;
    const realMain = prf.realResolve(main);
    const realBase = prf.realResolve(`${main}/${IN_REPO_BASE_REL}`);
    const baseKey = prf.foldKey(realBase);
    if (baseKey !== prf.foldKey(path.join(realMain, ...IN_REPO_BASE_REL.split("/")))) return false;
    return prf.foldKey(prf.realResolve(target)).startsWith(baseKey + "/");
  } catch {
    return false;
  }
}

// Repo-relative POSIX path (real spelling) of <base> when it really lies strictly inside <mainDir>;
// null when outside, when a link redirects it (lexical and real relatives disagree), or on error.
function inRepoRelative(base, mainDir) {
  if (!base || !mainDir) return null;
  try {
    const norm = (p) => normalizeCwd(String(p)) || String(p);
    const rel = path.relative(prf.realResolve(norm(mainDir)), prf.realResolve(norm(base)));
    // Segment-aware: "..wt" is a child named "..wt", not a parent escape.
    if (rel === "" || rel === ".." || rel.startsWith(".." + path.sep) || path.isAbsolute(rel)) return null;
    const fold = (s) => (prf.foldsCase() ? s.toLowerCase() : s).replace(/\\/g, "/");
    const lexical = path.relative(path.resolve(norm(mainDir)), path.resolve(norm(base)));
    if (fold(lexical) !== fold(rel)) return null;
    return rel.replace(/\\/g, "/");
  } catch {
    return null;
  }
}

module.exports = { IN_REPO_BASE_REL, resolveWorktreeBase, explicitWorktreeBase, isInRepoBase, inRepoRelative };
