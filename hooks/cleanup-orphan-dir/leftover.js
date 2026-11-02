"use strict";
// The gitlink path of cleanup-orphan-dir (#322 / #2875): a WE-11 leftover keeps its `.git` gitlink,
// so it may go only once its ownership is proven against the caller's expected main root.

const fs = require("fs");
const { execFileSync } = require("child_process");
const path = require("path");
const { classifyWorktreeLeftover } = require("../workflow-state/resolve-worktree-path");
const { normalizePathForCompare } = require("../lib/repo-identity");

// The main checkout of a common dir named `.git`; a bare repo (any other name) has none.
function mainRootOf(commonDir) {
  return commonDir && path.basename(commonDir) === ".git" ? path.dirname(commonDir) : null;
}

// Why `dir` may not take the gitlink path, or null when it is a proven leftover of `expectMainRoot`.
function leftoverRefusal(dir, expectMainRoot) {
  const { kind, commonDir } = classifyWorktreeLeftover(dir);
  if (kind !== "unregistered-leftover") return `target .git is not an unregistered worktree leftover (${kind}): ${dir}`;
  const repoRoot = mainRootOf(commonDir);
  if (!repoRoot) return `leftover's repository has no main checkout (common dir ${commonDir}): ${dir}`;
  const want = normalizePathForCompare(path.resolve(expectMainRoot));
  if (want === null || normalizePathForCompare(repoRoot) !== want) {
    return `leftover belongs to ${repoRoot}, not the expected main root ${expectMainRoot}: ${dir}`;
  }
  return registrationRefusal(dir, repoRoot);
}

// Second opinion from git itself, fail-closed: a path-string miss in the admin-dir scan must not
// let a live worktree (symlink or short-name spelling) through.
function registrationRefusal(dir, repoRoot) {
  let out;
  try {
    out = execFileSync("git", ["-C", repoRoot, "worktree", "list", "--porcelain"], { encoding: "utf8", timeout: 10000 });
  } catch (e) {
    return `cannot list worktrees of ${repoRoot}(${e.code || e.message}): ${dir}`;
  }
  const want = [dir, safeRealpath(dir)].map(normalizePathForCompare);
  for (const line of out.split(/\r?\n/)) {
    if (!line.startsWith("worktree ")) continue;
    const listed = line.slice("worktree ".length);
    const forms = [normalizePathForCompare(listed), normalizePathForCompare(safeRealpath(listed))];
    if (forms.some((f) => f !== null && want.includes(f))) return `git lists the target as a registered worktree of ${repoRoot}:${dir}`;
  }
  return null;
}

function safeRealpath(p) {
  try { return fs.realpathSync.native(p); } catch { return p; }
}

// Uncapped walk that never follows a link: a refusal reason for a nested `.git` or an unreadable
// subdir, else null. The leftover's own top-level gitlink is the one `.git` allowed.
function subtreeRefusal(root) {
  const stack = [root];
  while (stack.length > 0) {
    const cur = stack.pop();
    let entries;
    try {
      entries = fs.readdirSync(cur, { withFileTypes: true });
    } catch (e) {
      return `unreadable subdir in leftover (${e.code || e.message}): ${cur}`;
    }
    for (const ent of entries) {
      const sub = path.join(cur, ent.name);
      if (ent.name === ".git" && cur !== root) return `leftover subtree contains a nested .git entry: ${sub}`;
      if (ent.isSymbolicLink()) continue;
      if (ent.isDirectory()) stack.push(sub);
    }
  }
  return null;
}

module.exports = { leftoverRefusal, mainRootOf, subtreeRefusal };
