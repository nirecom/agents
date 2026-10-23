"use strict";
// hooks/lib/size-limits.js — the one source of every file-size limit (#2631) and the shared
// predicate the edit-time, CONFIRM and commit paths call. Pure: no fs, no child processes.
// rules/coding/file-split.md carries the generated table (bin/print-size-limits --markdown-table).
// Verdict: post > HARD is "hard" unless post < pre ("shrink"); WARN < post <= HARD is "warn".

const LIMITS = Object.freeze({
  code: Object.freeze({ unit: "lines", warn: 300, hard: 500 }),
  prompt: Object.freeze({ unit: "lines", warn: 100, hard: 200 }),
  docs: Object.freeze({ unit: "lines", warn: 300, hard: 500 }),
  history: Object.freeze({ unit: "lines", warn: 500, hard: 800, role: "rotation" }),
  intent: Object.freeze({ unit: "lines", warn: 100, hard: 200 }),
  outline: Object.freeze({ unit: "lines", warn: 100, hard: 200 }),
  detail: Object.freeze({ unit: "lines", warn: 300, hard: 500 }),
  progress: Object.freeze({ unit: "chars", warn: 400, hard: 600 }),
});

const SCOPES = Object.freeze({
  code: "Code files (`CODE_FILE_EXTENSIONS`, default `js;sh;py`)",
  prompt: "`skills/**/SKILL.md`, `rules/**/*.md`, `agents/**/*.md`, `skills/_shared/**/*.md`",
  docs: "Other `.md` files (`docs/**/*.md`, `README.md`)",
  history: "`history.md`, `CHANGELOG.md` — rotation threshold, used by `bin/doc-rotate.py`",
  intent: "Plan artifact `<sid>-intent.md`",
  outline: "Plan artifact `<sid>-outline.md`",
  detail: "Plan artifact `<sid>-detail.md`",
  progress: "The `## Current state` section of `<sid>-session-progress.md`",
});

const CURRENT_STATE_HEADING = /^## Current state[ \t]*$/;
const EXEMPT_BASENAMES = new Set(["history.md", "CHANGELOG.md"]);
const EXEMPT_DIRS = new Set(["_archive", "_archived"]);
// Rotated record directories hold append-only documents; a code file placed there is still judged.
const EXEMPT_DOC_DIRS = new Set(["history", "changelog"]);

function countNewlines(s) {
  let n = 0;
  for (let i = s.indexOf("\n"); i !== -1; i = s.indexOf("\n", i + 1)) n++;
  return n;
}

function countLines(text) {
  if (typeof text !== "string" || text.length === 0) return 0;
  const n = countNewlines(text);
  return text.endsWith("\n") ? n : n + 1;
}

function codePoints(s) {
  return typeof s === "string" ? Array.from(s).length : 0;
}

function currentStateChars(text) {
  if (typeof text !== "string") return 0;
  const lines = text.replace(/\r\n/g, "\n").split("\n");
  const start = lines.findIndex((l) => CURRENT_STATE_HEADING.test(l));
  if (start === -1) return 0;
  let end = start + 1;
  while (end < lines.length && !lines[end].startsWith("## ")) end++;
  return codePoints(lines.slice(start + 1, end).join("\n").trim());
}

function measure(kind, text) {
  const limit = LIMITS[kind];
  if (!limit) throw new Error(`size-limits: unknown kind: ${kind}`);
  return limit.unit === "chars" ? currentStateChars(text) : countLines(text);
}

function judge(kind, pre, post) {
  const limit = LIMITS[kind];
  if (!limit) return null;
  const before = Number.isFinite(pre) ? pre : 0;
  let verdict = "ok";
  if (post > limit.hard) verdict = post < before ? "shrink" : "hard";
  else if (post > limit.warn) verdict = "warn";
  return { verdict, kind, value: post, pre: before, warn: limit.warn, hard: limit.hard, unit: limit.unit };
}

// A replace_all edit repeats an unknown number of times, so its growth can never net into a decrease.
function fragmentDelta(edits, size) {
  let total = 0;
  let unboundedGrowth = false;
  for (const e of Array.isArray(edits) ? edits : []) {
    if (!e || typeof e !== "object") continue;
    const d = size(String(e.new_string == null ? "" : e.new_string)) - size(String(e.old_string == null ? "" : e.old_string));
    if (e.replace_all === true && d > 0) unboundedGrowth = true;
    total += d;
  }
  return unboundedGrowth ? Math.max(total, 0) : total;
}

function newlineDelta(edits) {
  return fragmentDelta(edits, countNewlines);
}

function codePointDelta(edits) {
  return fragmentDelta(edits, codePoints);
}

function isExemptRepoPath(rel) {
  if (typeof rel !== "string" || rel.length === 0) return false;
  const segs = rel.replace(/\\/g, "/").split("/").filter((s) => s.length > 0 && s !== ".");
  if (segs.length === 0) return false;
  const base = segs[segs.length - 1];
  if (EXEMPT_BASENAMES.has(base)) return true;
  const dirs = segs.slice(0, -1);
  if (dirs.some((s) => EXEMPT_DIRS.has(s))) return true;
  return base.endsWith(".md") && dirs.some((s) => EXEMPT_DOC_DIRS.has(s));
}

module.exports = {
  LIMITS, SCOPES, countLines, currentStateChars, measure, judge, newlineDelta, codePointDelta, isExemptRepoPath,
};
