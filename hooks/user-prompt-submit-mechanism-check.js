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

// Lazy + cached + fail-closed: a require() failure at module load used to be
// fatal for the whole hook (the top-level require threw before main() could
// run its own try/catch). Deferring it here means a broken policy module can
// only make isPromptNotifyExempt() find no matching row (never exempt) —
// exactly like every other setup failure in this file, never a hook crash.
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

// isKnownStep(step): true only for a step name the workflow state machine
// actually recognizes (or the state-level pseudo-step). Guards describe()'s
// interpolation of finding.step into additionalContext/systemMessage — a
// state file rewritten outside the normal appendEvents path (projection.js
// does not re-validate event.step against VALID_STEPS at read time) could
// otherwise carry an attacker-chosen string straight into the next prompt's
// injected context. Fail-CLOSED: any require/read error reads as unknown.
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

// `state-absent` is the commonest shape this hook sees — most prompts are typed
// in sessions that never ran /workflow-init — so it is normal, not a failure.
// Reporting it would also write a ledger that suppresses the session's FIRST
// genuine stall, reintroducing #1979 through the code meant to close it.
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

// Exemption predicates for rows registered with promptNotify:true in
// EXEMPTION_MATRIX (hooks/lib/stop-exemption-policy.js). Per-finding: a
// finding is exempt only when its OWN step's last mark came from the WI-10
// lookahead hook specifically, not from any origin isWorkflowStarted misses
// (state-corrupt's pseudo-step, or a resumed session's real stall) (#2169).
const PROMPT_NOTIFY_EXEMPTIONS = [
  {
    id: "pre-workflow-init",
    test: (sid, finding, deps) =>
      !deps.isWorkflowStarted(sid) && deps.isLookaheadOnlyInFlight(sid, finding.step),
  },
];

// Assembles the predicates PROMPT_NOTIFY_EXEMPTIONS needs. A require()/setup
// failure here is caught by the caller (isFindingExemptFromPromptNotify) and
// resolves to NOT exempt — the opposite direction from isWorkflowStarted's own
// fail-closed — so a broken gate can only over-notify, never go silent.
function buildPromptNotifyDeps() {
  const { isWorkflowStarted, isLookaheadOnlyInFlight } = require("./workflow-state");
  return { isWorkflowStarted, isLookaheadOnlyInFlight };
}

// isPromptNotifyExempt(sid, finding, deps): true when some row registered
// with promptNotify:true in EXEMPTION_MATRIX currently holds for this
// finding. Mirrors firstExemption()'s fail-closed-on-throw contract
// (stop-premature-stop-guard.js): a predicate that throws is NOT exempt.
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

// isFindingExemptFromPromptNotify(sid, finding): the per-finding entry point
// main() calls. A setup failure at buildPromptNotifyDeps() is caught here and
// resolves to "not exempt" — deliberately the OPPOSITE direction from
// isWorkflowStarted's own fail-closed — so this gate never swallows a genuine
// finding just because its own setup broke.
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

  // #2169: exemption is evaluated PER FINDING, after reportableFindings, since
  // each finding's own step decides whether it is a bare WI-10 lookahead mark
  // (exempt) or a real stall (state-corrupt's pseudo-step, or a resumed
  // session) that must still surface — a single session-wide gate would wrongly
  // swallow those too.
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
