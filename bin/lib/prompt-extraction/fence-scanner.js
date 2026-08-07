"use strict";
// bin/lib/prompt-extraction/fence-scanner.js
// rules/prompt.md §1.5 detection: fenced code blocks holding 3+ content lines.
//
// Fence nesting is decided by marker length, not by nesting depth: a 3-backtick
// line inside a 4-backtick fence is content, not a close. Tilde fences are
// treated identically to backtick fences (CPR-UNV — one rule for the whole domain).

const FENCE_RE = /^\s*(`{3,}|~{3,})/;
const MIN_FENCE_LINES = 3;
const MIN_INDENT_LINES = 3;

/**
 * Boolean mask marking every line that is a fence marker or fence interior.
 * Shared with procedure-scanner.js so both scanners agree on fence state (CPR-SSOT).
 * @param {string[]} lines
 * @returns {boolean[]}
 */
function fenceMask(lines) {
  const mask = new Array(lines.length).fill(false);
  let openChar = null;
  let openLen = 0;
  for (let i = 0; i < lines.length; i += 1) {
    const m = FENCE_RE.exec(lines[i]);
    if (openChar === null) {
      if (m) {
        openChar = m[1][0];
        openLen = m[1].length;
        mask[i] = true;
      }
      continue;
    }
    mask[i] = true;
    if (m && m[1][0] === openChar && m[1].length >= openLen) {
      openChar = null;
    }
  }
  return mask;
}

/**
 * @param {string[]} lines
 * @param {{emitNotes?: boolean}} [opts]
 * @returns {{violations: Array<{line: number, lineCount: number}>,
 *            notes: Array<{line: number, lineCount: number}>}}
 */
function scanFences(lines, opts) {
  const emitNotes = Boolean(opts && opts.emitNotes);
  const violations = [];
  const notes = [];

  let openChar = null;
  let openLen = 0;
  let startLine = 0;
  let contentLines = 0;

  let indentRun = 0;
  let indentStart = 0;

  const flushIndent = () => {
    if (emitNotes && indentRun >= MIN_INDENT_LINES) {
      notes.push({ line: indentStart, lineCount: indentRun });
    }
    indentRun = 0;
  };

  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    const m = FENCE_RE.exec(line);

    if (openChar === null) {
      if (m) {
        flushIndent();
        openChar = m[1][0];
        openLen = m[1].length;
        startLine = i + 1;
        contentLines = 0;
        continue;
      }
      if (/^ {4}\S/.test(line)) {
        if (indentRun === 0) indentStart = i + 1;
        indentRun += 1;
      } else if (line.trim() !== "") {
        flushIndent();
      }
      continue;
    }

    if (m && m[1][0] === openChar && m[1].length >= openLen) {
      if (contentLines >= MIN_FENCE_LINES) {
        violations.push({ line: startLine, lineCount: contentLines });
      }
      openChar = null;
      continue;
    }
    contentLines += 1;
  }

  // Unterminated fence: judge what was accumulated rather than dropping it.
  if (openChar !== null && contentLines >= MIN_FENCE_LINES) {
    violations.push({ line: startLine, lineCount: contentLines });
  }
  flushIndent();

  return { violations, notes };
}

module.exports = { scanFences, fenceMask };
