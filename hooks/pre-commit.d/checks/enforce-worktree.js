"use strict";
// enforce-worktree check (#2507): blocks a commit from the main worktree or onto a protected
// branch unless ENFORCE_WORKTREE is off, every staged path is excluded, a session marker grants
// the bypass, or a human terminal (TTY outside Claude Code) runs the commit.
// Mirrors hooks/enforce-worktree.js; wording is the former bash hook's.

const fs = require("fs");
const path = require("path");
const { err } = require("../output");
const { fromCfg, git, sessionMarkerOff } = require("../lib/support");

const OFF = new Set(["off", "0", "false", "no", "disabled"]);

const isOn = (env) => !OFF.has(String(env.ENFORCE_WORKTREE === undefined ? "" : env.ENFORCE_WORKTREE).toLowerCase());

function excludeRc(context, staged) {
  if (staged.length === 0 || !context.repoTop) return 2;
  try {
    const env = { ...context.env, _PRECOMMIT_REPO_TOP: context.repoTop, _PRECOMMIT_STAGED: staged.join("\n") };
    const rc = fromCfg(context.cfgDir, "hooks/lib/precommit-exclude-check.js").run({ argv: [], cwd: context.repoTop, env, stdout: process.stdout, stderr: process.stderr });
    return Number.isInteger(rc) ? rc : 1;
  } catch (_) {
    return 1;
  }
}

function absDir(top, p) {
  const abs = path.resolve(top, p);
  try {
    return fs.realpathSync.native(abs);
  } catch (_) {
    return abs.toLowerCase();
  }
}

function isMainWorktree(top, env) {
  const r = git(top, ["rev-parse", "--git-common-dir", "--git-dir"], { env });
  const [common, dir] = String(r.stdout).split(/\r?\n/);
  if (!r.ok || !common || !dir) return false;
  return absDir(top, common) === absDir(top, dir);
}

function protectedBranches(top, env) {
  const listed = String(env.DEFAULT_BRANCHES || "");
  if (listed) return listed.split(/[,\s]+/).filter(Boolean);
  const out = [];
  const originHead = git(top, ["symbolic-ref", "refs/remotes/origin/HEAD"], { env });
  if (originHead.ok && originHead.stdout.trim()) out.push(originHead.stdout.trim().replace(/.*\//, ""));
  const heads = git(top, ["for-each-ref", "--format=%(refname)", "refs/heads/main", "refs/heads/master"], { env });
  for (const cand of ["main", "master"]) if (heads.stdout.split(/\r?\n/).includes(`refs/heads/${cand}`)) out.push(cand);
  const init = git(top, ["config", "init.defaultBranch"], { env });
  if (init.ok && init.stdout.trim()) out.push(init.stdout.trim());
  return out.length > 0 ? out : ["main"];
}

async function run({ context, snapshot, files }) {
  const env = context.env || process.env;
  if (!isOn(env)) return { verdict: "pass", messages: [] };
  const messages = [];
  const staged = typeof snapshot.rows === "function" ? snapshot.rows().map((r) => r.path) : files;

  const rc = excludeRc(context, staged);
  if (rc === 0) return { verdict: "pass", messages };
  if (rc !== 2) messages.push(err(`pre-commit: exclude-check failed (rc=${rc}); falling back to enforce-worktree gate.`));

  const marker = sessionMarkerOff(context.cfgDir);
  if (marker === 0) return { verdict: "pass", messages };
  if (marker !== 2) messages.push(err(`pre-commit: session-marker bypass check failed (rc=${marker}); falling back to enforce-worktree gate.`));

  if (context.isTTY && !env.CLAUDECODE) return { verdict: "pass", messages };

  const top = context.repoTop;
  if (isMainWorktree(top, env)) {
    messages.push(err("ENFORCE_WORKTREE: commits from main worktree are blocked."),
      err("Work from a linked worktree. Run: /worktree-start"),
      err("Or set ENFORCE_WORKTREE=off in agents config to allow direct main work."));
    return { verdict: "block", messages };
  }
  const cur = git(top, ["symbolic-ref", "--short", "HEAD"], { env });
  const branch = cur.ok ? cur.stdout.trim() : "";
  if (branch && protectedBranches(top, env).includes(branch)) {
    messages.push(err(`ENFORCE_WORKTREE: commits to protected branch '${branch}' are blocked.`),
      err("Switch to a feature branch. Run: git switch -c feature/<name>"),
      err("Or set ENFORCE_WORKTREE=off in agents config to disable."));
    return { verdict: "block", messages };
  }
  return { verdict: "pass", messages };
}

module.exports = { run, isOn };
