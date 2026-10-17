"use strict";
// The wording of one progress request. Addressed to the model only: it says what to do and
// why, and never asks the model to talk to the user — except the one burst line.

const RULE = "rules/progress-update.md";

// buildMessage({steps, bytesSince, compaction, burst, progressPath}) -> string.
function buildMessage(r) {
  const lines = ["[progress check] time to update session-progress.md. Reasons:"];
  for (const step of r.steps || []) lines.push(`- step complete: ${step}`);
  if (typeof r.bytesSince === "number") lines.push(`- the transcript grew by about ${Math.round(r.bytesSince / 1024)}KB since the last update`);
  if (r.compaction) lines.push("- a context compaction happened");
  lines.push(`file: ${r.progressPath}`);
  lines.push(`Per ${RULE}, rewrite "Current state" and add facts not yet recorded.`);
  lines.push("If nothing changed, write nothing and continue. Use Edit only; do not explain.");
  if (r.burst) {
    lines.push("Compactions are coming in quick succession. Tell the user this one thing: propose, once, updating session-progress.md and handing over to a new session.");
  }
  return lines.join("\n");
}

module.exports = { buildMessage };
