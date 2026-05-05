#!/usr/bin/env node
// Path normalization for cwd values received from Claude Code hooks.
//
// On Windows, Claude Code (running through Git Bash / msys) sometimes passes
// Unix-style paths like `/<drive>/path/to/repo` in the hook stdin payload. Node.js
// child_process.execSync / spawnSync on Windows cannot use these paths as cwd
// — the call throws ENOENT. This helper converts a POSIX drive-letter prefix
// (single-letter root segment followed by the rest of the path) to the Windows
// drive-letter form (e.g. drive letter X with separator).
// on win32, leaves other shapes untouched, and is a no-op on non-Windows.

function normalizeCwd(p) {
  if (typeof p !== "string" || !p) return undefined;
  if (process.platform === "win32" && /^\/[a-zA-Z]\//.test(p)) {
    // /<drive>/path/to/repo -> C:\git\dotfiles
    return p.charAt(1).toUpperCase() + ":" + p.slice(2).replace(/\//g, "\\");
  }
  return p;
}

// Extract the path argument from a `git -C <path> ...` command, if any.
// Returns the path string (not normalized) or null.
function extractDashCPath(command) {
  if (typeof command !== "string") return null;
  const m = command.match(/^git\s+-C\s+(\S+)/);
  return m ? m[1] : null;
}

/**
 * Resolve the user repo's cwd from multiple sources, in priority order:
 *   1. `-C <path>` argument in the command (explicit user intent)
 *   2. `process.env.CLAUDE_PROJECT_DIR` (set by Claude Code per hook)
 *   3. `input.cwd` from the hook's stdin payload (if present)
 *   4. caller-supplied `stateCwd` (typically `state.cwd` saved at session-start)
 *   5. `process.cwd()` (last resort — usually the hook lib repo, often wrong)
 *
 * All non-empty candidates are passed through `normalizeCwd` for Windows
 * Unix-style → drive-letter conversion.
 *
 * Why this chain matters: in production, PostToolUse stdin does not always
 * include `cwd`, and `process.cwd()` is wherever the hook process started
 * (typically the agents repo). Without this resolution, hooks operate on the
 * wrong repo's HEAD. See history.md "F4: workflow-mark cwd resolution".
 */
function resolveRepoCwd({ command, input, stateCwd } = {}) {
  const candidates = [
    extractDashCPath(command || ""),
    process.env.CLAUDE_PROJECT_DIR,
    input && input.cwd,
    stateCwd,
  ];
  for (const c of candidates) {
    const norm = normalizeCwd(c);
    if (norm) return norm;
  }
  return process.cwd();
}

module.exports = { normalizeCwd, extractDashCPath, resolveRepoCwd };
