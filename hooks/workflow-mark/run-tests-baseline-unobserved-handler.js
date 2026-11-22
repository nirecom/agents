"use strict";
// Issue #3067 — WORKFLOW_RUN_TESTS_BASELINE_UNOBSERVED_ACCEPTED.
//
//   echo "<<WORKFLOW_RUN_TESTS_BASELINE_UNOBSERVED_ACCEPTED: {reason}>>"
// Completes a run_tests whose only blockers are rows the base could not observe (approvable list:
// bin/workflow/lib/run-tests-baseline-evidence/disposition.js), bound to the HEAD the baseline
// classified; check and write share one appendEvents builder. The commit gate re-checks HEAD.

const path = require("path");
const { spawnSync } = require("child_process");
const { RUN_TESTS_BASELINE_UNOBSERVED_ACCEPTED_RE_DQ, RUN_TESTS_BASELINE_UNOBSERVED_ACCEPTED_LOOKSLIKE_RE } =
  require("../lib/sentinel-patterns");
const { appendEvents } = require("../workflow-state/state-io");
const { sanitizeLine } = require("../lib/output-sanitize");
const { normalizeCwd } = require("../lib/path-normalize");
const { APPROVAL_SENTINEL_FORM, approvalRejection, approvalEvents } = require(path.join(
  __dirname, "..", "..", "bin", "workflow", "lib", "run-tests-baseline-evidence", "approval"));

const LABEL = "RUN_TESTS_BASELINE_UNOBSERVED_ACCEPTED";
const ORIGIN = "workflow-mark-run-tests-baseline-unobserved";

// The Bash call's cwd wins over the resolved session cwd, as in the commit gate's repoDir.
function currentHead(toolCwd, repoCwd) {
  const dir = normalizeCwd(toolCwd) || repoCwd;
  if (!dir) return null;
  const r = spawnSync("git", ["-C", dir, "rev-parse", "--verify", "--quiet", "HEAD"],
    { encoding: "utf8", timeout: 2000, windowsHide: true });
  const out = r.status === 0 ? String(r.stdout || "").trim() : "";
  return out === "" ? null : out;
}

function accept(sessionId, reason, head) {
  const verdict = { why: "state was not examined", count: 0 };
  appendEvents(sessionId, (_events, current) => {
    const entry = (current && current.steps && current.steps.run_tests) || null;
    verdict.why = approvalRejection({ sessionId, entry, currentHead: head });
    if (verdict.why !== null) return [];
    const events = approvalEvents(entry, reason, ORIGIN);
    verdict.count = events.find((e) => e.key === "baseline_unobserved_accept").value.tests.length;
    return events;
  });
  return verdict;
}

function handle(ctx) {
  const { cmd, sessionId, repoCwd, toolCwd, pushMessage, pushUnapplied } = ctx;
  const m = cmd.match(RUN_TESTS_BASELINE_UNOBSERVED_ACCEPTED_RE_DQ);
  if (m) {
    const reason = sanitizeLine(m[1].trim());
    if (reason.replace(/\s/g, "").length < 3) {
      pushUnapplied(`workflow-mark: ${LABEL} rejected — reason too short; state unchanged. Re-emit: ${APPROVAL_SENTINEL_FORM}`);
      return true;
    }
    if (!sessionId) {
      pushUnapplied(`workflow-mark: could not resolve session_id — ${LABEL} NOT recorded.`);
      return true;
    }
    const head = currentHead(toolCwd, repoCwd);
    if (head === null) {
      pushUnapplied(`workflow-mark: ${LABEL} rejected — HEAD of the session's worktree cannot be read; state unchanged.`);
      return true;
    }
    try {
      const v = accept(sessionId, reason, head);
      if (v.why !== null) {
        pushUnapplied(`workflow-mark: ${LABEL} rejected — ${v.why}; state unchanged.`);
        return true;
      }
      pushMessage(
        `[workflow] ${LABEL}: run_tests complete with ${v.count} failing test(s) approved without a base ` +
          `observation at HEAD ${head.slice(0, 7)}. A commit after HEAD moves needs a new approval; ` +
          "the Final Report and PR body must say so."
      );
    } catch (e) {
      pushUnapplied(`workflow-mark: failed to write state — ${e.message}. ${LABEL} NOT recorded.`);
    }
    return true;
  }
  if (RUN_TESTS_BASELINE_UNOBSERVED_ACCEPTED_LOOKSLIKE_RE.test(cmd)) {
    pushUnapplied(
      `workflow-mark: malformed WORKFLOW_${LABEL} — expected: ${APPROVAL_SENTINEL_FORM} ` +
        "{reason} must not contain ( ) ; | & > or a backtick."
    );
    return true;
  }
  return false;
}

module.exports = { handle };
