"use strict";

// SSOT worktree-path resolution for the session-bound linked worktree.
// resolveSessionWorktreePath(sessionId) → owned linked-worktree path | null; tries state.cwd then
//   state.session_worktree and NEVER falls back to process.cwd() (NOSTATE: bin/resolve-worktree-path).
// isMainWorktree(dir): git-dir === git-common-dir; any error counts as main (reject).
// isOwnedLinkedWorktree / classifyWorktreeLeftover: fs-only ownership (#2875). git is never spawned:
//   inside a leftover it answers for the parent repo, and the resolver is on hot paths.

const fs = require("fs");
const path = require("path");
const { execFileSync } = require("../lib/limited-child-process");
const { toWindowsPath } = require("../lib/branch-diff");
const { normalizePathForCompare } = require("../lib/repo-identity");
const { readState } = require("./state-io");

const samePath = (a, b) => {
  const na = normalizePathForCompare(a);
  return na !== null && na === normalizePathForCompare(b);
};

const readTrimmed = (file) => fs.readFileSync(file, "utf8").trim();

// The admin dir a `.git` gitlink file names, resolved against `dir`; null when it is no gitlink.
function gitlinkAdmin(dir) {
  const m = /^gitdir:\s*(.+?)\s*$/m.exec(fs.readFileSync(path.join(dir, ".git"), "utf8"));
  return m ? path.resolve(dir, toWindowsPath(m[1])) : null;
}

// `<common>` for an admin dir shaped `<common>/worktrees/<name>`, or null.
function commonDirOfAdmin(admin) {
  if (path.basename(path.dirname(admin)) !== "worktrees") return null;
  const common = path.dirname(path.dirname(admin));
  try {
    if (!fs.statSync(common).isDirectory() || !fs.statSync(path.join(common, "HEAD")).isFile()) return null;
  } catch (_e) {
    return null;
  }
  return common;
}

function adminPointsAt(admin, dotGit) {
  const target = readTrimmed(path.join(admin, "gitdir"));
  return target !== "" && samePath(path.resolve(admin, toWindowsPath(target)), dotGit);
}

// Gitlink facts of `dir`: { dotGit, kind: "file"|"dir"|"other"|"none", admin, common }.
function gitlinkFacts(dir) {
  const d = toWindowsPath(dir);
  const dotGit = path.join(d, ".git");
  const facts = { dir: d, dotGit, kind: "none", admin: null, common: null };
  let st;
  try { st = fs.lstatSync(dotGit); } catch (_e) { return facts; }
  facts.kind = st.isFile() ? "file" : st.isDirectory() ? "dir" : "other";
  if (facts.kind !== "file") return facts;
  facts.admin = gitlinkAdmin(d);
  if (facts.admin) facts.common = commonDirOfAdmin(facts.admin);
  return facts;
}

function isOwnedFacts(f) {
  if (!f.common) return false;
  try { return adminPointsAt(f.admin, f.dotGit); } catch (_e) { return false; }
}

// True only for a live linked worktree whose gitlink, admin dir, and back-reference agree.
function isOwnedLinkedWorktree(dir) {
  try {
    return typeof dir === "string" && dir !== "" && isOwnedFacts(gitlinkFacts(dir));
  } catch (_e) {
    return false;
  }
}

// Every `<common>/worktrees/*/gitdir`: true when one names `dotGit`, false when none does, null
// when the listing cannot be read whole. ENOENT on the worktrees dir itself is an empty listing.
function anyAdminPointsAt(common, dotGit) {
  let entries;
  try {
    entries = fs.readdirSync(path.join(common, "worktrees"), { withFileTypes: true });
  } catch (e) {
    return e && e.code === "ENOENT" ? false : null;
  }
  for (const ent of entries) {
    if (!ent.isDirectory()) continue;
    try {
      if (adminPointsAt(path.join(common, "worktrees", ent.name), dotGit)) return true;
    } catch (e) {
      if (!e || e.code !== "ENOENT") return null;
    }
  }
  return false;
}

// { kind: "owned"|"foreign"|"unregistered-leftover"|"unknown", commonDir: string|null }.
function classifyWorktreeLeftover(dir) {
  try {
    if (typeof dir !== "string" || dir === "") return { kind: "unknown", commonDir: null };
    const f = gitlinkFacts(dir);
    if (f.kind === "dir") return { kind: "foreign", commonDir: null };
    if (f.kind !== "file" || !f.common) return { kind: "unknown", commonDir: null };
    if (isOwnedFacts(f)) return { kind: "owned", commonDir: f.common };
    const registered = anyAdminPointsAt(f.common, f.dotGit);
    return { kind: registered === false ? "unregistered-leftover" : "unknown", commonDir: f.common };
  } catch (_e) {
    return { kind: "unknown", commonDir: null };
  }
}

// True when `dir` is the main worktree (git-dir === git-common-dir).
// argv-form execFileSync (never string-template exec) so path metacharacters
// in `dir` cannot alter the command. Fail-close: any error → true (reject).
function isMainWorktree(dir) {
  try {
    const gitDir = execFileSync("git", ["-C", dir, "rev-parse", "--git-dir"], {
      encoding: "utf8",
      timeout: 5000,
    });
    const gitCommonDir = execFileSync("git", ["-C", dir, "rev-parse", "--git-common-dir"], {
      encoding: "utf8",
      timeout: 5000,
    });
    return path.resolve(gitDir.trim()) === path.resolve(gitCommonDir.trim());
  } catch (_e) {
    return true;
  }
}

// The absolute git common dir of `dir` (shared by a repo and all its linked worktrees,
// so equal values mean "same repository"), or null when git cannot answer.
function gitCommonDirOf(dir) {
  try {
    const out = execFileSync("git", ["-C", dir, "rev-parse", "--path-format=absolute", "--git-common-dir"], {
      encoding: "utf8",
      timeout: 5000,
      stdio: ["ignore", "pipe", "ignore"],
    });
    const v = out.trim();
    return v ? v : null;
  } catch (_e) {
    return null;
  }
}

// Resolve the session-bound linked worktree path, or null when unresolvable.
// Fail-safe: the entire body is wrapped so any exception collapses to null.
function resolveSessionWorktreePath(sessionId) {
  try {
    let sid = sessionId;
    if (!sid) {
      // Lazy require: keeps the resolver out of module load and out of any future
      // require cycle through the ./workflow-state barrel.
      const { resolveSessionId } = require("./session-id");
      sid = resolveSessionId({});
    }
    if (!sid) return null;
    const state = readState(sid);
    if (state === null) return null;
    // Two candidates in order, judged by ONE predicate (CPR-E2C): isOwnedLinkedWorktree.
    // Failing it rejects the candidate, not the whole resolution — state.cwd can be absent,
    // stale, or a WE-11 leftover while session_worktree is good.
    for (const candidate of [state.cwd, state.session_worktree]) {
      if (isOwnedLinkedWorktree(candidate)) return candidate;
    }
    return null;
  } catch (_e) {
    return null;
  }
}

module.exports = {
  classifyWorktreeLeftover,
  gitCommonDirOf,
  isMainWorktree,
  isOwnedLinkedWorktree,
  resolveSessionWorktreePath,
};
