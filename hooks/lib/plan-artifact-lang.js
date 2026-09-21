"use strict";
// hooks/lib/plan-artifact-lang.js — plan-artifact language policy shared by the
// PreToolUse gate, the PostToolUse checker and the Stop guard re-lint (#2278).
// Owns "is this path a plan artifact", "where does <sid>-<stage>.md live" and the
// block-reason line format so the three consumers cannot drift apart.

const fs = require("fs");
const path = require("path");
const { getWorkflowPlansDir } = require("./workflow-plans-dir");
const { isPlanArtifact } = require("./is-plan-artifact");
const { loadLangConfig, classifyPolicy } = require("./lang-config");
const { lintPlanLang } = require("./lint-plan-lang");

const STAGES = new Set(["intent", "outline", "detail"]);

function isPlanArtifactPath(resolvedPath) {
  if (typeof resolvedPath !== "string" || resolvedPath.length === 0) return false;
  const plansDir = path.resolve(getWorkflowPlansDir());
  const resolved = path.resolve(resolvedPath);
  const rel = path.relative(plansDir, resolved);
  if (rel === "" || rel.startsWith("..") || path.isAbsolute(rel)) return false;
  if (rel.includes(path.sep) || rel.includes("/")) return false;
  return isPlanArtifact(path.basename(resolved));
}

// The joined basename must itself be a plan artifact: this rejects separators,
// traversal and any sid outside the UUID / timestamp classes in one check.
function resolvePlanArtifactPath(sid, stage) {
  if (typeof sid !== "string" || typeof stage !== "string" || !STAGES.has(stage)) return null;
  const base = sid + "-" + stage + ".md";
  if (!isPlanArtifact(base)) return null;
  return path.join(getWorkflowPlansDir(), base);
}

// Inverse of resolvePlanArtifactPath: derive the stage (intent/outline/detail)
// from a resolved plan-artifact path's basename. SSOT for basename->stage so the
// gate, checker and Stop guard classify a stage the same way. Returns null when
// no known stage suffix matches.
function stageOf(resolvedPath) {
  if (typeof resolvedPath !== "string" || resolvedPath.length === 0) return null;
  const base = path.basename(resolvedPath);
  for (const stage of STAGES) {
    if (base.endsWith("-" + stage + ".md")) return stage;
  }
  return null;
}

function loadPlanPolicy() {
  const policy = loadLangConfig("plan");
  return { policy, tier: classifyPolicy(policy) };
}

function lintPlanArtifactText(text, policy, stage) {
  if (typeof text !== "string") return [];
  return lintPlanLang(text, policy, stage);
}

// Re-lint the confirmed artifact. Body language checks still require a strict
// policy, but canonical-heading checks run regardless of policy (#2338): when
// the stage resolves, heading violations are returned even under a non-strict
// policy, so a non-strict policy no longer short-circuits the whole re-lint.
function relintPlanArtifact(sid, stage) {
  const { policy, tier } = loadPlanPolicy();
  const result = { skipped: null, policy, tier, artifactPath: null, violations: [] };
  const artifactPath = resolvePlanArtifactPath(sid, stage);
  if (artifactPath === null) return Object.assign(result, { skipped: "unresolved" });
  // A non-strict policy with no resolvable stage has nothing to check: heading
  // checks need a stage, body checks need strict. stage is resolvable here (the
  // path resolved), so heading checks can run; keep going.
  result.artifactPath = artifactPath;
  let text;
  try {
    if (!fs.statSync(artifactPath).isFile()) return Object.assign(result, { skipped: "unreadable" });
    text = fs.readFileSync(artifactPath, "utf8");
  } catch (e) {
    return Object.assign(result, { skipped: "unreadable" });
  }
  result.violations = lintPlanArtifactText(text, policy, stage);
  return result;
}

function formatPlanLangViolations(violations, max) {
  const limit = typeof max === "number" && max > 0 ? max : 5;
  const list = Array.isArray(violations) ? violations : [];
  const lines = list.slice(0, limit).map((v) => "line " + v.lineNumber + ": " + String(v.line).slice(0, 80));
  if (list.length > limit) lines.push("... and " + (list.length - limit) + " more");
  return lines;
}

module.exports = {
  isPlanArtifactPath,
  resolvePlanArtifactPath,
  stageOf,
  loadPlanPolicy,
  lintPlanArtifactText,
  relintPlanArtifact,
  formatPlanLangViolations,
};
