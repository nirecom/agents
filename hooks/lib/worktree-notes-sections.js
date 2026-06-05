"use strict";

// Shared helpers for parsing and annotating WORKTREE_NOTES.md.
// Consumed by:
//   - bin/worktree-notes-triage.js (parseSectionEntries, markEntryPromoted)

const MARKER_RE = / <!-- promoted: #\d+ -->$/;

function extractSection(text, heading) {
  const lines = text.split(/\r?\n/);
  let inSection = false;
  const bullets = [];
  for (const line of lines) {
    if (line === `## ${heading}`) { inSection = true; continue; }
    if (inSection && (line.startsWith("## ") || line.startsWith("### "))) break;
    if (inSection && line.startsWith("- ")) bullets.push(line);
  }
  if (bullets.length === 0) return "(none)";
  if (bullets.length === 1 && bullets[0] === "- (none)") return "(none)";
  return bullets.join("\n");
}

// Returns Array<{raw: string, lineNumber: number, hasMarker: boolean, section?: string}>.
// lineNumber is 1-indexed against the full document.
// Empty array for missing section OR section that contains only "- (none)".
function parseSectionEntries(text, heading) {
  const lines = text.split(/\r?\n/);
  let inSection = false;
  const entries = [];
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    if (line === `## ${heading}`) { inSection = true; continue; }
    if (inSection && (line.startsWith("## ") || line.startsWith("### "))) break;
    if (!inSection) continue;
    if (!line.startsWith("- ")) continue;
    if (line === "- (none)") continue;
    entries.push({
      raw: line,
      lineNumber: i + 1,
      hasMarker: MARKER_RE.test(line),
    });
  }
  return entries;
}

// Append ` <!-- promoted: #<issueNumber> -->` to the line at lineNumber (1-indexed).
// Preserves CRLF if the original line used it. Out-of-range → unchanged.
function markEntryPromoted(text, lineNumber, issueNumber) {
  if (!Number.isInteger(lineNumber) || lineNumber < 1) return text;
  // Split preserving line endings: capture each line's original terminator.
  const parts = text.split(/(\r\n|\n)/);
  // parts alternates: [content, sep, content, sep, ..., trailingContent]
  // Line N (1-indexed) is at parts[(N - 1) * 2].
  const idx = (lineNumber - 1) * 2;
  if (idx >= parts.length) return text;
  const original = parts[idx];
  if (typeof original !== "string") return text;
  parts[idx] = `${original} <!-- promoted: #${issueNumber} -->`;
  return parts.join("");
}

module.exports = { extractSection, parseSectionEntries, markEntryPromoted };
