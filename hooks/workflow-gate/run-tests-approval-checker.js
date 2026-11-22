"use strict";
// Commit-gate check of a run_tests completed by the user's approval of an unobserved base (#3067).
// The approval is bound to the HEAD it was given at: the commit made on that HEAD passes, and any
// later non-docs-only commit (HEAD moved) is refused until a new run and approval. Read-only.

const { spawnSync } = require("child_process");
const { BASELINE_UNOBSERVED_BASIS } = require("../lib/run-tests-completion-note");

const HEAD_RE = /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/;
const SENTINEL = "echo \"<<WORKFLOW_RUN_TESTS_BASELINE_UNOBSERVED_ACCEPTED: {reason}>>\"";
const REAPPROVE = "Re-approve in the session's worktree: re-run /run-tests, then bin/run-tests-baseline, " +
  `and ask the user to approve again with ${SENTINEL}.`;

function headOf(repoDir) {
  if (!repoDir) return null;
  const r = spawnSync("git", ["-C", repoDir, "rev-parse", "--verify", "--quiet", "HEAD"], { encoding: "utf8", timeout: 2000, windowsHide: true });
  const out = r.status === 0 ? String(r.stdout || "").trim() : "";
  return HEAD_RE.test(out) ? out : null;
}

// checkUnobservedApproval(stepState, { repoDir, docsOnly }) → { action: "pass" | "block", reason? }
function checkUnobservedApproval(stepState, { repoDir, docsOnly }) {
  if (!stepState || stepState.completion_basis !== BASELINE_UNOBSERVED_BASIS) return { action: "pass" };
  if (docsOnly) return { action: "pass" };
  const acc = stepState.baseline_unobserved_accept;
  const approved = acc && typeof acc === "object" ? acc.head : undefined;
  if (typeof approved !== "string" || !HEAD_RE.test(approved)) {
    return { action: "block", reason: `run_tests was approved without a base observation, but the approval records no valid HEAD. ${REAPPROVE}` };
  }
  const now = headOf(repoDir);
  if (now === null) {
    return { action: "block", reason: `run_tests approval cannot be checked: HEAD of ${repoDir} cannot be read. ${REAPPROVE}` };
  }
  if (now !== approved) {
    return { action: "block", reason: `HEAD moved after the run_tests approval without a base observation ` +
      `(approved at ${approved.slice(0, 7)}, HEAD is ${now.slice(0, 7)}). ${REAPPROVE}` };
  }
  return { action: "pass" };
}

module.exports = { checkUnobservedApproval };
