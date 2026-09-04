#!/usr/bin/env node
// Claude Code UserPromptSubmit hook: surface a stalled workflow mechanism at the
// next user turn (#1979).
//
// A session once sat idle overnight waiting for a notification that never came:
// write_tests stayed in_progress, every quiet layer kept honouring it, and
// nothing ever told the user. The next prompt is the earliest moment a human is
// present to hear about it. Fail-open: every error path exits 0.
"use strict";

const fs = require("fs");
const { detectStalledSteps, reportMechanismFailureOnce, STATE_PSEUDO_STEP } = require("./lib/mechanism-failure");

const SID_RE = /^[A-Za-z0-9_-]+$/;

// Lazy + cached: a require() failure here must not crash the hook — resolves to {} (no exemption) instead.
let _exemptionMatrixCache = null;
function getExemptionMatrix() {
  if (_exemptionMatrixCache) return _exemptionMatrixCache;
  try {
    _exemptionMatrixCache = require("./lib/stop-exemption-policy").EXEMPTION_MATRIX || {};
  } catch (_e) {
    _exemptionMatrixCache = {};
  }
  return _exemptionMatrixCache;
}

// Guards describe()'s interpolation of finding.step into the injected prompt context — a state
// file rewritten outside appendEvents isn't re-validated against VALID_STEPS at read time.
function isKnownStep(step) {
  if (step === STATE_PSEUDO_STEP) return true;
  try {
    const { VALID_STEPS } = require("./workflow-state/state-io");
    return Array.isArray(VALID_STEPS) && VALID_STEPS.indexOf(step) !== -1;
  } catch (_e) {
    return false;
  }
}

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(4096);
  try {
    while (true) {
      const n = fs.readSync(0, buf, 0, buf.length);
      if (n === 0) break;
      chunks.push(buf.slice(0, n));
    }
  } catch (_e) {}
  return Buffer.concat(chunks).toString("utf8");
}

// `state-absent` is normal (no /workflow-init yet), not a failure — reporting it would burn the
// once-per-session ledger slot and suppress the session's first genuine stall (reintroducing #1979).
function reportableFindings(sid) {
  const findings = detectStalledSteps(sid) || [];
  return findings.filter((f) => f && f.kind !== "state-absent");
}

function describe(findings) {
  const items = findings
    .map((f) => "'" + (isKnownStep(f.step) ? f.step : "(unrecognized-step)") + "' (" + f.kind + ")")
    .join(", ");
  return (
    "mechanism-failure: the workflow mechanism has stalled — " + items + ". " +
    "Nothing settled the step, so every quiet layer kept honouring it. " +
    "Check whether the delegated work actually finished, then settle the step " +
    "with next-step --advance (or reset it) before continuing."
  );
}

// Per-finding, not session-wide: a finding is exempt only when its OWN step's last
// mark came from the WI-10 lookahead hook, not from any other isWorkflowStarted miss (#2169).
const PROMPT_NOTIFY_EXEMPTIONS = [
  {
    id: "pre-workflow-init",
    test: (sid, finding, deps) =>
      !deps.isWorkflowStarted(sid) && deps.isLookaheadOnlyInFlight(sid, finding.step),
  },
];

function buildPromptNotifyDeps() {
  const { isWorkflowStarted, isLookaheadOnlyInFlight } = require("./workflow-state");
  return { isWorkflowStarted, isLookaheadOnlyInFlight };
}

// Mirrors firstExemption()'s fail-closed-on-throw contract (stop-premature-stop-guard.js).
function isPromptNotifyExempt(sid, finding, deps) {
  const exemptionMatrix = getExemptionMatrix();
  for (const row of PROMPT_NOTIFY_EXEMPTIONS) {
    const matrixRow = exemptionMatrix[row.id];
    if (!matrixRow || !matrixRow.promptNotify) continue;
    try {
      if (row.test(sid, finding, deps)) return true;
    } catch (_e) { /* fail-closed: not exempt, keep scanning */ }
  }
  return false;
}

// A buildPromptNotifyDeps() setup failure resolves to "not exempt" here — the opposite of
// isWorkflowStarted's own fail-closed — so a broken gate can only over-notify, never go silent.
function isFindingExemptFromPromptNotify(sid, finding) {
  try {
    return isPromptNotifyExempt(sid, finding, buildPromptNotifyDeps());
  } catch (_e) {
    return false;
  }
}

function main() {
  let input = null;
  try { input = JSON.parse(readStdin()); } catch (_e) { input = null; }

  let sid = input && typeof input.session_id === "string" ? input.session_id : null;
  if (!sid) {
    try { sid = require("./workflow-state").resolveSessionId() || null; } catch (_e) { sid = null; }
  }
  if (!sid || !SID_RE.test(sid)) return {};

  const allFindings = reportableFindings(sid);
  if (allFindings.length === 0) return {};

  const findings = allFindings.filter((f) => !isFindingExemptFromPromptNotify(sid, f));
  if (findings.length === 0) return {};

  for (const finding of findings) {
    try { reportMechanismFailureOnce(sid, finding); } catch (_e) {}
  }

  const message = describe(findings);
  return {
    blocks: true,
    systemMessage: message,
    hookSpecificOutput: {
      hookEventName: "UserPromptSubmit",
      additionalContext: message,
    },
  };
}

if (require.main === module) {
  let out = {};
  try { out = main() || {}; } catch (_e) { out = {}; }
  try { process.stdout.write(JSON.stringify(out)); } catch (_e) {}
  process.exit(0);
}

module.exports = {
  reportableFindings, describe, isKnownStep,
  PROMPT_NOTIFY_EXEMPTIONS, isPromptNotifyExempt, isFindingExemptFromPromptNotify,
};
