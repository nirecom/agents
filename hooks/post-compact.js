#!/usr/bin/env node
// Claude Code PostCompact hook: re-inject session ID into conversation context

const { getConvLangInjection } = require("./lib/conv-lang");
const { readState, getStatePath, VALID_STEPS } = require("./workflow-state");
const { isDeliveryBoundaryReset } = require("./workflow-state/effective-state/delivery-boundary");
const { SESSION_ID_ANNOUNCE_PREFIX } = require("./lib/session-announce");

// Steps left out of the post-compact summary: sentinel-driven or sub-steps the
// model does not act on from this list, and the session-close tail.
const POST_COMPACT_HIDDEN_STEPS = new Set([
  "branching_complete", "review_tests", "write_code", "run_tests",
  "pre_final_report_gate", "final_report",
]);
const WORKFLOW_STEPS = VALID_STEPS.filter((s) => !POST_COMPACT_HIDDEN_STEPS.has(s));

const { readHookInput } = require("./lib/read-stdin");

let sessionId = null;
const hookInput = readHookInput();
if (hookInput.kind === "ok") {
  try {
    sessionId = hookInput.input.session_id || null;
  } catch (e) {}
}

if (!sessionId) {
  console.log("{}");
  process.exit(0);
}

// The one event the artifact exists for is also the one the compacted
// transcript can no longer describe, and PostCompact is the only code that runs
// at that instant. A lost breadcrumb must never cost the re-injection below.
try {
  const { appendAutoRecord } = require("./lib/handoff-auto-record");
  appendAutoRecord(sessionId, {
    cls: "B",
    step: "-",
    key: "compaction",
    summary: `context compaction occurred at ${new Date().toISOString()}`,
    pointer: "-",
  }, "compaction");
} catch (_e) { /* fail-open */ }

// #2594: point at session-progress.md (path only — never created here) and leave the compaction's
// pending state for hooks/progress-nudge.js. Outside the workflow active period: nothing.
let progressLine = null;
try {
  const { isWorkflowActivePeriod } = require("./lib/workflow-active-period");
  if (isWorkflowActivePeriod(sessionId)) {
    const { progressPathFor } = require("./lib/progress-file");
    const p = progressPathFor(sessionId);
    if (p) progressLine = `session-progress.md: ${p} (read "Current state" first)`;
    require("./lib/progress-compaction").recordCompaction(sessionId, Date.now());
  }
} catch (_e) { /* fail-open */ }

try {
  const lines = [
    // Lineage evidence for #1305 — the compacted transcript carries this
    // attachment forward, naming the pre-compact session. SSOT: lib/session-announce.
    `${SESSION_ID_ANNOUNCE_PREFIX}${sessionId}`,
  ];
  // The routed path (#2511): a legacy-root session's file is named where it really lives.
  try { lines.push(`State file: ${getStatePath(sessionId)}`); } catch (_e) { /* invalid sid: omit */ }
  try {
    const state = readState(sessionId);
    lines.push("");
    lines.push("Workflow progress:");
    if (state && state.steps) {
      if (state.cwd)        lines.push(`Worktree: ${state.cwd}`);
      if (state.git_branch) lines.push(`Branch: ${state.git_branch}`);
      let pendingCount = 0;
      for (const step of WORKFLOW_STEPS) {
        const s = state.steps[step] || {};
        const status = s.status || "pending";
        // #2527: a delivery-boundary reset records a delivery, not outstanding work.
        const boundary = step === "user_verification" && isDeliveryBoundaryReset(s);
        const annotation = !boundary ? ""
          : s.reset_reason === "post-merge" ? " (reset after pr merge — expected)"
            : " (reset after protected push — expected)";
        lines.push(`- ${step}: ${status}${annotation}`);
        if (status === "pending" && !boundary) {
          pendingCount++;
        }
      }
      if (pendingCount > 0) {
        lines.push("→ Workflow is in progress. Run /resume-session to resume from the current step.");
      }
    } else {
      lines.push("(no state file found — run /workflow-init)");
    }
  } catch (_e) { /* fail-open */ }

  if (progressLine) lines.push(progressLine);

  try {
    const convLang = getConvLangInjection();
    if (convLang) lines.push(convLang);
  } catch (_e) { /* fail-open */ }

  // Re-inject the model-conditional hardening line after compaction. Read-only:
  // the flag was frozen at SessionStart, so PostCompact never resolves the model
  // and never writes state.
  try {
    const { getVerbosePromptInjection } = require("./lib/verbose-prompt");
    const verbosePrompt = getVerbosePromptInjection(sessionId);
    if (verbosePrompt) lines.push(verbosePrompt);
  } catch (_e) { /* fail-open */ }

  console.log(JSON.stringify({ additionalContext: lines.join("\n") }));
} catch (e) {
  console.log("{}");
}
