"use strict";
// hooks/workflow-gate/early-gate-allowlist.js
// The early gate's WRITE ALLOWLIST: which Edit/Write targets stay open while
// workflow_init / clarify_intent are still pending (#2108).
//
// Two destinations, and only two: the plans dir (intent / outline / detail) and the
// session scratchpad (surveys, notes, drafts). #2108 was filed because only the
// first existed, leaving a subagent with no legal write target at all.

const path = require("path");

// Tool scope is deliberately narrower than EARLY_GATE_TOOLS: `editFiles` and
// `NotebookEdit` keep their pre-existing blanket block (plan R10).
const { getWorkflowPlansDir } = require("../lib/workflow-plans-dir");
const {
  getClaudeBaseNorm,
  isAtOrUnderClaudeBase,
  isAllowedScratchpadTarget,
} = require("../lib/claude-scratchpad-base");

const ALLOWLIST_TOOLS = new Set(["Write", "Edit", "MultiEdit"]);

// A target is only a target when it is a non-empty STRING. `null`, a number and an
// array all name nothing, so nothing about them can be allowed.
function targetPathOf(toolInput) {
  const raw = toolInput && (toolInput.file_path || toolInput.path);
  return typeof raw === "string" ? raw : "";
}

// Repo detection is injected into isAllowedScratchpadTarget to defeat a poisoned
// TEMP that nests the claude base inside a repo tree (F1, fix-1441). Required
// lazily so a load failure leaves the gate fail-open rather than crashing it.
function findRepoRootSafe(p) {
  const { findRepoRoot } = require("../enforce-worktree/git-repo-detection");
  return findRepoRoot(p);
}

// Containment, not prefix: the trailing separator is what keeps `<plans>-evil/` out,
// and path.resolve() is what keeps `<plans>/../escape.md` out.
function isUnderPlansDir(resolved) {
  try {
    const plansRoot = path.resolve(getWorkflowPlansDir()) + path.sep;
    return resolved.toLowerCase().startsWith(plansRoot.toLowerCase());
  } catch (e) {
    console.error(`workflow-gate: ${e.message}`);
    return false;
  }
}

// classifyEarlyWriteAllow(toolName, toolInput): "plans" | "scratchpad" | null.
// The KIND is carried out (not just a boolean) so the caller can report which route
// answered, and so a future third route cannot be added without naming itself.
function classifyEarlyWriteAllow(toolName, toolInput) {
  if (!ALLOWLIST_TOOLS.has(toolName)) return null;
  const filePath = targetPathOf(toolInput || {});
  if (!filePath) return null;

  let resolved;
  try {
    resolved = path.resolve(filePath);
  } catch (e) {
    console.error(`workflow-gate: ${e.message}`);
    return null;
  }

  if (isUnderPlansDir(resolved)) return "plans";
  try {
    if (isAllowedScratchpadTarget(resolved, findRepoRootSafe)) return "scratchpad";
  } catch (e) {
    console.error(`workflow-gate: ${e.message}`);
  }
  return null;
}

// The scratchpad allow root as a NATIVE, unfolded path. getScratchpadAllowRootNorm()
// is the decision SSOT but returns a case-FOLDED string on win32, which is not a
// spelling to show a human — so its two branches are re-derived here for DISPLAY
// only, and must stay in step with it.
function scratchpadAllowRootForDisplay() {
  try {
    const sp = process.env.SCRATCHPAD;
    if (sp && isAtOrUnderClaudeBase(sp)) return path.resolve(sp);
  } catch (e) { /* fall back to the claude base */ }
  try {
    return path.resolve(getClaudeBaseNorm());
  } catch (e) {
    return "<os-tmpdir>/claude";
  }
}

// describeAllowedTargets(): the same two routes as prose-ready absolute paths, for
// the block message. Never yields an empty or `undefined` fragment — a message that
// named nothing would send the agent somewhere the allowlist will not honour.
function describeAllowedTargets() {
  let plans;
  try {
    plans = path.resolve(getWorkflowPlansDir());
  } catch (e) {
    plans = "~/.workflow-plans";
  }
  return { plans, scratchpad: scratchpadAllowRootForDisplay() };
}

module.exports = { classifyEarlyWriteAllow, describeAllowedTargets, ALLOWLIST_TOOLS };
