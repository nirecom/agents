"use strict";

// Shared helpers for parsing and annotating WORKTREE_NOTES.md.
// Consumed by:
//   - bin/worktree-notes-triage.js (parseSectionEntries, markEntryPromoted)
//   - bin/worktree-notes-append.js (parseSectionEntries)
//   - bin/render-final-report/notes.js (scanSection)
//
// Marker convention on an entry line (canonical, fixed order):
//   - <body> <!-- severity: high --> <!-- promoted: #N -->
// Recognition is strict (canonical form only, so a malformed severity tag
// fails safe to "compress"); stripping is lenient (any trailing comment, any
// order), so no raw marker ever leaks into rendered output.

const PROMOTED_MARKER_RE = / <!-- promoted: #(\d+) -->$/;
const SEVERITY_MARKER_RE = /^- (?:(?!<!--).)*<!-- severity: (high) -->(?: <!-- promoted: #\d+ -->)?$/;
const TRAILING_MARKER_RE = / <!--[^<>]*-->$/;

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

// Strip the leading "- " and every trailing HTML comment marker, whatever its
// kind or order. In-body text such as "(#42)" is preserved.
function entryBody(rawLine) {
  let body = String(rawLine);
  if (body.startsWith("- ")) body = body.slice(2);
  while (TRAILING_MARKER_RE.test(body)) {
    body = body.replace(TRAILING_MARKER_RE, "");
  }
  return body.trim();
}

// Single-pass section scan. Returns exactly:
//   { entries, strayCount, stoppedAtSubHeading, subHeading }
// entries: Array<{raw, lineNumber, hasMarker, severity, body}> — lineNumber is
//   1-indexed against the full document; "- (none)" placeholders are skipped.
// strayCount: non-blank lines inside the section that are not "- " bullets.
// stoppedAtSubHeading / subHeading: a "### " line cut the scan short, so the
//   remaining entries were never seen (they are lost, not merely compressed).
// A duplicate "## <heading>" re-enters the same section rather than ending it.
function scanSection(text, heading) {
  const target = `## ${heading}`;
  const lines = text.split(/\r?\n/);
  const entries = [];
  let inSection = false;
  let strayCount = 0;
  let stoppedAtSubHeading = false;
  let subHeading = null;
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    if (line.trimEnd() === target) { inSection = true; continue; }
    if (!inSection) continue;
    if (line.startsWith("### ")) {
      stoppedAtSubHeading = true;
      subHeading = line;
      break;
    }
    if (line.startsWith("## ")) break;
    if (!line.startsWith("- ")) {
      if (line.trim() !== "") strayCount += 1;
      continue;
    }
    if (line === "- (none)") continue;
    entries.push({
      raw: line,
      lineNumber: i + 1,
      hasMarker: PROMOTED_MARKER_RE.test(line),
      severity: SEVERITY_MARKER_RE.test(line) ? "high" : null,
      body: entryBody(line),
    });
  }
  return { entries, strayCount, stoppedAtSubHeading, subHeading };
}

// Thin wrapper: the entry list is the only thing most consumers need.
function parseSectionEntries(text, heading) {
  return scanSection(text, heading).entries;
}

// Append ` <!-- promoted: #<issueNumber> -->` to the line at lineNumber (1-indexed).
// Preserves CRLF if the original line used it. Out-of-range → unchanged.
// The unconditional end-of-line append is what keeps the canonical marker order
// (severity first, promoted last) intact.
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

module.exports = {
  PROMOTED_MARKER_RE,
  SEVERITY_MARKER_RE,
  TRAILING_MARKER_RE,
  extractSection,
  entryBody,
  scanSection,
  parseSectionEntries,
  markEntryPromoted,
};
