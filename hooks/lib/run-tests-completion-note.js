"use strict";
// The one line a run_tests completed without proof leaves in the Final Report and the PR body:
// UNRUNNABLE accept (#2501 D5-7) or baseline auto-accept (#2688). Read from the run_tests
// annotations only (CPR-SSOT); a later run tombstones them, so a session whose final run was
// green prints nothing. baseline-preexisting (a proof, not an accept) is not disclosed; new
// failure lines a baseline saw (#2956) are, whatever the basis.

const path = require("path");

const UNRUNNABLE_ACCEPT_BASIS = "unrunnable-accepted";
const BASELINE_AUTO_BASIS = "baseline-auto-accepted";
// Written by the pre-#2688 user grant; only read here, never written again.
const LEGACY_USER_BASIS = "baseline-user-accepted";
const PROVEN_CLASSES = ["preexisting", "preexisting-inherited"];

function oneLine(v) {
  return String(v).replace(/[\r\n]+/g, " ").slice(0, 200);
}

function unrunnableLine(entry) {
  const count = Number.isInteger(entry.unrunnable_count) ? entry.unrunnable_count : "?";
  const runtimes = entry.unrunnable_runtimes ? oneLine(entry.unrunnable_runtimes) : "unknown";
  const reason = entry.unrunnable_accept_reason ? oneLine(entry.unrunnable_accept_reason) : "(none)";
  return `- Unverified tests: ${count} UNRUNNABLE accepted (missing runtimes: ${runtimes}; reason: ${reason})`;
}

// Every classified entry without a pre-existing proof was auto-accepted (record refuses otherwise).
function autoLine(entry) {
  const entries = (entry.baseline_classification && Array.isArray(entry.baseline_classification.entries))
    ? entry.baseline_classification.entries : [];
  const auto = entries.filter((e) => e && !PROVEN_CLASSES.includes(e.class));
  const causes = [...new Set(auto.map((e) => e.detail).filter(Boolean))].join(", ") || "unknown";
  const note = typeof entry.baseline_note === "string" && entry.baseline_note !== "" ? `\`${oneLine(entry.baseline_note).replace(/`/g, "'")}\`` : "(none)"; // code span: no markdown, no @mention notice
  return `- Unverified tests: ${auto.length} failing test(s) auto-accepted without baseline proof ` +
    `(causes: ${oneLine(causes)}; note: ${note})`;
}

const LEGACY_LINE = "- Unverified tests: failing tests accepted by the user before #2688 (legacy grant; details not re-read)";

function basisLine(entry) {
  if (entry.completion_basis === UNRUNNABLE_ACCEPT_BASIS) return unrunnableLine(entry);
  if (entry.completion_basis === BASELINE_AUTO_BASIS) return autoLine(entry);
  if (entry.completion_basis === LEGACY_USER_BASIS) return LEGACY_LINE;
  return null;
}

// #2956 S9: new failure lines a baseline record saw, kept past later runs (not a RUN_TOMBSTONE),
// so they are disclosed whatever basis completed the step. One line per path.
function newLinesLines(entry) {
  const seen = entry.baseline_new_lines_seen;
  if (!seen || typeof seen !== "object" || Array.isArray(seen)) return [];
  return Object.keys(seen).sort().filter((p) => seen[p] && typeof seen[p] === "object").map((p) => {
    const s = seen[p];
    const head = Array.isArray(s.head) ? s.head.map(String).join("; ") : "";
    return oneLine(`- Baseline new failure lines: ${p} (${s.count} new lines, ${s.class}: ${head})`);
  });
}

// completionNote(entry) — the lines for a run_tests entry, or null when nothing needs disclosing.
function completionNote(entry) {
  if (!entry || entry.status !== "complete") return null;
  const lines = [basisLine(entry)].filter((l) => l !== null).concat(newLinesLines(entry));
  return lines.length === 0 ? null : lines.join("\n");
}

// readCompletionNote(sessionId) — the same line from the session's state; null on any error.
function readCompletionNote(sessionId) {
  try {
    const { readState } = require(path.join(__dirname, "..", "workflow-state", "state-io"));
    const state = readState(sessionId);
    return completionNote(state && state.steps && state.steps.run_tests);
  } catch {
    return null;
  }
}

module.exports = { UNRUNNABLE_ACCEPT_BASIS, BASELINE_AUTO_BASIS, completionNote, readCompletionNote };
