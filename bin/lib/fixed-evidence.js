"use strict";

// Verify a this-pr `disposed: fixed` claim (#3145 S10): its loc changed since the base point.
// Base point: the entry's base when it is an ancestor of HEAD, else the merge-base of HEAD and
// origin's default branch (origin/HEAD, then origin/<DEFAULT_BRANCHES>, then local <DEFAULT_BRANCHES>). Git runs only through the injected runGit(args) -> {status, stdout} | null,
// so the hook / CLI and the commit-push worker (spawn.js) share one judgment.

const path = require("path");
const { spawnSync } = require("../../hooks/lib/limited-child-process");

const GIT_TIMEOUT_MS = 5000;
const NOTES_FILE = "WORKTREE_NOTES.md";
// The same env override and fallback as hooks/lib/merge-detect.js getProtectedBranches.
const DEFAULT_BRANCHES = Object.freeze(["main", "master"]);

const fwd = (p) => String(p).replace(/\\/g, "/");
const ok = (r) => Boolean(r) && r.status === 0;
const out = (r) => String((r && r.stdout) || "").trim();

function defaultBranches() {
  const env = String(process.env.DEFAULT_BRANCHES || "").split(",").map((s) => s.trim()).filter(Boolean);
  return env.length ? env : DEFAULT_BRANCHES.slice();
}

function defaultGitRunner(dir) {
  return (args) => {
    try {
      const r = spawnSync("git", ["-C", dir].concat(args), { encoding: "utf8", timeout: GIT_TIMEOUT_MS });
      if (!r || r.error) return { status: 1, stdout: "" };
      return { status: r.status === null ? 1 : r.status, stdout: String(r.stdout || "") };
    } catch (_e) {
      return { status: 1, stdout: "" };
    }
  };
}

function originDefaultRef(runGit) {
  const head = runGit(["symbolic-ref", "-q", "refs/remotes/origin/HEAD"]);
  if (ok(head) && out(head) !== "") return out(head);
  const refs = defaultBranches().map((b) => `refs/remotes/origin/${b}`)
    .concat(defaultBranches().map((b) => `refs/heads/${b}`));
  return refs.find((ref) => ok(runGit(["rev-parse", "--verify", "-q", ref]))) || null;
}

function basePoint(entry, runGit) {
  if (entry.base && ok(runGit(["merge-base", "--is-ancestor", entry.base, "HEAD"]))) return entry.base;
  const ref = originDefaultRef(runGit);
  if (ref === null) return null;
  const mb = runGit(["merge-base", "HEAD", ref]);
  return ok(mb) && out(mb) !== "" ? out(mb) : null;
}

const splitPaths = (r) => String(r.stdout || "").split(/[\0\r\n]+/).map(fwd).filter((p) => p !== "" && p !== NOTES_FILE);

function changeSet(point, runGit) {
  const diff = runGit(["diff", "--name-only", "-z", point]);
  const others = runGit(["ls-files", "--others", "--exclude-standard", "--full-name", "-z"]);
  if (!ok(diff) || !ok(others)) return null;
  return Array.from(new Set(splitPaths(diff).concat(splitPaths(others))));
}

// The loc as a repo-root-relative path; null when absent or outside the repo (then any change counts).
function relativeLoc(loc, runGit) {
  if (!loc) return null;
  const p = fwd(String(loc).trim()).replace(/:\d+(?:-\d+)?$/, "");
  if (!path.posix.isAbsolute(p) && !path.win32.isAbsolute(p)) {
    const rel = path.posix.normalize(p).replace(/^\.\/+/, "").replace(/\/+$/, "");
    return rel === ".." || rel.startsWith("../") ? null : rel;
  }
  const top = runGit(["rev-parse", "--show-toplevel"]);
  if (!ok(top)) return null;
  const root = fwd(out(top)).replace(/\/+$/, "");
  const fold = (s) => (process.platform === "win32" ? s.toLowerCase() : s);
  if (fold(p) === fold(root)) return "";
  return fold(p).startsWith(`${fold(root)}/`) ? p.slice(root.length + 1).replace(/\/+$/, "") : null;
}

function fixedEvidence(entry, runGit) {
  const point = basePoint(entry, runGit);
  if (point === null) return { ok: false, reason: "no-base", path: entry.loc || null };
  const changed = changeSet(point, runGit);
  if (changed === null) return { ok: false, reason: "git-unavailable", path: entry.loc || null };
  const rel = relativeLoc(entry.loc, runGit);
  if (rel === null || rel === "" || rel === ".") {
    return changed.length > 0 ? { ok: true } : { ok: false, reason: "no-change", path: null };
  }
  const hit = changed.some((f) => f === rel || f.startsWith(`${rel}/`));
  return hit ? { ok: true } : { ok: false, reason: "loc-unchanged", path: rel };
}

module.exports = { DEFAULT_BRANCHES, defaultGitRunner, fixedEvidence };
