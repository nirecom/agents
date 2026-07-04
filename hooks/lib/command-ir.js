"use strict";

const { tokenizeSegment, splitSegments, REDIRECT_RE, ATTACHED_REDIRECT_RE } = require("./command-parser");

// Extract the file descriptor string from a redirect operator.
// Returns "1" for plain >, "1" for 1>, "2" for 2>, "&" for &>, etc.
function extractFd(op) {
  if (op.length > 0 && /^\d/.test(op)) return op[0];
  if (op.startsWith("&")) return "&";
  return "1";
}

// Detect unclosed quotes in a command string (fail-closed: treat as malformed).
// Returns true when the string has an unclosed single or double quote.
function hasUnclosedQuote(str) {
  let inDouble = false;
  let inSingle = false;
  let i = 0;
  const n = str.length;
  while (i < n) {
    const ch = str[i];
    if (inDouble) {
      if (ch === "\\" && i + 1 < n) { i += 2; continue; }
      if (ch === '"') { inDouble = false; }
      i++;
    } else if (inSingle) {
      if (ch === "'") { inSingle = false; }
      i++;
    } else {
      if (ch === '"') { inDouble = true; i++; }
      else if (ch === "'") { inSingle = true; i++; }
      else { i++; }
    }
  }
  return inDouble || inSingle;
}

// Build a SegmentIR from a segment string.
// { cmd0, argv, redirects, kind, rawText, sub }
// sub is set to true when this segment lives inside a subshell.
function buildSegmentIR(segStr, isSubshell) {
  let tokens;
  try {
    tokens = tokenizeSegment(segStr);
  } catch (e) {
    const seg = { cmd0: "", argv: [], redirects: [], kind: "simple", rawText: segStr };
    if (isSubshell) seg.sub = true;
    return seg;
  }

  const argv = [];
  const redirects = [];
  let i = 0;

  while (i < tokens.length) {
    const tok = tokens[i];
    if (REDIRECT_RE.test(tok)) {
      const op = tok;
      const target = i + 1 < tokens.length ? tokens[i + 1] : "";
      redirects.push({ op, fd: extractFd(op), target });
      i += 2;
      continue;
    }
    const attachedMatch = ATTACHED_REDIRECT_RE.exec(tok);
    if (attachedMatch) {
      // Reconstruct the operator part (everything before the captured target)
      const target = attachedMatch[1];
      const op = tok.slice(0, tok.length - target.length);
      redirects.push({ op, fd: extractFd(op), target });
      i++;
      continue;
    }
    argv.push(tok);
    i++;
  }

  const cmd0 = argv.length > 0 ? argv.shift() : "";

  const seg = { cmd0, argv, redirects, kind: "simple", rawText: segStr };
  if (isSubshell) seg.sub = true;
  return seg;
}

/**
 * Parse a bash command string into an IR (Intermediate Representation).
 *
 * Returns:
 * {
 *   segments: SegmentIR[],   // array of segment IRs
 *   cmd0: string,            // first token of first segment (or "")
 *   argv: string[],          // remaining tokens of first segment
 *   redirects: RedirectIR[], // redirects from first segment only: {op, fd, target}
 *   kind: string,            // "simple"|"pipeline"|"subshell"|"empty"
 *   rawText: string,         // ALWAYS the original cmd string, even on parseFailure
 *   parseFailure: boolean    // true when tokenization throws
 * }
 *
 * rawText is always set before any processing begins.
 */
function parse(cmd) {
  const rawText = cmd;

  try {
    if (!cmd || typeof cmd !== "string" || cmd.trim() === "") {
      return { segments: [], cmd0: "", argv: [], redirects: [], kind: "empty", rawText, parseFailure: false };
    }

    // Fail-closed: unclosed quotes indicate malformed input
    if (hasUnclosedQuote(cmd)) {
      return { segments: [], cmd0: "", argv: [], redirects: [], kind: "empty", rawText, parseFailure: true };
    }

    const trimmed = cmd.trim();

    // Determine kind
    let kind;
    const isSubshell = trimmed.startsWith("(");
    if (isSubshell) {
      kind = "subshell";
    } else {
      const segStrings = splitSegments(cmd);
      if (segStrings.length > 1) {
        kind = "pipeline";
      } else {
        kind = "simple";
      }
    }

    const segStrings = splitSegments(cmd);
    const segments = segStrings.map((s) => buildSegmentIR(s, isSubshell));

    // Top-level IR comes from first segment
    const first = segments.length > 0 ? segments[0] : { cmd0: "", argv: [], redirects: [] };

    return {
      segments,
      cmd0: first.cmd0,
      argv: first.argv.slice(),
      redirects: first.redirects,
      kind,
      rawText,
      parseFailure: false,
    };
  } catch (e) {
    return { segments: [], cmd0: "", argv: [], redirects: [], kind: "empty", rawText, parseFailure: true };
  }
}

/**
 * Returns true if target is an OS temporary directory path (POSIX or Windows).
 * Used to gate temp-path redirects: redirects to temp paths are non-persistent
 * and can be treated as read for classification purposes.
 */
function isOsTempPath(target) {
  if (target == null || typeof target !== "string" || target === "") return false;
  // Reject path traversal: ../  can escape the temp root (CWE-22)
  if (/(?:^|[/\\])\.\.(?:[/\\]|$)/.test(target)) return false;
  // POSIX temp paths
  if (/^\/tmp\//.test(target) || /^\/var\/tmp\//.test(target) || /^\/dev\/shm\//.test(target)) return true;
  // Windows: AppData/Local/Temp (case-insensitive, with or without leading slash/drive)
  if (/appdata[/\\]local[/\\]temp[/\\]/i.test(target)) return true;
  // Windows: C:\tmp\ or C:/tmp/
  if (/^[a-zA-Z]:[/\\]tmp[/\\]/i.test(target)) return true;
  // Windows: \Windows\Temp\ or /Windows/Temp/
  if (/[/\\]windows[/\\]temp[/\\]/i.test(target)) return true;
  return false;
}

module.exports = { parse, isOsTempPath };
