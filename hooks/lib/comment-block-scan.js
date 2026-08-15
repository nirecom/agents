// hooks/lib/comment-block-scan.js
//
// SSOT (CPR-SSOT) for comment-run recognition. Ported 1:1 from the awk core that
// bin/review-comment-block-size.d/scan.sh used to carry, so that the Edit-time
// PreToolUse hook (hooks/block-comment-block-size.js) and the commit-time CLI
// (bin/review-comment-block-size, via review-comment-block-size.d/scan-cli.js)
// judge a file by exactly the same rules.
//
// Deliberate dual representation, not an oversight: the FILE-LEVEL filter rules
// (which extensions count as code, which path segments are skipped) are written
// both here and in bash inside bin/review-comment-block-size — `ext_ok()` and
// `path_ok()` are the bash twins of hasScannableExtension / isExcludedPath. The
// filter runs once per file while the scan core runs once per line, so keeping
// the filter in bash costs nothing and avoids a node spawn per CLI invocation.
// The drift net for that duplication is
// tests/feature-1894-hook-comment-block/filter-parity.sh — change one side and
// the other must move with it.
//
// Purity contract: this module is required from the Edit hot path. It reads no
// configuration, touches no filesystem, and prints nothing. Every value it needs
// arrives as an argument.
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

/**
 * scanText(text, threshold) -> { runs, count, longest }
 *
 * One pass, one state bit (inside a block comment). A run is a maximal stretch
 * of consecutive comment lines; only runs strictly LONGER than `threshold` are
 * reported. `longest` is the longest reported run, or 0 when there are none.
 *
 * Under-detects on purpose, exactly as the awk core did: `--`, `;`, `%` and
 * Python triple quotes are not treated as comment markers.
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
  let start = 0;

  const flush = () => {
    if (run > t) {
      const end = start + run - 1;
      runs.push({ start, end, len: run });
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
    let isComment = false;
    if (lineNo === 1 && head2 === "#!") {
      // A shebang is not a comment block, but only on line 1.
      isComment = false;
    } else if (inBlock) {
      isComment = true;
      if (s.indexOf("*/") !== -1) inBlock = false;
    } else if (head2 === "/*") {
      isComment = true;
      if (s.slice(2).indexOf("*/") === -1) inBlock = true;
    } else if (head2 === "//" || s.charAt(0) === "#" || head2 === "*/") {
      isComment = true;
    } else if (
      s.charAt(0) === "*" &&
      (s.length === 1 || s.charAt(1) === " " || s.charAt(1) === "\t")
    ) {
      isComment = true;
    }

    if (isComment) {
      if (run === 0) start = lineNo;
      run++;
    } else {
      flush();
    }
  }
  flush();

  return { runs, count: runs.length, longest };
}

module.exports = {
  DEFAULT_MAX_LINES,
  EXCLUDED_PATH_SEGMENTS,
  hasScannableExtension,
  isExcludedPath,
  parseExtensions,
  parseMaxLines,
  scanText,
};
