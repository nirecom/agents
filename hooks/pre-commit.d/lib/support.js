"use strict";
// Helpers shared by the pre-commit checks (#2507): cfgDir-relative module loading, git in the
// repo under commit, a captured stdout/stderr pair for in-process CLI modules, and the
// WORKFLOW_OFF / WORKTREE_OFF session-marker probe.

const path = require("path");
const { spawnSync } = require("../../lib/limited-child-process");
const { toWindowsPath } = require("../../lib/branch-diff");

const GIT_TIMEOUT_MS = 60000;

// fromCfg(cfgDir, rel) — the module at <cfgDir>/<rel>; a missing module throws.
function fromCfg(cfgDir, rel) {
  return require(path.join(toWindowsPath(cfgDir), rel));
}

function git(cwd, args, { env, input, encoding = "utf8" } = {}) {
  const r = spawnSync("git", args, { cwd: toWindowsPath(cwd), env: env || process.env, input, encoding, timeout: GIT_TIMEOUT_MS, maxBuffer: 256 * 1024 * 1024, windowsHide: true });
  return { ok: !r.error && r.status === 0, status: r.status, stdout: r.stdout || "", stderr: r.stderr || "", error: r.error };
}

// captureStreams() — { stdout, stderr, text() }: both streams write into one buffer, as 2>&1 does.
function captureStreams() {
  const chunks = [];
  const sink = { write: (c) => { chunks.push(Buffer.isBuffer(c) ? c.toString("utf8") : String(c)); return true; } };
  return { stdout: sink, stderr: sink, text: () => chunks.join("") };
}

// withQuietStderr(fn) — runs fn with process.stderr writes dropped (the bash probe ran 2>/dev/null).
function withQuietStderr(fn) {
  const real = process.stderr.write;
  process.stderr.write = () => true;
  try {
    return fn();
  } finally {
    process.stderr.write = real;
  }
}

// sessionMarkerOff(cfgDir) -> 0 bypass granted, 2 no bypass, 3 probe error.
function sessionMarkerOff(cfgDir) {
  try {
    return withQuietStderr(() => {
      const { resolveSessionId } = fromCfg(cfgDir, "hooks/workflow-state.js");
      const { isWorkflowOff, isWorktreeOff } = fromCfg(cfgDir, "hooks/lib/session-markers.js");
      const sid = resolveSessionId();
      if (!sid) return 2;
      return isWorkflowOff(sid) || isWorktreeOff(sid) ? 0 : 2;
    });
  } catch (_) {
    return 3;
  }
}

module.exports = { fromCfg, git, captureStreams, withQuietStderr, sessionMarkerOff };
