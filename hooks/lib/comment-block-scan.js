// hooks/lib/comment-block-scan.js
//
// SSOT (CPR-SSOT) for comment-run recognition, ported from the awk core
// bin/review-comment-block-size.d/scan.sh used to carry, so the Edit-time
// hook and the commit-time CLI judge files identically.
//
// FILE-LEVEL filter rules are duplicated in bash; drift net is
// tests/feature-1894-hook-comment-block/filter-parity.sh. Purity contract:
// no config, no filesystem, no output — every value arrives as an argument.
"use strict";

// Default threshold: a run of MORE than this many consecutive comment lines is
// a finding. The comparator is strictly `>` — a run of exactly N is allowed.
const DEFAULT_MAX_LINES = 10;

// Default code extensions. Bash twin: the `CODE_FILE_EXTENSIONS:-js;sh;py`
// default in bin/review-comment-block-size.
const DEFAULT_EXTENSIONS = ["js", "sh", "py"];

// Path segments never scanned: vendored trees and archived code.
// Bash twin: the `path_ok()` case arm in bin/review-comment-block-size.
const EXCLUDED_PATH_SEGMENTS = ["node_modules", ".git", "_archive", "_archived"];

// Neutral bridging tokens: a line consisting of only one of these (after
// trim) does not break a comment run, but does not count toward its length
// either. `;;` is deliberately excluded — it is a real bash `case` terminator.
const NEUTRAL_NOOP_TOKENS = Object.freeze([";", ":", "{}", "()", ","]);
const NEUTRAL_NOOP_SET = new Set(NEUTRAL_NOOP_TOKENS);

// parseMaxLines mirrors the bash guard `[[ $T =~ ^[0-9]+$ ]] && [[ $T -gt 0 ]]`.
// Anything else — empty, negative, float, hex, exponent, padded — is not a
// threshold and falls back to the built-in default rather than becoming an
// accidental "no limit".
function parseMaxLines(raw) {
  if (typeof raw === "number") {
    return Number.isInteger(raw) && raw > 0 ? raw : DEFAULT_MAX_LINES;
  }
  if (typeof raw !== "string" || !/^[0-9]+$/.test(raw)) return DEFAULT_MAX_LINES;
  const n = Number(raw);
  return Number.isSafeInteger(n) && n > 0 ? n : DEFAULT_MAX_LINES;
}

// parseExtensions splits the `;`-separated CODE_FILE_EXTENSIONS value. Empty
// elements are dropped; an absent or empty value falls back to the default list.
function parseExtensions(raw) {
  if (typeof raw !== "string") return DEFAULT_EXTENSIONS.slice();
  const parts = raw.split(";").filter((e) => e.length > 0);
  return parts.length > 0 ? parts : DEFAULT_EXTENSIONS.slice();
}

// hasScannableExtension is the bash `ext_ok()`: a plain case-sensitive suffix
// match on the whole path, so `dir.sh/a.md` is not a shell script.
function hasScannableExtension(filePath, extensions) {
  if (typeof filePath !== "string" || filePath.length === 0) return false;
  const list = Array.isArray(extensions) ? extensions : parseExtensions(extensions);
  for (const e of list) {
    if (typeof e !== "string" || e.length === 0) continue;
    if (filePath.endsWith("." + e)) return true;
  }
  return false;
}

// isExcludedPath is the bash `path_ok()` inverted: the segment must be a whole
// path component, so `my_node_modules/` and `_archiver/` are ordinary source.
// Backslashes are normalized first — the Edit-time hook receives Windows paths.
function isExcludedPath(filePath) {
  if (typeof filePath !== "string" || filePath.length === 0) return false;
  const norm = "/" + filePath.replace(/\\/g, "/");
  for (const seg of EXCLUDED_PATH_SEGMENTS) {
    if (norm.indexOf("/" + seg + "/") !== -1) return true;
  }
  return false;
}

// Leading space/tab strip, written as an index scan rather than a regex: a
// single line can be megabytes wide and this runs once per line.
function stripLeadingBlanks(s) {
  let i = 0;
  while (i < s.length) {
    const c = s.charCodeAt(i);
    if (c !== 32 && c !== 9) break;
    i++;
  }
  return i === 0 ? s : s.slice(i);
}

// isBlankLine — a line that is empty or all whitespace (space, tab, form-feed,
// NBSP, etc. — the ECMAScript WhiteSpace class via `\s`). Such a line bridges
// a comment run without counting toward its length.
function isBlankLine(s) {
  return /^\s*$/.test(s);
}

/**
 * scanText(text, threshold) -> { runs, count, longest }
 *
 * Classifies each line as comment / neutral / code. A run is comment lines
 * bridged across neutral lines (blank, or a lone NEUTRAL_NOOP_TOKENS entry);
 * any code line resets it. Only runs strictly LONGER than `threshold` are
 * reported (`longest` is 0 when none). Under-detects on purpose, as the awk
 * core did: `--`, `%`, and Python triple quotes are not comment markers.
 */
function scanText(text, threshold) {
  const t = parseMaxLines(threshold);
  const runs = [];
  let longest = 0;
  if (typeof text !== "string" || text.length === 0) {
    return { runs, count: 0, longest };
  }

  // A leading BOM belongs to the file, not to line 1's content.
  const body = text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
  const lines = body.split("\n");
  // split() invents a trailing empty element for a newline-terminated file.
  if (lines.length > 0 && lines[lines.length - 1] === "") lines.pop();

  let inBlock = false;
  let run = 0;
  let first = 0;
  let last = 0;

  const flush = () => {
    if (run > t) {
      runs.push({ start: first, end: last, len: run });
      if (run > longest) longest = run;
    }
    run = 0;
  };

  for (let i = 0; i < lines.length; i++) {
    const lineNo = i + 1;
    let s = lines[i];
    if (s.length > 0 && s.charCodeAt(s.length - 1) === 13) s = s.slice(0, -1);
    s = stripLeadingBlanks(s);

    const head2 = s.slice(0, 2);
    let kind;
    if (lineNo === 1 && head2 === "#!") {
      // A shebang is not a comment block, but only on line 1.
      kind = "code";
    } else if (inBlock) {
      kind = "comment";
      if (s.indexOf("*/") !== -1) inBlock = false;
    } else if (isBlankLine(s) || NEUTRAL_NOOP_SET.has(s.trim())) {
      // Block-internal lines are decided above, before this bridging check —
      // a no-op token inside `/* ... */` must still count as a comment line.
      kind = "neutral";
    } else if (head2 === "/*") {
      kind = "comment";
      if (s.slice(2).indexOf("*/") === -1) inBlock = true;
    } else if (head2 === "//" || s.charAt(0) === "#" || head2 === "*/") {
      kind = "comment";
    } else if (
      s.charAt(0) === "*" &&
      (s.length === 1 || s.charAt(1) === " " || s.charAt(1) === "\t")
    ) {
      kind = "comment";
    } else {
      kind = "code";
    }

    if (kind === "comment") {
      if (run === 0) first = lineNo;
      run++;
      last = lineNo;
    } else if (kind === "code") {
      flush();
    }
    // kind === "neutral" bridges the run without touching it.
  }
  flush();

  return { runs, count: runs.length, longest };
}

module.exports = {
  DEFAULT_MAX_LINES,
  EXCLUDED_PATH_SEGMENTS,
  NEUTRAL_NOOP_TOKENS,
  hasScannableExtension,
  isExcludedPath,
  parseExtensions,
  parseMaxLines,
  scanText,
};
