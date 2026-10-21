#!/usr/bin/env node
"use strict";
// Stop hook: C4 premature-stop guard — detects ACTION=invoke being ignored and auto-resumes Claude.
// Fires when Claude stops despite next-step returning ACTION=invoke (workflow step pending).
// Records a warning/workflow finding and outputs decision:block to trigger auto-resume.

const fs = require("fs");
const { spawnSync } = require("child_process");
const path = require("path");

const SCRIPT_CHECKOUT_ROOT = path.resolve(__dirname, "..");

// Steps whose ACTION=invoke is handled by a dedicated Stop hook. Emitting a
// second generic block in the same turn would surface two competing messages,
// so this guard stays silent for them (CPR-SC — one owner per condition).
// - pre_final_report_gate → owned by hooks/stop-final-report-guard.js lane B.
const DELEGATED_REASONS = new Set(["pre_final_report_gate"]);

// Exemption table. Add a row to extend the conditions.
// phase="session"          : decidable from session state alone, before next-step runs
// phase="next-step-output" : decidable only after seeing next-step's output (REASON)
// Each test is a pure function of (ctx, deps) — it must not close over module-scope
// `let` bindings from the require.main block, or it throws ReferenceError (see #1794).
// A pause is SCOPED to a step since #1624, so the marker can only be judged
// against the step the session is actually on. Resolved here rather than
// through `deps` so the row adds no new dependency to the table's contract.
function currentStepOf(sid) {
  try {
    return require("./workflow-state/current-step").resolveCurrentEffectiveStep(sid);
  } catch (_e) {
    return null;
  }
}

const C4_EXEMPTIONS = [
  { id: "workflow-off",      phase: "session", test: (c, d) => d.isWorkflowOff(c.sid) },
  { id: "next-step-paused",  phase: "session",
    test: (c, d) => d.isNextStepPaused(c.sid, currentStepOf(c.sid)) },
  { id: "pre-workflow-init", phase: "session", test: (c, d) => !d.isWorkflowStarted(c.sid) },
  { id: "step-in-flight",    phase: "session", test: (c, d) => !!d.anyStepInFlight(c.sid) },
  { id: "delegated-reason",  phase: "next-step-output",
    test: (c, _d) => DELEGATED_REASONS.has(c.reason) },
  // #2277/#2650: a presentation turn with no CONFIRM echo from its continuation, or after a Deny, waits for approval.
  { id: "awaiting-plan-approval", phase: "next-step-output",
    test: (c, _d) => typeof c.reason === "string" && c.reason.startsWith("awaiting-plan-approval:") },
  // #2527 4-4: the human merges the PR on the web; the background poller resumes the session.
  { id: "human-web-merge-wait", phase: "next-step-output",
    test: (c, _d) => c.wait === "human-web-merge" },
  // #2698: next-step-output (not session) so the mechanism-failure lane above stays unchanged.
  { id: "user-dialog-turn", phase: "next-step-output",
    test: (c, d) => d.isUserDialogTurn(c.input) },
];

// Per-finding exemptions that apply to the mechanism-failure lane only. The
// condition mirrors hooks/user-prompt-submit-mechanism-check.js and rests on
// the same EXEMPTION_MATRIX row (pre-workflow-init's c4 column) (#2213).
// Deliberate duplication: intent.md keeps the #2169 side untouched as the
// reference implementation; tests/feature-2169-.../p-wiring.sh cross-checks
// that the two agree.
const C4_MECHANISM_EXEMPTIONS = [
  { id: "pre-workflow-init",
    test: (sid, finding, d) =>
      !d.isWorkflowStarted(sid) && d.isLookaheadOnlyInFlight(sid, finding.step) },
];

function isFindingExemptFromC4(sid, finding, deps) {
  const matrix = require("./lib/stop-exemption-policy").EXEMPTION_MATRIX || {};
  for (const row of C4_MECHANISM_EXEMPTIONS) {
    const matrixRow = matrix[row.id];
    if (!matrixRow || !matrixRow.c4) continue;
    try {
      if (row.test(sid, finding, deps)) return true;
    } catch (_e) {
      // fail-closed: do not exempt
    }
  }
  return false;
}

// Assembles the predicates the table needs. Both the hook body and tests use
// only this function, so the wiring never diverges between the two.
// A require failure throws here and is caught by the caller (the
// require.main block's try/catch) — same handling as any other dependency
// load failure.
function buildExemptionDeps() {
  const { isWorkflowOff, isNextStepPaused } =
    require("./lib/session-markers");
  const { isWorkflowStarted, anyStepInFlight, isLookaheadOnlyInFlight } =
    require("./workflow-state");
  const { isUserDialogTurn } = require("./lib/user-dialog-turn");
  return {
    isWorkflowOff, isNextStepPaused, isWorkflowStarted,
    anyStepInFlight, isLookaheadOnlyInFlight, isUserDialogTurn,
  };
}

// An exemption holds only when it can be actively proven. A predicate that
// throws is treated as NOT holding, and its id is pushed onto `degraded` so
// evaluation continues to the next row. Treating a throw as exempt would let
// a single buggy predicate silence C4 across every session.
function firstExemption(phase, ctx, deps, degraded) {
  for (const e of C4_EXEMPTIONS) {
    if (e.phase !== phase) continue;
    let hit = false;
    try {
      hit = e.test(ctx, deps);
    } catch (_err) {
      if (degraded) degraded.push(e.id);
      continue;
    }
    if (hit) return e.id;
  }
  return null;
}

// Stalled-mechanism findings worth surfacing, or [] on any failure — the guard
// stays fail-OPEN, so a broken detector must never manufacture a block.
// `state-absent` is dropped here (see the call site).
function mechanismStalls(sid) {
  try {
    const { detectStalledSteps } = require("./lib/mechanism-failure");
    const found = detectStalledSteps(sid);
    if (!Array.isArray(found)) return [];
    return found.filter((f) => f && f.kind !== "state-absent");
  } catch (_e) {
    return [];
  }
}

function formatMechanismFailureReason(listed) {
  const { withConvLang } = require("./lib/conv-lang");
  return withConvLang(
    `[C4 mechanism-failure] The workflow mechanism is stalled: ${listed}. ` +
    "The step is recorded in_progress but its record is stale or unusable, so " +
    "next-step guidance cannot be trusted. Inspect the workflow state and settle " +
    "the step before continuing. (Hook: stop-premature-stop-guard.js)");
}

function formatPrematureStopReason({ pendingNote, degradedNote = "" } = {}) {
  const { withConvLang } = require("./lib/conv-lang");
  return withConvLang(`[C4 premature-stop] ${pendingNote} If this turn is waiting on a user decision, ask it with the AskUserQuestion tool instead of plain text. (Hook: stop-premature-stop-guard.js)${degradedNote}`);
}

// Reports each finding at most once per session (the ledger owns idempotency),
// then emits the decision:block payload naming the mechanism and the steps.
function emitMechanismBlock(sid, stalls) {
  try {
    const { reportMechanismFailureOnce } = require("./lib/mechanism-failure");
    for (const f of stalls) reportMechanismFailureOnce(sid, f);
  } catch (_e) {}
  const listed = stalls.map((f) => `${f.step} (${f.kind})`).join(", ");
  const reason = formatMechanismFailureReason(listed);
  try {
    process.stdout.write(JSON.stringify({ decision: "block", reason }) + "\n");
  } catch (_e) {}
}

const { readHookInput, readFailOpenDiagnostic } = require("./lib/read-stdin");

if (require.main === module) {
  const r = readHookInput();
  if (r.kind !== "ok") {
    try {
      fs.writeSync(2, readFailOpenDiagnostic("stop-premature-stop-guard", r, "premature-stop check skipped") + "\n");
    } catch (_) {}
    process.exit(0);
  }
  const input = r.input;

  // Loop prevention: when this hook itself caused Claude to re-invoke, skip.
  if (input.stop_hook_active === true) process.exit(0);

  let resolveSessionId;
  let appendFinding;
  let deps;
  try {
    ({ resolveSessionId } = require("./workflow-state"));
    ({ appendFinding } = require("./lib/supervisor-state-writer"));
    deps = buildExemptionDeps();
  } catch (_) {
    process.exit(0);
  }

  try {
    // Resolve CC session ID from input (used for next-step, workflow-state, and appendFinding).
    let sessionId = null;
    try {
      sessionId = resolveSessionId({
        sessionIdFromInput: input.session_id,
        transcriptPath: input.transcript_path,
      });
    } catch (_) {}
    if (!sessionId) process.exit(0);

    const degraded = [];
    const sessionExemption = firstExemption("session", { sid: sessionId }, deps, degraded);
    // Every session exemption except pre-workflow-init still silences both lanes.
    if (sessionExemption !== null && sessionExemption !== "pre-workflow-init") process.exit(0);

    // #1997: a stalled MECHANISM is fail-fast, and it is decided before
    // next-step runs — a session whose state is stuck often makes next-step
    // report something unrelated (or nothing), so nudging past it would leave
    // the failure invisible, which is the silence #1979 was made of.
    // `state-absent` is excluded: no state at all is the ordinary
    // no-workflow session, already covered by the pre-workflow-init exemption.
    // The lane is judged per-finding (#2213): even when pre-workflow-init holds,
    // a stall NOT explained by the WI-10 lookahead mark (corrupt state, a
    // genuinely claimed step) must still surface.
    const stalls = mechanismStalls(sessionId)
      .filter((f) => !(sessionExemption === "pre-workflow-init" && isFindingExemptFromC4(sessionId, f, deps)));
    if (stalls.length > 0) {
      emitMechanismBlock(sessionId, stalls);
      process.exit(2);
    }

    // The premature-stop (ACTION=invoke) lane keeps its pre-workflow-init exemption.
    if (sessionExemption === "pre-workflow-init") process.exit(0);

    // Locate next-step binary.
    const nextStepPath = path.join(SCRIPT_CHECKOUT_ROOT, "bin", "workflow", "next-step");
    if (!fs.existsSync(nextStepPath)) process.exit(0);

    // Run next-step with CC session ID to check current ACTION.
    const result = spawnSync(process.execPath, [nextStepPath, "--session", sessionId], {
      timeout: 5000,
      encoding: "utf8",
    });
    if (result.status !== 0 || !result.stdout) process.exit(0);

    // Parse ACTION from output.
    const lines = result.stdout.split("\n");
    const actionLine = lines.find((l) => l.startsWith("ACTION="));
    if (!actionLine || actionLine !== "ACTION=invoke") process.exit(0);

    // Delegate reasons owned by a dedicated Stop hook (REASON is single-quoted).
    const reasonLine = lines.find((l) => l.startsWith("REASON="));
    const reasonValue = reasonLine ? reasonLine.slice("REASON=".length).replace(/^'|'$/g, "") : "";
    // #2527 4-4: WAIT names a wait on a human outside Claude (the web merge); unquoted value.
    const waitLine = lines.find((l) => l.startsWith("WAIT="));
    const waitValue = waitLine ? waitLine.slice("WAIT=".length).trim() : "";
    if (firstExemption("next-step-output", { sid: sessionId, reason: reasonValue, wait: waitValue, input }, deps, degraded)) {
      process.exit(0);
    }

    // Extract NEXT_SKILL for the continuation message.
    const skillLine = lines.find((l) => l.startsWith("NEXT_SKILL="));
    const nextSkill = skillLine ? skillLine.replace("NEXT_SKILL=", "").trim() : "";
    // A skill-less step (e.g. branching_complete) carries its recovery in NEXT_HINT (#2527 4-2).
    const hintLine = lines.find((l) => l.startsWith("NEXT_HINT="));
    const nextHint = hintLine ? hintLine.slice("NEXT_HINT=".length).trim().replace(/^'|'$/g, "") : "";

    // Record warning/workflow finding (fail-open — do not suppress continuation on error).
    try {
      appendFinding(sessionId, {
        categories: ["workflow"],
        severity: "warning",
        detail: `premature-stop: ACTION=invoke ignored (${nextSkill ? "skill: " + nextSkill : "no skill; hint: " + (nextHint || "-")})`,
        reporter: "stop-premature-stop-guard",
      });
    } catch (_) {}

    // Output decision:block to auto-resume Claude with the pending skill or recovery.
    const pendingNote = nextSkill
      ? `ACTION=invoke was pending (NEXT_SKILL=${nextSkill}). Run /${nextSkill} now via the Skill tool to continue the workflow.`
      : `ACTION=invoke was pending for a step with no skill. Recovery: ${nextHint || "see bin/workflow/next-step --list for the pending step."}`;
    const degradedNote = degraded.length
      ? ` [warning: exemption predicate(s) failed: ${degraded.join(",")}]`
      : "";
    const reason = formatPrematureStopReason({ pendingNote, degradedNote });
    if (degraded.length) {
      try {
        process.stderr.write(`stop-premature-stop-guard: exemption predicate(s) failed: ${degraded.join(",")}\n`);
      } catch (_) {}
    }
    process.stdout.write(JSON.stringify({ decision: "block", reason }) + "\n");
    process.exit(2);
  } catch (_) {
    // Fail-open: never block on own errors.
    process.exit(0);
  }
}

module.exports = {
  C4_EXEMPTIONS, C4_MECHANISM_EXEMPTIONS,
  buildExemptionDeps, firstExemption, isFindingExemptFromC4,
  formatPrematureStopReason, formatMechanismFailureReason,
};
