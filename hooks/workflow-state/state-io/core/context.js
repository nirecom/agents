"use strict";
// Git/cwd context resolution for state-io/core.js. Split out to keep core.js
// under the file-split.md line limit (rules/coding/file-split.md).

const fs = require("fs");
const path = require("path");
// execFileSync, never execSync: since #1733 these git calls receive a path that
// came from TOOL INPUT (postuse-native-worktree-record passes tool_input.path),
// and a shell would expand `$(...)` / backticks inside it. Argv form has no shell.
const { execFileSync } = require("child_process");
const { normalizeCwd } = require("../../../lib/path-normalize");

// getCurrentContext(dir) -> { cwd, git_branch }.
// With no argument the behaviour is exactly the pre-#1733 one (back-compat for
// session-start.js and friends). With `dir` given, the POSIX drive-letter form
// emitted by Git Bash / MSYS2 is normalized first, because `git -C` and the
// fs APIs below cannot use it on win32 (rules/coding/nodejs.md).
function getCurrentContext(dir) {
  const base = normalizeCwd(dir) || dir || process.env.CLAUDE_PROJECT_DIR || process.cwd();
  const cwd = path.resolve(base);
  let git_branch = null;
  try {
    const out = execFileSync(
      "git",
      ["-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"],
      { encoding: "utf8", timeout: 2000, stdio: ["pipe", "pipe", "pipe"] }
    );
    git_branch = out.trim() || null;
    if (git_branch === "HEAD") git_branch = null;
  } catch (e) {}
  return { cwd, git_branch };
}

// resolveWorktreeContext(rawPath) -> the fields a `worktree` event needs.
// `path_source` records HOW the path was obtained (CPR-SC): a path read from
// tool input is evidence, a process cwd is a guess, and the two must never be
// conflated downstream.
//
// A path is only trusted as `tool_input` when EVERY link of the chain holds:
//   1. a non-empty string that normalizes to an ABSOLUTE path,
//   2. that path exists and is a directory,
//   3. `git -C <path> rev-parse --git-dir` succeeds.
// Any failure falls through to the process-cwd fallback with worktree_path:null —
// recording the hook's own cwd as "the worktree that was entered" would be a
// confident-looking lie. FAILS OPEN on every branch: this never throws.
function resolveWorktreeContext(rawPath) {
  try {
    if (typeof rawPath === "string" && rawPath.trim()) {
      const normalized = normalizeCwd(rawPath.trim());
      if (typeof normalized === "string" && path.isAbsolute(normalized)) {
        const p = path.resolve(normalized);
        if (fs.statSync(p).isDirectory()) {
          execFileSync("git", ["-C", p, "rev-parse", "--git-dir"], {
            encoding: "utf8",
            timeout: 2000,
            stdio: ["pipe", "pipe", "pipe"],
          });
          const ctx = getCurrentContext(p);
          return { cwd: ctx.cwd, git_branch: ctx.git_branch, worktree_path: p, path_source: "tool_input" };
        }
      }
    }
  } catch (e) {
    /* fall through to the fallback below */
  }
  const ctx = getCurrentContext();
  return { cwd: ctx.cwd, git_branch: ctx.git_branch, worktree_path: null, path_source: "fallback-process-cwd" };
}

module.exports = { getCurrentContext, resolveWorktreeContext };
