"use strict";

// Compresses WORKTREE_NOTES.md finding sections for the Final Report (#1886).
// Verbatim dumping used to emit thousands of chars into the reply (CPR-UO);
// now every entry collapses to a title line except `<!-- severity: high -->`
// entries, which stay verbatim. Every line leads with `#N ` or `[issue-TBD] `
// (#2904); one backup pointer line appears only when something was omitted.
// Promoted non-high entries with an identical body share one `#N #M ` line
// (#3013); COMPRESSED_LIST_MAX counts those output lines, not entries.
// Entries carrying a `disposed:` terminal marker are not shown (#2019).
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

function isTitleTruncated(body) {
  return Array.from(String(body).replace(/\s+/g, " ").trim()).length > TITLE_MAX_CHARS;
}

// The issue column of an entry line: `#N ` once promoted, else `[issue-TBD] `.
function entryHead(entry) {
  return entry.promotedNumber ? `#${entry.promotedNumber} ` : "[issue-TBD] ";
}

// A Mode A line already ends its body with ` (#N)`; drop it so `#N` is not shown twice.
function displayBody(entry) {
  const dup = ` (#${entry.promotedNumber})`;
  return entry.promotedNumber && entry.body.endsWith(dup)
    ? entry.body.slice(0, -dup.length)
    : entry.body;
}

// Returns one { head, body } per output line, in order of first appearance.
function mergeEntries(entries) {
  const groups = [];
  const byBody = new Map();
  for (const entry of entries) {
    const body = displayBody(entry);
    if (!entry.promotedNumber) {
      groups.push({ head: entryHead(entry), body });
      continue;
    }
    const group = byBody.get(body);
    if (group) {
      if (!group.numbers.includes(entry.promotedNumber)) group.numbers.push(entry.promotedNumber);
      continue;
    }
    const fresh = { numbers: [entry.promotedNumber], body };
    byBody.set(body, fresh);
    groups.push(fresh);
  }
  return groups.map((g) => ({
    head: g.head || g.numbers.map((n) => `#${n} `).join(""),
    body: g.body,
  }));
}

// The indented body lines right below the entry at lineNumber (1-indexed): a high entry keeps its
// whole body verbatim (#2019), so these are shown rather than counted as omitted stray lines.
function continuationLines(allLines, lineNumber) {
  const out = [];
  for (let i = lineNumber; i < allLines.length; i += 1) {
    const l = allLines[i];
    if (!/^\s+\S/.test(l)) break;
    out.push(l);
  }
  return out;
}

// Returns { BugsFound, RelatedTasks, NextTasks }, each a ready-to-emit string
// ("(none)" when the section yields nothing).
function compressNotesSections(text, options) {
  const opts = options || {};
  const backupPath = opts.backupPath || "(none)";
  const result = {};
  const allLines = String(text).split(/\r?\n/);
  for (const section of NOTES_SECTIONS) {
    const scan = scanSection(text, section);
    const { stoppedAtSubHeading, subHeading } = scan;
    let strayCount = scan.strayCount;
    // A disposed entry was listed once by the notes-promotion pass that marked it (#2019);
    // showing it again would repeat it on every Final Report rebuild.
    const entries = scan.entries.filter((e) => e.disposed === null);
    const high = entries.filter((e) => e.severity === "high");
    const rest = mergeEntries(entries.filter((e) => e.severity !== "high"));

    const lines = [];
    for (const entry of high) {
      lines.push(`- ${entryHead(entry)}${sanitizeTokens(displayBody(entry))}`);
      const more = continuationLines(allLines, entry.lineNumber);
      strayCount -= more.length;
      for (const l of more) lines.push(sanitizeTokens(l));
    }
    let truncatedCount = 0;
    for (const { head, body } of rest.slice(0, COMPRESSED_LIST_MAX)) {
      if (isTitleTruncated(body)) truncatedCount += 1;
      lines.push(`- ${head}${sanitizeTokens(titleLine(body))}`);
    }

    const parts = [];
    if (truncatedCount > 0) parts.push(`${truncatedCount} title(s) shortened`);
    if (rest.length > COMPRESSED_LIST_MAX) {
      parts.push(`${rest.length - COMPRESSED_LIST_MAX} not listed above`);
    }
    if (strayCount > 0) parts.push(`${strayCount} non-entry line(s) omitted`);
    if (stoppedAtSubHeading) {
      parts.push(`section truncated at "${sanitizeTokens(titleLine(subHeading))}"`);
    }
    // Exempt from the length cap: the backup path is the only pointer to the
    // full text, so truncating it would defeat the whole mechanism.
    if (parts.length > 0) lines.push(`- (${parts.join("; ")}; full text: ${backupPath})`);

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
