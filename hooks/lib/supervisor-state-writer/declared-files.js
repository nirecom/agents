"use strict";

// #2448 — the declared_files snapshot of audit-run.js. It keeps two sets:
// plan_files (first path token of each detail "Files to modify" line, the
// scope-drift baseline) and files (plan_files inside the working-tree diff),
// with diff_scope recording how files was scoped: empty | unavailable | scoped.

const ledger = require("../audit-ledger");
const { parseDetailFilesToModify } = require("../branch-diff");

// Same coverage rule as computeScopeDrift: an exact path, or a directory declaration.
function covers(declared, changed) {
  return changed === declared || changed.startsWith(declared.endsWith("/") ? declared : `${declared}/`);
}

function scopeToDiff(planFiles, changedFiles) {
  if (!Array.isArray(changedFiles)) return { files: [], diff_scope: "unavailable" };
  if (changedFiles.length === 0) return { files: [], diff_scope: "empty" };
  return { files: planFiles.filter((d) => changedFiles.some((p) => covers(d, p))), diff_scope: "scoped" };
}

// changedFiles is null when the diff could not be computed.
function snapshotDeclaredFiles(audit, opts) {
  const { trIds, runId, plansDir, planSessionId, nowIso, narrowed, changedFiles } = opts;
  const prior = audit.declared_files;
  // TR3 (re)seeds plan_files and detail_key, and so does a narrowing, so drift is
  // judged against what the plan declares now. A later arm only re-scopes files.
  if (trIds.includes("TR3") || narrowed === true) {
    const { computeArtifactKey } = require("../diff-fingerprint");
    const detailKey = computeArtifactKey(plansDir, planSessionId, ["intent", "outline", "detail"]);
    const planFiles = parseDetailFilesToModify(plansDir, planSessionId) || [];
    audit.declared_files = ledger.capDeclaredFiles({
      snapshot_at: nowIso,
      run_id: runId,
      detail_key: typeof detailKey === "string" && detailKey.length > 0 ? detailKey : null,
      plan_files: planFiles,
      ...scopeToDiff(planFiles, changedFiles),
    });
    return;
  }
  if (!prior || !Array.isArray(prior.plan_files)) return;
  if (!Array.isArray(changedFiles) || changedFiles.length === 0) return;
  audit.declared_files = ledger.capDeclaredFiles({ ...prior, ...scopeToDiff(prior.plan_files, changedFiles) });
}

// The scope-drift baseline: plan_files when present; a legacy snapshot (no
// plan_files) reads files, then the detail parse.
function declaredFilesOf(audit, plansDir, planSessionId) {
  const snapshot = audit.declared_files;
  if (snapshot && Array.isArray(snapshot.plan_files) && snapshot.plan_files.length > 0) return snapshot.plan_files;
  if (snapshot && Array.isArray(snapshot.files) && snapshot.files.length > 0) return snapshot.files;
  return parseDetailFilesToModify(plansDir, planSessionId);
}

module.exports = { snapshotDeclaredFiles, declaredFilesOf };
