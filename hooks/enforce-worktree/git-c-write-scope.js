// hooks/enforce-worktree/git-c-write-scope.js
// #2649 policy (A): the write verdict of a command made only of `git -C <path>` git
// writes. The -C target is judged against the NARROWED roots (cwd repo +
// ADDITIONAL_REPOS) by git common dir, never against a root set that the payload
// already added the -C path to. Every other command shape returns null from
// classifyGitCWrite and keeps the legacy session-scope path (cd route, non-git
// writes, redirects, --work-tree/--git-dir, existing relative -C).

"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");
const { resolveGitArgvForSegment, isGitWriteArgv, resolveGitSubArgv } = require("../lib/bash-write-patterns/git-write-ir");
const { getProtectedBranches, getCurrentBranch } = require("./config");
const { extractGitScopeFlagsFromArgv } = require("../lib/parse-git-args");
const { getGitCommonDir, resolveRepoRoot, isMainCheckout, normalizeForCompare, resolveScopeValue, AMBIGUOUS_SCOPE } = require("./git-repo-detection");
const { getNarrowedSessionRoots } = require("./session-scope");

const READ_REDIRECT_OPS = new Set(["<", "<<", "<<<", "<&"]);

function hasWriteRedirect(seg) {
  return (seg.redirects || []).some((r) => {
    if (!r || READ_REDIRECT_OPS.has(r.op)) return false;
    const raw = typeof r.targetRaw === "string" ? r.targetRaw : r.target;
    return !(raw === "/dev/null" || /^&\d*-?$/.test(String(raw || "")));
  });
}

function homeDiverges() {
  const home = process.env.HOME;
  // Unset: Git Bash derives HOME from USERPROFILE and POSIX bash reads passwd, as os.homedir() does.
  // Empty: bash expands `~` to "" while os.homedir() falls back to passwd, so they diverge.
  if (typeof home !== "string") return false;
  if (home === "") return true;
  // resolveScopeValue maps the MSYS `/<drive>/...` spelling to `<DRIVE>:\...`; a non-absolute HOME diverges.
  const v = resolveScopeValue(home);
  if (v === AMBIGUOUS_SCOPE) return true;
  return normalizeForCompare(v) !== normalizeForCompare(os.homedir());
}

// One -C value → { kind: "resolved", root, common } | "ambiguous" | "unresolved" | "legacy".
// "legacy" = an existing relative path; its behaviour is outside #2649 and stays as-is.
function resolveCTarget(raw, toolCwd) {
  if (typeof raw !== "string" || raw === "") return { kind: "ambiguous" };
  const v = resolveScopeValue(raw);
  if (v === AMBIGUOUS_SCOPE) {
    if (/\$/.test(raw) || raw.startsWith("~")) return { kind: "ambiguous" };
    let exists = false;
    try { exists = fs.existsSync(path.resolve(toolCwd || process.cwd(), raw)); } catch (e) { exists = false; }
    return { kind: exists ? "legacy" : "ambiguous" };
  }
  // resolveScopeValue expands `~` with os.homedir() (USERPROFILE on Windows), but the
  // shell expands it with $HOME: when the two differ the verdict would judge another repo.
  if (raw.startsWith("~") && homeDiverges()) return { kind: "ambiguous" };
  if (!fs.existsSync(v)) return { kind: "unresolved" };
  const root = resolveRepoRoot(v);
  const common = root ? getGitCommonDir(v) : null;
  if (!root || !common) return { kind: "unresolved" };
  // A repo-config core.worktree moves the work tree out of the -C repo: the work
  // tree must round-trip to the same common dir, or the verdict proves nothing.
  return getGitCommonDir(root) === common ? { kind: "resolved", root, common } : { kind: "unresolved" };
}

// Common dirs of the narrowed roots plus the tool-cwd repo (the session checkout);
// null when the cwd is not a repo or any root is unresolvable (fail-closed: no new allow).
function anchorCommonDirs(toolCwd) {
  const cwdRoot = resolveRepoRoot(toolCwd || process.cwd());
  if (cwdRoot === null) return null;
  const roots = new Set(getNarrowedSessionRoots());
  roots.add(cwdRoot);
  const commons = new Set();
  for (const r of roots) {
    const c = getGitCommonDir(r);
    if (c === null) return null;
    commons.add(c);
  }
  return commons;
}

// A repo nested in a session checkout (submodule or plain clone) has its own common
// dir, yet its files live inside that checkout: walk every enclosing repo upward.
function nestedInAnchor(root, anchors) {
  let cur = root;
  for (;;) {
    const parent = path.dirname(cur);
    if (!parent || parent === cur) return false;
    const enclosing = resolveRepoRoot(parent);
    if (enclosing === null) return false;
    const c = getGitCommonDir(enclosing);
    if (c === null || anchors.has(c)) return true;
    cur = enclosing;
  }
}

// Every worktree path of the anchor repos (main checkouts included), normalized;
// null when any listing fails (fail-closed).
function anchorWorktreePaths(toolCwd) {
  const cwdRoot = resolveRepoRoot(toolCwd || process.cwd());
  const roots = new Set(getNarrowedSessionRoots());
  if (cwdRoot !== null) roots.add(cwdRoot);
  const out = new Set();
  for (const r of roots) {
    let res;
    try {
      res = spawnSync("git", ["worktree", "list", "--porcelain"], { cwd: r, encoding: "utf8", timeout: 2000 });
    } catch (e) {
      return null;
    }
    if (res.error || res.status !== 0) return null;
    for (const line of (res.stdout || "").split(/\r?\n/)) {
      if (line.startsWith("worktree ")) out.add(normalizeForCompare(line.slice("worktree ".length)));
    }
  }
  return out;
}

// A target whose work tree encloses a session checkout (e.g. a superproject holding it
// as a submodule) can reach it through submodule recursion, explicit or via
// submodule.recurse, whatever the subcommand.
// `root` (resolveRepoRoot) and `worktrees` are both normalizeForCompare output.
function enclosesAnchor(root, worktrees) {
  const prefix = root.endsWith(path.sep) ? root : root + path.sep;
  for (const w of worktrees) if (w && w.startsWith(prefix)) return true;
  return false;
}

// Write subcommands whose writes stay inside the -C repo. Any other write may name an
// explicit destination (`config --file`, `clone <dir>`, `push <local path>`, `worktree add`,
// `archive -o`, …) that a -C verdict says nothing about, so it keeps the legacy path.
const C_CONFINED_WRITE_SUBCOMMANDS = new Set([
  "add", "am", "branch", "checkout", "cherry-pick", "commit", "fetch", "merge", "mv",
  "pull", "rebase", "reset", "restore", "revert", "rm", "stash", "switch", "tag",
]);

// GIT_WORK_TREE / GIT_DIR / GIT_INDEX_FILE (any GIT_* name) redirect the write away
// from the -C repo, so a -C common-dir verdict proves nothing. Any token naming one —
// inline prefix, `env NAME=…`, `export NAME[=…]` — keeps the legacy path.
const GIT_ENV_TOKEN_RE = /^GIT_[A-Za-z0-9_]*(=|$)/;

function setsGitEnv(seg) {
  const toks = [seg.cmd0, ...(Array.isArray(seg.argv) ? seg.argv : [])];
  return toks.some((t) => typeof t === "string" && GIT_ENV_TOKEN_RE.test(t));
}

// The same redirection inherited by the hook process (and so by the Bash child). Narrower
// than the command-token rule on purpose: a token is an explicit act of the command,
// while the ambient environment routinely carries benign GIT_* (GIT_EDITOR, GIT_TERMINAL_PROMPT,
// GIT_CONFIG_NOSYSTEM). Unlike a token, it is invisible in the command, so it blocks outright.
const GIT_REDIRECT_ENV_RE =
  /^GIT_(DIR|WORK_TREE|INDEX_FILE|OBJECT_DIRECTORY|ALTERNATE_OBJECT_DIRECTORIES|COMMON_DIR|CONFIG|CONFIG_GLOBAL|CONFIG_SYSTEM|CONFIG_COUNT|CONFIG_PARAMETERS|CONFIG_KEY_\d+|CONFIG_VALUE_\d+)$/i;

function inheritsGitRedirect(env) {
  return Object.keys(env || {}).some((k) => GIT_REDIRECT_ENV_RE.test(k) && env[k] !== undefined);
}

// null → the command is not a pure `git -C` write; caller keeps the legacy path.
function classifyGitCWrite(ir, toolCwd) {
  if (!ir || ir.parseFailure === true || !Array.isArray(ir.segments) || ir.segments.length === 0) return null;
  if (ir.segments.some(setsGitEnv)) return null;
  const values = [];
  for (const seg of ir.segments) {
    const argv = resolveGitArgvForSegment(seg);
    if (argv === null || hasWriteRedirect(seg)) return null;
    // `-c core.worktree=…` / `--config-env` can redirect the write like GIT_WORK_TREE.
    const { subArgv, hasConfigInjection } = resolveGitSubArgv(argv);
    if (hasConfigInjection) return null;
    // Every segment must be a confined write: a read-classified segment (`git -C <main> add .`)
    // still touches its own repo, and an early allow would carry it along unexamined.
    if (!isGitWriteArgv(argv) || !C_CONFINED_WRITE_SUBCOMMANDS.has(subArgv[0])) return null;
    const f = extractGitScopeFlagsFromArgv(argv);
    if (!f.sawScopeFlag || f.workTree !== null || f.gitDir !== null) return null;
    values.push(f.cIn);
  }
  if (values.length === 0) return null;
  if (inheritsGitRedirect(process.env)) return { redirected: true, ambiguous: false, unresolved: false, external: false, sharedRoots: [] };
  let targets = values.map((v) => resolveCTarget(v, toolCwd));
  if (targets.some((t) => t.kind === "legacy")) return null;
  const anchors = anchorCommonDirs(toolCwd);
  if (anchors !== null) {
    const worktrees = targets.some((t) => t.kind === "resolved" && !anchors.has(t.common)) ? anchorWorktreePaths(toolCwd) : null;
    targets = targets.map((t) => {
      if (t.kind !== "resolved" || anchors.has(t.common)) return t;
      if (worktrees === null || nestedInAnchor(t.root, anchors) || enclosesAnchor(t.root, worktrees)) return { kind: "unresolved" };
      return t;
    });
  }
  const resolved = targets.filter((t) => t.kind === "resolved");
  const shared = resolved.filter((t) => anchors === null || anchors.has(t.common));
  return {
    ambiguous: targets.some((t) => t.kind === "ambiguous"),
    unresolved: targets.some((t) => t.kind === "unresolved"),
    external: anchors !== null && resolved.length === targets.length && shared.length === 0,
    sharedRoots: shared.map((t) => t.root),
  };
}

// Calls done() on allow/block; returns on fall-through to the post-dispatch
// main-checkout / protected-branch checks (keyed on repoRoot).
function decideGitCWrite(c, repoRoot, done) {
  if (c.redirected) {
    done({
      block: true,
      reason:
        "ENFORCE_WORKTREE: git -C write blocked. Reason: an inherited GIT_* variable\n" +
        "(GIT_DIR, GIT_WORK_TREE, GIT_INDEX_FILE, GIT_CONFIG*, ...) can redirect the write\n" +
        "away from the -C repo. Unset it in the session environment and retry.",
    });
  }
  if (c.external) done();
  const linkedCwd = repoRoot ? isMainCheckout(repoRoot) === false : false;
  if (linkedCwd && (c.ambiguous || c.unresolved)) {
    done({
      block: true,
      reason:
        "ENFORCE_WORKTREE: git -C write blocked. Reason: the -C path cannot be resolved\n" +
        "($VAR, ~user, a nonexistent path, or no resolvable git common dir).\n" +
        "Pass a literal absolute path to an existing repo.",
    });
  }
  // A segment aimed at a checkout other than the one post-dispatch judges
  // (e.g. `git -C <linked wt> commit && git -C <main> commit`) must not ride out
  // on the first segment's verdict: apply both post-dispatch checks to it here.
  const judged = repoRoot ? normalizeForCompare(repoRoot) : null;
  for (const root of c.sharedRoots) {
    if (root === judged) continue;
    if (isMainCheckout(root) !== false) {
      done({
        block: true,
        reason:
          `ENFORCE_WORKTREE: git -C write blocked. Reason: ${root} is a main checkout of a session repo.\n` +
          "Main worktree is reserved for merge/pull only. Work from a linked worktree.",
      });
    }
    const branch = getCurrentBranch(root);
    if (branch && getProtectedBranches(root).includes(branch)) {
      done({
        block: true,
        reason:
          `ENFORCE_WORKTREE: git -C write blocked. Reason: protected branch '${branch}' in linked worktree ${root}.\n` +
          "Switch that worktree to a feature branch before writing.",
      });
    }
  }
}

module.exports = { classifyGitCWrite, decideGitCWrite };
