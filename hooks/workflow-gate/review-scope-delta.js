"use strict";
// Re-review scope (#2327): which staged files a repeat /review-tests must read.
// Pure functions — no I/O. bin/select-review-scope.js owns the git/state reads.

const { isReviewScopeExcludedPath, isReviewScopeTestPath } = require("./review-tests-evidence");

const MANIFEST_KEY = "review_scope_manifest";
// Only the workflow_init downstream reset starts a new run. The RESET_FROM clear
// (reset-handler) and the write_code reopen keep the record for the delta.
const DISCARDING_CLEAR_ORIGIN = "workflow-init-downstream-reset";

function isValidManifest(rec) {
  return !!rec && typeof rec === "object" && rec.v === 1 &&
    !!rec.files && typeof rec.files === "object" && !Array.isArray(rec.files);
}

// The latest non-null review_scope_manifest annotation still in force, or null.
function latestRecordedManifest(events) {
  let latest = null;
  for (const ev of Array.isArray(events) ? events : []) {
    if (!ev || ev.step !== "review_tests") continue;
    if (ev.kind === "step_annotations_cleared" && ev.origin === DISCARDING_CLEAR_ORIGIN) {
      latest = null;
    } else if (ev.kind === "step_annotation" && ev.key === MANIFEST_KEY) {
      latest = ev.value == null ? null : ev.value;
    }
  }
  return latest;
}

function inScope(files) {
  const out = {};
  for (const [p, oid] of Object.entries(files || {})) {
    if (!isReviewScopeExcludedPath(p)) out[p] = oid;
  }
  return out;
}

// Per-file change set D between the recorded and the current manifest.
function changeSet(recordedFiles, currentFiles) {
  const added = [];
  const modified = [];
  const deleted = [];
  for (const [p, oid] of Object.entries(currentFiles)) {
    if (!(p in recordedFiles)) added.push(p);
    else if (recordedFiles[p] !== oid) modified.push(p);
  }
  for (const p of Object.keys(recordedFiles)) {
    if (!(p in currentFiles)) deleted.push(p);
  }
  return { added, modified, deleted };
}

// { scope: "full"|"delta", reason, review, deleted, inventory, sources } — repo-relative paths.
function decideReviewScope(recorded, current) {
  const cur = inScope(current && current.files);
  const curPaths = Object.keys(cur).sort();
  const tests = curPaths.filter(isReviewScopeTestPath);
  const sources = curPaths.filter((p) => !isReviewScopeTestPath(p));
  const full = (reason) => ({ scope: "full", reason, review: tests, deleted: [], inventory: [], sources });

  if (!isValidManifest(recorded)) return full("no-record");
  const d = changeSet(inScope(recorded.files), cur);
  const changed = [...d.added, ...d.modified, ...d.deleted];
  if (changed.length === 0) return full("explicit-rereview");
  if (changed.some((p) => !isReviewScopeTestPath(p))) return full("impl-changed");

  const review = [...d.added, ...d.modified].sort();
  const reviewSet = new Set(review);
  return {
    scope: "delta",
    reason: "tests-only",
    review,
    deleted: d.deleted.slice().sort(),
    inventory: tests.filter((p) => !reviewSet.has(p)),
    sources,
  };
}

module.exports = { latestRecordedManifest, decideReviewScope };
