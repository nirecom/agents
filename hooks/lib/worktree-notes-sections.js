"use strict";

// Parse and annotate WORKTREE_NOTES.md entries (triage, append and render-final-report consumers).
// Canonical entry tail, fixed order (#2019, #3145): severity, instance?, loc?, test-failure?, pr-scope,
// base?, rescoped-from?, handoff-rejected?, then one terminal marker (promoted | disposed |
// user-accepted). composeEntryMarkers is the only writer of that order. Recognition is strict: a non-canonical line reads as severity medium,
// pr-scope other; legacy `none` reads as not-defect and a retired user-acknowledged marker is skipped.
// Stripping is lenient, so no raw marker leaks into rendered output. Contract: skills/_shared/notes-promotion.md.

const PROMOTED_MARKER_RE = / <!-- promoted: #(\d+) -->$/;
const SEVERITY_MARKER_RE = /^- ((?:(?!<!--).)*?) <!-- severity: (high|medium|low|not-defect|none) -->(.*)$/;
// The retired #2903 marker; a legacy line carrying it is read with the marker stripped.
const USER_ACK_MARKER_RE = /^ <!-- user-acknowledged: (?:true|false) -->/;
const TERMINAL_MARKER_RE = / <!-- (?:promoted: #(\d+)|disposed: (fixed|known-limits|discard|handed-off)|user-accepted: ([^<>\r\n]{1,120})) -->$/;
const TAIL_MARKERS_RE = /^(?: <!-- instance: ((?:(?!-->|<!--).)+?) -->)?(?: <!-- loc: ((?:(?!-->|<!--).)+?) -->)?( <!-- test-failure -->)?(?: <!-- pr-scope: (this-pr|other) -->)?(?: <!-- base: ([0-9a-f]{40}) -->)?( <!-- rescoped-from: this-pr -->)?( <!-- handoff-rejected -->)?$/;
const USER_ACCEPTED_REASON_MAX = 120;
const TRAILING_MARKER_RE = / <!--[^<>]*-->$/;

const SEVERITIES = Object.freeze(["high", "medium", "low", "not-defect"]);
const PR_SCOPES = Object.freeze(["this-pr", "other"]);
const DISPOSED_KINDS = Object.freeze(["fixed", "known-limits", "discard", "handed-off"]);

function composeEntryMarkers({ severity, instance, loc, testFailure, prScope, base, rescopedFrom }) {
  let out = ` <!-- severity: ${severity} -->`;
  if (instance) out += ` <!-- instance: ${instance} -->`;
  if (loc) out += ` <!-- loc: ${loc} -->`;
  if (testFailure) out += " <!-- test-failure -->";
  out += ` <!-- pr-scope: ${prScope} -->`;
  if (base) out += ` <!-- base: ${base} -->`;
  if (rescopedFrom) out += ` <!-- rescoped-from: ${rescopedFrom} -->`;
  return out;
}

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

// The canonical fields of one entry line; null when the line is not canonical.
function parseCanonical(line) {
  const m = SEVERITY_MARKER_RE.exec(line);
  if (m === null) return null;
  let tail = m[3];
  const terminal = TERMINAL_MARKER_RE.exec(tail);
  if (terminal !== null) tail = tail.slice(0, terminal.index);
  const t = TAIL_MARKERS_RE.exec(tail.replace(USER_ACK_MARKER_RE, ""));
  if (t === null) return null;
  return {
    body: m[1].trim(),
    severity: m[2] === "none" ? "not-defect" : m[2],
    instance: t[1] === undefined ? null : t[1],
    loc: t[2] === undefined ? null : t[2],
    testFailure: t[3] !== undefined,
    prScope: t[4] === undefined ? "other" : t[4],
    base: t[5] === undefined ? null : t[5],
    rescopedFrom: t[6] === undefined ? null : "this-pr",
    handoffRejected: t[7] !== undefined,
  };
}

function parseEntryLine(line) {
  const promoted = PROMOTED_MARKER_RE.exec(line);
  const terminal = TERMINAL_MARKER_RE.exec(line);
  const c = parseCanonical(line) || {
    body: entryBody(line), severity: "medium", instance: null, loc: null,
    testFailure: false, prScope: "other", base: null, rescopedFrom: null, handoffRejected: false,
  };
  const userAccepted = terminal !== null && terminal[3] !== undefined ? terminal[3] : null;
  return Object.assign(c, {
    hasMarker: promoted !== null || userAccepted !== null,
    promotedNumber: promoted ? parseInt(promoted[1], 10) : null,
    disposed: terminal !== null && terminal[2] !== undefined ? terminal[2] : null,
    userAccepted,
  });
}

// Single-pass section scan -> { entries, strayCount, stoppedAtSubHeading, subHeading }.
// entries: {raw, lineNumber (1-indexed), ...parseEntryLine}; "- (none)" placeholders are skipped.
// strayCount: non-blank non-bullet lines. A "### " line cuts the scan short (later entries are
// lost, not compressed). A duplicate "## <heading>" re-enters the same section.
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
    entries.push(Object.assign({ raw: line, lineNumber: i + 1 }, parseEntryLine(line)));
  }
  return { entries, strayCount, stoppedAtSubHeading, subHeading };
}

// Thin wrapper: the entry list is the only thing most consumers need.
function parseSectionEntries(text, heading) {
  return scanSection(text, heading).entries;
}

// Rewrite the line at lineNumber (1-indexed) with edit(line), preserving every line
// terminator (CRLF included). Out-of-range → unchanged.
function editLine(text, lineNumber, edit) {
  if (!Number.isInteger(lineNumber) || lineNumber < 1) return text;
  const parts = text.split(/(\r\n|\n)/);
  const idx = (lineNumber - 1) * 2;
  if (idx >= parts.length || typeof parts[idx] !== "string") return text;
  parts[idx] = edit(parts[idx]);
  return parts.join("");
}

// The terminal marker is always last, so an end-of-line append keeps the canonical order.
function markEntryPromoted(text, lineNumber, issueNumber) {
  return editLine(text, lineNumber, (l) => `${l} <!-- promoted: #${issueNumber} -->`);
}

function markEntryDisposed(text, lineNumber, kind) {
  if (!DISPOSED_KINDS.includes(kind)) return text;
  return editLine(text, lineNumber, (l) => `${l} <!-- disposed: ${kind} -->`);
}

// handoff-rejected sits before any terminal marker; a line already carrying it is unchanged.
function markEntryHandoffRejected(text, lineNumber) {
  return editLine(text, lineNumber, (l) => {
    if (parseEntryLine(l).handoffRejected) return l;
    const terminal = TERMINAL_MARKER_RE.exec(l);
    if (terminal === null) return `${l} <!-- handoff-rejected -->`;
    return `${l.slice(0, terminal.index)} <!-- handoff-rejected -->${l.slice(terminal.index)}`;
  });
}

// Recompose a canonical line from its parsed fields; a non-canonical line is left unchanged.
function recompose(line, change) {
  const c = parseCanonical(line);
  if (c === null) return line;
  const terminal = TERMINAL_MARKER_RE.exec(line);
  const next = change(Object.assign({}, c), terminal === null ? "" : terminal[0]);
  const rejected = next.handoffRejected ? " <!-- handoff-rejected -->" : "";
  return `- ${next.body}${composeEntryMarkers(next)}${rejected}${next.terminal}`;
}

// A rescope away from this-pr withdraws a `disposed: fixed` claim; other terminals are kept.
function markEntryRescoped(text, lineNumber) {
  return editLine(text, lineNumber, (l) => recompose(l, (c, terminal) => Object.assign(c, {
    prScope: "other", rescopedFrom: "this-pr", terminal: terminal === " <!-- disposed: fixed -->" ? "" : terminal,
  })));
}

function markEntryUnrescoped(text, lineNumber) {
  return editLine(text, lineNumber, (l) => recompose(l, (c, terminal) => (c.rescopedFrom === null
    ? Object.assign(c, { terminal })
    : Object.assign(c, { prScope: "this-pr", rescopedFrom: null, terminal }))));
}

function sanitizeAcceptedReason(reason) {
  return String(reason === undefined || reason === null ? "" : reason)
    .replace(/[\r\n]+/g, " ").replace(/[<>]/g, "").trim().slice(0, USER_ACCEPTED_REASON_MAX).trim();
}

// user-accepted replaces any terminal marker; an empty reason after sanitizing writes nothing.
function markEntryUserAccepted(text, lineNumber, reason) {
  const clean = sanitizeAcceptedReason(reason);
  if (clean === "") return text;
  return editLine(text, lineNumber, (l) => recompose(l, (c) => Object.assign(c, {
    terminal: ` <!-- user-accepted: ${clean} -->`,
  })));
}

module.exports = {
  PROMOTED_MARKER_RE,
  SEVERITY_MARKER_RE,
  USER_ACK_MARKER_RE,
  TERMINAL_MARKER_RE,
  TRAILING_MARKER_RE,
  SEVERITIES,
  PR_SCOPES,
  DISPOSED_KINDS,
  composeEntryMarkers,
  extractSection,
  entryBody,
  parseEntryLine,
  scanSection,
  parseSectionEntries,
  markEntryPromoted,
  markEntryDisposed,
  markEntryHandoffRejected,
  markEntryRescoped,
  markEntryUnrescoped,
  markEntryUserAccepted,
  sanitizeAcceptedReason,
};
