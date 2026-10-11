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

function comparablePath(p) {
  return path.resolve(normalizeCwd(p) || p).replace(/\\/g, "/").toLowerCase();
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

module.exports = { isAllowedSupervisorBinTool, SUPERVISOR_BIN_TOOLS };
