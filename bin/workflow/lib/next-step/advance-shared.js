"use strict";
// The forward operation (`--advance`), shared by every member of the advance
// class: bin/workflow/next-step, record-skip-judgment, set-workflow-type and
// (by delegation) record-complexity-and-skip (#1644).
//
// Why it is shared rather than per-CLI: the four members differ only in how they
// derive the target step. The transaction shape — read the pre-write current
// step, record, then optionally ask for the next action — must be identical, or
// a caller could advance without the gates another caller applies.
//
// This module decides from RECORDED FACTS only: session state files and config
// files. It never reads model-authored plan prose.

const {
  VALID_STEPS,
  isSettledStatus,
  readState,
  resolveSessionId,
} = require("../../../../hooks/workflow-state");
const { reconcileEffectiveState } = require("../../../../hooks/workflow-state/effective-state");
const {
  recordStepVerdict,
  ADVANCE_ORIGINS,
} = require("../../../../hooks/workflow-state/record-step-verdict");
const { isTerminalStep } = require("./steps");

// `--status pending` is the existing `--reset` capability under another name, so
// it goes through the same gate rather than acquiring the advance gate set.
const GATE_FOR_STATUS = { pending: "reset" };

// The pre-write current step. Read OUTSIDE the write's lock region and BEFORE
// the write, because the whole point is to compare "the step this call settles"
// against "the step the session was on when the call started".
// Uses the same walk predicate as computeVerdict so the two cannot disagree.
// Fail-open to null: an unreadable state simply means "not the current step".
function resolveCurrentStep(sessionId, opts) {
  try {
    const state = readState(sessionId);
    if (!state) return null;
    const isWfMeta = state.workflow_type === "wf-meta";
    let steps = null;
    try {
      const snapshot = reconcileEffectiveState(state, sessionId, {
        repoDir: (opts && opts.repoDir) || undefined,
        isWfMeta,
      });
      steps = snapshot && snapshot.steps;
    } catch (_) {
      steps = state.steps || null;
    }
    if (!steps) return null;
    for (const step of VALID_STEPS) {
      if (isTerminalStep(step)) continue;
      const status = (steps[step] || {}).status || "pending";
      if (!isSettledStatus(status)) return step;
    }
  } catch (_) { /* fail-open */ }
  return null;
}

// Emits the advance result and, when asked, the next action. Never returns —
// every path exits the process.
//
// opts: { session, binary, step, status, skipReason, skipJudgment,
//         skipVerdictSource, repoDir, next, prefix }
// `prefix` is the CLI's own leading stdout (already newline-terminated); it is
// written only after the session id resolves, so a usage error prints nothing.
function runAdvance(opts) {
  const rawSession = opts.session;
  const sid = resolveSessionId({ sessionIdFromInput: rawSession });
  if (!sid) {
    process.stderr.write(opts.binary + ": could not resolve session id\n");
    process.exit(1);
  }

  // Read before the write, outside the lock region.
  const currentStep = resolveCurrentStep(sid, { repoDir: opts.repoDir });

  const gate = GATE_FOR_STATUS[opts.status] || "advance";
  const verdictOpts = { gate, repoDir: opts.repoDir };
  if (gate === "advance") {
    verdictOpts.provenance = "declared";
    verdictOpts.origin = ADVANCE_ORIGINS[opts.binary] || opts.binary + "-advance";
  }
  if (opts.skipReason !== undefined) verdictOpts.skipReason = opts.skipReason;
  if (opts.skipJudgment !== undefined) verdictOpts.skipJudgment = opts.skipJudgment;
  if (opts.skipVerdictSource !== undefined) verdictOpts.skipVerdictSource = opts.skipVerdictSource;

  const res = recordStepVerdict(sid, opts.step, opts.status, verdictOpts);
  if (!res.ok) {
    // fail-CLOSED on the record side: a failed record never returns a next
    // action, so a caller cannot mistake "not recorded" for "recorded, proceed".
    if (opts.prefix) process.stdout.write(opts.prefix);
    process.stderr.write(res.message + "\n");
    process.exit(res.code);
  }

  if (opts.prefix) process.stdout.write(opts.prefix);
  process.stdout.write(
    "ADVANCED=" + opts.step + " status=" + opts.status + (res.already ? " already=true" : "") + "\n"
  );

  if (!opts.next) process.exit(0);

  // computeVerdict always re-walks from the first step, so the action it returns
  // describes the SESSION's current step — not necessarily the step this call
  // settled. Saying which of the two happened is the contract; guessing is not.
  const inScope = currentStep !== null && currentStep === opts.step;
  process.stdout.write("ADVANCE_SCOPE=" + (inScope ? "current-step" : "not-current-step") + "\n");
  if (!inScope) process.exit(0);

  // computeVerdict owns its own emit()/process.exit(0). It must NOT run inside a
  // lock region — the record transaction above has already released.
  const { computeVerdict } = require("./verdict");
  computeVerdict(rawSession);
  process.exit(0);
}

module.exports = { resolveCurrentStep, runAdvance, GATE_FOR_STATUS };
