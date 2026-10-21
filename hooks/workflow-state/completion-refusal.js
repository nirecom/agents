"use strict";
// hooks/workflow-state/completion-refusal.js — the one place that words a refused completion
// (#2529): the approval boundary (UnapprovedCompletionError) and the glossary boundary
// (GlossaryCheckIncompleteError). The caller prefixes its own name ("record-step-verdict: ").

const { UnapprovedCompletionError, confirmSentinelFor, evaluateCompletionApproval } = require("./completion-approval");
const { GlossaryCheckIncompleteError, glossaryRefusalErrorOfComplete } = require("./glossary-check/record");

// completionRefusalOf(e, step) -> { kind: "unapproved" | "glossary-incomplete", code, message } | null.
function completionRefusalOf(e, step) {
  const s = (e && e.step) || step;
  if (e instanceof UnapprovedCompletionError) {
    return {
      kind: "unapproved", code: e.code,
      message: `${s} NOT recorded — no user approval on record (${e.code}). ` +
        `Ask the user to approve, then emit: echo "<<${confirmSentinelFor(s)}: {summary}>>" ` +
        `(or verify CONFIRM_${String(s).toUpperCase()}=off in your config).`,
    };
  }
  if (e instanceof GlossaryCheckIncompleteError) {
    return {
      kind: "glossary-incomplete", code: e.code,
      message: `${s} NOT recorded — the glossary check is not complete (${e.code}). ${e.recovery}`.trim(),
    };
  }
  return null;
}

// recordedCompleteRefusalOf(sid, step, state, opts) -> the completionRefusalOf shape for a gated
// step already RECORDED complete that the effective view reopens, else null. The decision is
// effective-state's gatedCompleteRefusal (one predicate); this only words it for a writer.
function recordedCompleteRefusalOf(sid, step, state, opts) {
  const entry = state && state.steps && state.steps[step];
  const raw = (entry && entry.status) || "pending";
  // Lazy: effective-state sits above this module in the require graph.
  const why = require("./effective-state").gatedCompleteRefusal(step, raw, state, sid, opts);
  if (!why) return null;
  if (why === "unapproved-complete") {
    const v = evaluateCompletionApproval(sid, step, state);
    return completionRefusalOf(new UnapprovedCompletionError(step, v.code || "no-approval-record"), step);
  }
  const err = glossaryRefusalErrorOfComplete(sid, step, state, opts) || new GlossaryCheckIncompleteError(step, why, "");
  return completionRefusalOf(err, step);
}

module.exports = { completionRefusalOf, recordedCompleteRefusalOf };
