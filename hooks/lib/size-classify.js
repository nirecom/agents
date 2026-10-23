"use strict";
// hooks/lib/size-classify.js — which size-limits kind a path belongs to (#2631).
// Plans-dir artifacts: classifyPlansPath. Repo files: classifyRepoPath (prompt -> docs -> code;
// exempt stream records are null). matchesKind serves the review bins' --kind filter.

const path = require("path");
const { isExemptRepoPath } = require("./size-limits");
const { hasScannableExtension, isExcludedPath } = require("./comment-block-scan");

const PROMPT_RE = /^(skills\/.+\/SKILL\.md|rules\/.+\.md|agents\/.+\.md|skills\/_shared\/.+\.md)$/;
const PLAN_STAGE_KIND = Object.freeze({
  intent: "intent", outline: "outline", detail: "detail", "session-progress": "progress",
});

function normRel(rel) {
  return String(rel).replace(/\\/g, "/").replace(/^(\.\/)+/, "");
}

function samePath(a, b) {
  const x = path.resolve(a);
  const y = path.resolve(b);
  return process.platform === "win32" ? x.toLowerCase() === y.toLowerCase() : x === y;
}

function classifyPlansPath(absPath, opts) {
  try {
    if (typeof absPath !== "string" || absPath.length === 0) return null;
    const { getWorkflowPlansDir } = require("./workflow-plans-dir");
    const plansDir = (opts && opts.plansDir) || getWorkflowPlansDir();
    if (!samePath(path.dirname(absPath), plansDir)) return null;
    const { syncedArtifactStage } = require("./plans-artifact-registry");
    const stage = syncedArtifactStage(path.basename(absPath));
    return (stage && PLAN_STAGE_KIND[stage]) || null;
  } catch (_e) {
    return null;
  }
}

function isSkippedRepoPath(rel) {
  return rel.length === 0 || isExemptRepoPath(rel) || isExcludedPath(rel);
}

function classifyRepoPath(rel, exts) {
  if (typeof rel !== "string") return null;
  const r = normRel(rel);
  if (isSkippedRepoPath(r)) return null;
  if (PROMPT_RE.test(r)) return "prompt";
  if (r.endsWith(".md")) return "docs";
  if (hasScannableExtension(r, exts)) return "code";
  return null;
}

function matchesKind(kind, rel, exts) {
  if (typeof rel !== "string") return false;
  if (kind === "docs") {
    const r = normRel(rel);
    return r.endsWith(".md") && !isSkippedRepoPath(r);
  }
  if (kind === "prompt" || kind === "code") return classifyRepoPath(rel, exts) === kind;
  return false;
}

module.exports = { classifyPlansPath, classifyRepoPath, matchesKind };
