"use strict";
// Re-review scope (#2327): which staged files a repeat /review-tests must read.
// Pure functions — no I/O. bin/select-review-scope.js owns the git/state reads.
// REASON vocabulary (SSOT) — full: no-record (no valid recorded manifest), explicit-rereview
// (empty change set), no-state (set by the CLI), impl-uncovered (a changed implementation has no
// covering test), large-change (review set > LARGE_CHANGE_REVIEW_RATIO of the staged tests),
// header-map-unavailable (impl change without a usable header map). delta: tests-only (only
// tests changed), impl-changed (changed tests + covering tests; the rest is paths-only inventory).
// A covering test is a staged test whose `Tests:` header names the changed path exactly.

const { isReviewScopeExcludedPath, isReviewScopeTestPath } = require("./review-tests-evidence");

const MANIFEST_KEY = "review_scope_manifest";
// Only the workflow_init downstream reset starts a new run. The RESET_FROM clear
// (reset-handler) and the write_code reopen keep the record for the delta.
const DISCARDING_CLEAR_ORIGIN = "workflow-init-downstream-reset";
const LARGE_CHANGE_REVIEW_RATIO = 0.5;

function isValidManifest(rec) {
  return !!rec && typeof rec === "object" && rec.v === 1 &&
    !!rec.files && typeof rec.files === "object" && !Array.isArray(rec.files);
}

// A plain object whose every value is a string array and which has every staged test as a key.
function isValidHeaderTargets(map, tests) {
  if (!map || typeof map !== "object" || Array.isArray(map)) return false;
  for (const v of Object.values(map)) {
    if (!Array.isArray(v) || !v.every((t) => typeof t === "string")) return false;
  }
  return tests.every((t) => Object.prototype.hasOwnProperty.call(map, t));
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
// headerTargets: { stagedTestPath: [Tests-header token, ...] } or null; read on the impl path only.
function decideReviewScope(recorded, current, headerTargets) {
  const cur = inScope(current && current.files);
  const curPaths = Object.keys(cur).sort();
  const tests = curPaths.filter(isReviewScopeTestPath);
  const sources = curPaths.filter((p) => !isReviewScopeTestPath(p));
  const full = (reason) => ({ scope: "full", reason, review: tests, deleted: [], inventory: [], sources });
  const delta = (reason, review, deleted) => {
    if (review.length > tests.length * LARGE_CHANGE_REVIEW_RATIO) return full("large-change");
    const reviewSet = new Set(review);
    return { scope: "delta", reason, review, deleted, inventory: tests.filter((p) => !reviewSet.has(p)), sources };
  };

  if (!isValidManifest(recorded)) return full("no-record");
  const d = changeSet(inScope(recorded.files), cur);
  const changed = [...d.added, ...d.modified, ...d.deleted];
  if (changed.length === 0) return full("explicit-rereview");

  const changedTests = [...d.added, ...d.modified].filter(isReviewScopeTestPath);
  const deletedTests = d.deleted.filter(isReviewScopeTestPath).sort();
  const changedImpl = changed.filter((p) => !isReviewScopeTestPath(p));
  if (changedImpl.length === 0) return delta("tests-only", changedTests.sort(), deletedTests);

  if (!isValidHeaderTargets(headerTargets, tests)) return full("header-map-unavailable");
  const review = new Set(changedTests);
  for (const p of changedImpl) {
    const covering = tests.filter((t) => headerTargets[t].includes(p));
    if (covering.length === 0) return full("impl-uncovered");
    for (const t of covering) review.add(t);
  }
  return delta("impl-changed", [...review].sort(), deletedTests);
}

module.exports = { LARGE_CHANGE_REVIEW_RATIO, latestRecordedManifest, decideReviewScope };
