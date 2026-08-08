"use strict";

// Compresses WORKTREE_NOTES.md finding sections for the Final Report (#1886).
// Verbatim dumping used to emit thousands of chars into the reply (CPR-UO);
// now every entry collapses to a title line except `<!-- severity: high -->`
// entries, which stay verbatim. One summary line carries counts + backup pointer.
//
// Pure functions only (Stop hook critical path) — no file access, subprocess, network, or model calls.

const { scanSection } = require("../../hooks/lib/worktree-notes-sections");

// Output sections of the Final Report. Not shared with triage.js's promotion
// targets or args.js's input allowlist — same names, three different scopes.
const NOTES_SECTIONS = ["BugsFound", "RelatedTasks", "NextTasks"];
const TITLE_MAX_CHARS = 120;
const COMPRESSED_LIST_MAX = 10;

// hooks/stop-final-report-guard.js refuses a report containing an unsubstituted
// `<TOKEN>`. A finding body may legitimately mention one, so escape both ends.
// The pattern is a subordinate copy of that guard's tokenRegex — keep in sync.
function sanitizeTokens(s) {
  return String(s).replace(/<([A-Z][A-Z0-9_]+)>/g, "&lt;$1&gt;");
}

// One bounded line: whitespace collapsed, truncated on code points so a
// surrogate pair is never split in half. (Grapheme clusters are out of scope.)
function titleLine(body) {
  const collapsed = String(body).replace(/\s+/g, " ").trim();
  const points = Array.from(collapsed);
  if (points.length <= TITLE_MAX_CHARS) return collapsed;
  return `${points.slice(0, TITLE_MAX_CHARS).join("")}…`;
}

// Returns { BugsFound, RelatedTasks, NextTasks }, each a ready-to-emit string
// ("(none)" when the section yields nothing).
function compressNotesSections(text, options) {
  const opts = options || {};
  const backupPath = opts.backupPath || "(none)";
  const result = {};
  for (const section of NOTES_SECTIONS) {
    const { entries, strayCount, stoppedAtSubHeading, subHeading } =
      scanSection(text, section);
    const high = entries.filter((e) => e.severity === "high");
    const rest = entries.filter((e) => e.severity !== "high");

    const lines = [];
    for (const entry of high) lines.push(`- ${sanitizeTokens(entry.body)}`);
    for (const entry of rest.slice(0, COMPRESSED_LIST_MAX)) {
      lines.push(`- ${sanitizeTokens(titleLine(entry.body))}`);
    }

    if (rest.length > 0 || strayCount > 0 || stoppedAtSubHeading) {
      const parts = [];
      if (rest.length > 0) {
        parts.push(`compressed: ${rest.length} entries — title line only`);
      }
      if (rest.length > COMPRESSED_LIST_MAX) {
        parts.push(`${rest.length - COMPRESSED_LIST_MAX} not listed above`);
      }
      if (strayCount > 0) {
        parts.push(`${strayCount} non-entry line(s) omitted`);
      }
      if (stoppedAtSubHeading) {
        parts.push(`section truncated at "${sanitizeTokens(titleLine(subHeading))}"`);
      }
      // Exempt from the length cap: the backup path is the only pointer to the
      // full text, so truncating it would defeat the whole mechanism.
      lines.push(`- (${parts.join("; ")}; full text: ${backupPath})`);
    }

    result[section] = lines.length === 0 ? "(none)" : lines.join("\n");
  }
  return result;
}

module.exports = {
  compressNotesSections,
  sanitizeTokens,
  titleLine,
  NOTES_SECTIONS,
  TITLE_MAX_CHARS,
  COMPRESSED_LIST_MAX,
};
