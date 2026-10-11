"use strict";
// hooks/enforce-worktree/main-worktree-allows/supervisor-bin.js
// isAllowedSupervisorBinTool — one literal-root call of a supervisor bin tool whose
// redirects are fd duplication or literal /tmp/ files only (#2589).

const path = require("path");
const { normalizeCwd } = require("../../lib/path-normalize");
const { resolveScriptCheckoutRoot } = require("../../lib/script-checkout-root");
const { rejectsUnsafeArgTail } = require("../arg-tail-guard");
const { singleInvocation, leadingAssignments, redirectsUnderTmp } = require("./command-shape");

const SUPERVISOR_BIN_TOOLS = Object.freeze(["bin/supervisor-findings-codex", "bin/supervisor-write-alert"]);
const SUPERVISOR_INTERPRETERS = new Set(["bash", "node"]);

// Case is folded only where the filesystem folds it: on a case-sensitive one,
// bin/SUPERVISOR-WRITE-ALERT is a different file from the allow-listed script.
const CASE_INSENSITIVE_FS = process.platform === "win32" || process.platform === "darwin";

function comparablePath(p, foldCase = CASE_INSENSITIVE_FS) {
  const resolved = path.resolve(normalizeCwd(p) || p).replace(/\\/g, "/");
  return foldCase ? resolved.toLowerCase() : resolved;
}

function isAllowedSupervisorBinTool(cmd) {
  const root = resolveScriptCheckoutRoot();
  if (!root) return false;
  const seg = singleInvocation(cmd);
  if (!seg) return false;
  const split = leadingAssignments(seg);
  if (!split || split.assignments.length !== 0) return false;
  if (!SUPERVISOR_INTERPRETERS.has(seg.cmd0) || seg.cmd0Raw !== seg.cmd0) return false;
  if (seg.argv.length === 0 || !Array.isArray(seg.argvRaw)) return false;
  const script = seg.argv[0];
  if (/[$`]/.test(script) || /[$`]/.test(seg.argvRaw[0] || "")) return false;
  // A relative path would resolve against the hook's cwd, not the Bash tool's.
  if (!path.isAbsolute(script) && !/^\/[A-Za-z]\//.test(script)) return false;
  let target;
  try { target = comparablePath(script); } catch (_) { return false; }
  const known = SUPERVISOR_BIN_TOOLS.some((rel) => {
    try { return comparablePath(path.join(root, rel)) === target; } catch (_) { return false; }
  });
  if (!known) return false;
  if (rejectsUnsafeArgTail(seg.argvRaw.slice(1).join(" "), "worker-script")) return false;
  return redirectsUnderTmp(seg);
}

module.exports = { isAllowedSupervisorBinTool, SUPERVISOR_BIN_TOOLS, comparablePath };
