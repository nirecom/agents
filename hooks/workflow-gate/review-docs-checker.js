"use strict";

const path = require("path");
const { spawnSync } = require("child_process");
const { hasStagedDocChanges } = require("../lib/staged-doc-changes");

const GATES_SCRIPT = path.join(__dirname, "..", "..", "bin", "review-doc-gates");

/**
 * Evaluate the review_docs step. Returns
 * { action: 'not_handled' | 'skip' | 'block', reason?: string }.
 * The recorded status is NOT trusted: the gates re-run against the staged blobs
 * every time (evidence-bound, TOCTOU-safe), and this runs even in a docs-only
 * session — review_docs is the exception the docs-only short-circuit must skip.
 */
function checkReviewDocs(step, stepState, opts) {
  if (step !== "review_docs") return { action: "not_handled" };

  const { repoDir } = opts || {};

  // Nothing staged to review → skip regardless of recorded status.
  if (!hasStagedDocChanges(repoDir)) return { action: "skip" };

  const res = spawnSync("bash", [GATES_SCRIPT, "--staged"], {
    cwd: repoDir,
    encoding: "utf8",
  });

  // Infra failure (bash/git missing, spawn error): fail closed with a reason.
  if (res.error) return { action: "block", reason: "doc-gates-unavailable" };
  if (res.status === 0) return { action: "skip" };
  return { action: "block", reason: "doc-gates-failed" };
}

module.exports = { checkReviewDocs };
