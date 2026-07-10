"use strict";
// command-ir.js — Bash command Intermediate Representation (IR).
//
// parse(cmd) → IR: tokenises a raw command string once into a structured object
// {segments, cmd0, argv, redirects, kind, rawText, parseFailure} that classify()
// and other callers can query without re-parsing. parseFailure===true forces "write"
// (fail-closed). isOsTempPath(target) is the SSOT predicate for OS temp-path detection.

const { tokenizeSegment, splitSegmentsWithSeparators, REDIRECT_RE, ATTACHED_REDIRECT_RE } = require("./command-parser");

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
 *   separators: string[],    // separator tokens between segments; recorded
 *                            //   unconditionally at each split point (leading/
 *                            //   trailing separators also recorded). May differ
 *                            //   in length from segments.length - 1 (intentional
 *                            //   for fail-closed behavior).
 *   parseFailure: boolean    // true when tokenization throws
 * }
 *
 * rawText is always set before any processing begins.
 */
function parse(cmd) {
  const rawText = cmd;

  try {
    if (!cmd || typeof cmd !== "string" || cmd.trim() === "") {
      return { segments: [], cmd0: "", argv: [], redirects: [], kind: "empty", rawText, separators: [], parseFailure: false };
    }

    // Fail-closed: unclosed quotes indicate malformed input
    if (hasUnclosedQuote(cmd)) {
      return { segments: [], cmd0: "", argv: [], redirects: [], kind: "empty", rawText, separators: [], parseFailure: true };
    }

    const trimmed = cmd.trim();

    const isSubshell = trimmed.startsWith("(");
    const { segs: segStrings, seps } = splitSegmentsWithSeparators(cmd);
    const kind = isSubshell ? "subshell" : segStrings.length > 1 ? "pipeline" : "simple";
    const segments = segStrings.map((s) => buildSegmentIR(s, isSubshell));

    // Top-level IR comes from first segment
    const first = segments.length > 0 ? segments[0] : { cmd0: "", argv: [], redirects: [] };

    return {
      segments,
      separators: seps,
      cmd0: first.cmd0,
      argv: first.argv.slice(),
      redirects: first.redirects,
      kind,
      rawText,
      parseFailure: false,
    };
  } catch (e) {
    return { segments: [], cmd0: "", argv: [], redirects: [], kind: "empty", rawText, separators: [], parseFailure: true };
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

const CONTROL_COND_HEADERS = new Set(["if", "elif", "while", "until"]);
const CONTROL_BODY_KEYWORDS = new Set(["do", "then", "else"]);
const CONTROL_NONEXEC_HEADERS = new Set(["for", "select", "case"]);
const CONTROL_TERMINATORS = new Set(["done", "fi", "esac"]);

/**
 * Strip env-prefix assignments (VAR=val) from the front of a segment IR.
 * Mirrors resolveEffectiveCommand() from segment-utils.js but returns a
 * full segmentIR rather than just the cmd0 string.
 *
 * Returns null when every token is an assignment (no real command).
 */
function stripEnvPrefix(seg) {
  const ASSIGN_RE = /^[A-Za-z_][A-Za-z0-9_]*=/;
  if (!seg || seg.cmd0 == null) return null;
  if (!ASSIGN_RE.test(seg.cmd0)) return seg;
  if (!Array.isArray(seg.argv)) return null;
  const idx = seg.argv.findIndex((a) => !ASSIGN_RE.test(a));
  if (idx === -1) return null;
  return { ...seg, cmd0: seg.argv[idx], argv: seg.argv.slice(idx + 1) };
}

/**
 * Resolve the effective command from a segment IR, penetrating control-structure
 * keywords (for/do/done/while/until/if/then/else/elif/fi/case/esac/select).
 *
 * Three categories:
 *   - Condition headers (if, elif, while, until): strip keyword, condition argv
 *     IS the effective command (the condition runs as a real command in shell).
 *   - Body keywords (do, then, else): strip keyword, body command is effective.
 *   - Non-executable headers (for, select, case) and terminators (done, fi, esac):
 *     return null — they are not real executable commands.
 *
 * After control-keyword stripping, env-prefix assignments (VAR=val) are also
 * stripped so the caller gets the true effective cmd0 (e.g. FOO=1 head -> head).
 * Non-control segments pass through unchanged (still subject to env-prefix strip).
 *
 * @param {object} segmentIR - A SegmentIR from parse() output
 * @returns {object|null} - Effective SegmentIR, or null for headers/terminators
 */
function resolveEffectiveSegment(segmentIR) {
  if (!segmentIR || segmentIR.cmd0 == null) return null;
  const cmd0 = segmentIR.cmd0;
  if (cmd0 === "") return null;

  // Non-executable headers and terminators: skip entirely
  if (CONTROL_NONEXEC_HEADERS.has(cmd0) || CONTROL_TERMINATORS.has(cmd0)) {
    return null;
  }

  // Condition headers (if/elif/while/until) and body keywords (do/then/else):
  // strip the keyword, the remaining argv is the effective command.
  if (CONTROL_COND_HEADERS.has(cmd0) || CONTROL_BODY_KEYWORDS.has(cmd0)) {
    if (!Array.isArray(segmentIR.argv) || segmentIR.argv.length === 0) return null;
    let effective = {
      ...segmentIR,
      cmd0: segmentIR.argv[0],
      argv: segmentIR.argv.slice(1)
    };
    // Compose with env-prefix stripping
    return stripEnvPrefix(effective);
  }

  // Non-control command: apply env-assignment stripping directly
  return stripEnvPrefix(segmentIR);
}

module.exports = { parse, isOsTempPath, resolveEffectiveSegment };
