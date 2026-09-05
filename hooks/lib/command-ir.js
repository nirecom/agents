"use strict";
// command-ir.js — Bash command Intermediate Representation (IR).
//
// parse(cmd) → IR: tokenises a raw command string once into a structured object
// {segments, cmd0, argv, redirects, kind, rawText, parseFailure} that classify()
// and other callers can query without re-parsing. parseFailure===true forces "write"
// (fail-closed). isOsTempPath(target) is the SSOT predicate for OS temp-path detection.

const { tokenizeSegment, tokenizeSegmentWithQuotes, splitSegmentsWithSeparators, REDIRECT_RE, ATTACHED_REDIRECT_RE } = require("./command-parser");
const { hasUnclosedQuoteSpan } = require("./quote-spans");
const { ASSIGN_RE } = require("./bash-write-patterns/segment-utils");

// Extract the file descriptor string from a redirect operator.
// Returns "1" for plain >, "1" for 1>, "2" for 2>, "&" for &>, etc.
function extractFd(op) {
  if (op.length > 0 && /^\d/.test(op)) return op[0];
  if (op.startsWith("&")) return "&";
  return "1";
}

// Build a SegmentIR from a segment string.
// { cmd0, argv, redirects, kind, rawText, sub }
// sub is set to true when this segment lives inside a subshell.
function buildSegmentIR(segStr, isSubshell, opts) {
  let richTokens;
  try {
    richTokens = tokenizeSegmentWithQuotes(segStr, opts);
  } catch (e) {
    const seg = { cmd0: "", cmd0Raw: "", argv: [], argvRaw: [], redirects: [], kind: "simple", rawText: segStr };
    if (isSubshell) seg.sub = true;
    return seg;
  }

  const argv = [];
  const argvRaw = [];
  const redirects = [];
  let i = 0;

  // Push a redirect record. targetRaw is defined NON-ENUMERABLE so that
  // JSON.stringify(redirects) stays byte-identical to the pre-migration shape
  // ({op,fd,target}) — the additive raw field is still readable via r.targetRaw
  // and ("targetRaw" in r) but does not perturb any redirects-snapshot pins.
  const pushRedirect = (op, target, targetRaw) => {
    const r = { op, fd: extractFd(op), target };
    Object.defineProperty(r, "targetRaw", { value: targetRaw, enumerable: false, writable: true, configurable: true });
    redirects.push(r);
  };

  while (i < richTokens.length) {
    const tok = richTokens[i].value;
    if (REDIRECT_RE.test(tok)) {
      const op = tok;
      const target = i + 1 < richTokens.length ? richTokens[i + 1].value : "";
      const targetRaw = i + 1 < richTokens.length ? richTokens[i + 1].raw : "";
      pushRedirect(op, target, targetRaw);
      i += 2;
      continue;
    }
    const attachedMatch = ATTACHED_REDIRECT_RE.exec(tok);
    if (attachedMatch) {
      // Reconstruct the operator part (everything before the captured target)
      const target = attachedMatch[1];
      const op = tok.slice(0, tok.length - target.length);
      // Attached raw target = the raw token minus the (byte-identical) operator prefix.
      const targetRaw = richTokens[i].raw.slice(op.length);
      pushRedirect(op, target, targetRaw);
      i++;
      continue;
    }
    argv.push(tok);
    argvRaw.push(richTokens[i].raw);
    i++;
  }

  const cmd0 = argv.length > 0 ? argv.shift() : "";
  const cmd0Raw = argvRaw.length > 0 ? argvRaw.shift() : "";

  const seg = { cmd0, cmd0Raw, argv, argvRaw, redirects, kind: "simple", rawText: segStr };
  if (isSubshell) seg.sub = true;
  return seg;
}

// INVARIANT: argvRaw[i] is the RAW spelling of argv[i], and cmd0Raw of cmd0, for
// every SegmentIR this module produces. Any transform shifting tokens off the
// front of argv MUST shift argvRaw by the same count — syncRaw() below. Callers
// index the two arrays against each other and depend on it.
// syncRaw(seg, shiftCount) recomputes {cmd0Raw, argvRaw} after `shiftCount`
// leading argv tokens were consumed. It guards BEFORE indexing: this module backs
// three security hooks, so a missing or out-of-sync argvRaw degrades to a copy of
// argv rather than throwing, which would fail those guards OPEN.
function syncRaw(seg, shiftCount) {
  const argv = Array.isArray(seg && seg.argv) ? seg.argv : [];
  const raw =
    seg && Array.isArray(seg.argvRaw) && seg.argvRaw.length === argv.length
      ? seg.argvRaw
      : argv.slice();
  const headIdx = shiftCount - 1;
  return {
    cmd0Raw: headIdx >= 0 && headIdx < raw.length ? raw[headIdx] : "",
    argvRaw: raw.slice(shiftCount),
  };
}

// parse(cmd, opts) → IR: {segments: SegmentIR[], cmd0, argv, redirects, kind
// ("simple"|"pipeline"|"subshell"|"empty"), rawText (ALWAYS the original cmd,
// even on parseFailure), separators (recorded at every split point, including
// leading/trailing, so its length may differ from segments.length-1 —
// intentional for fail-closed behavior), parseFailure}.
// opts.preserveSubstitutionSpans (default OFF) keeps unquoted `$(...)`, backtick,
// arithmetic and `${...}` spans intact through the split and tokenizer, so a
// target assembled inside one survives as a single token (./command-parser.js,
// ./substitution-spans.js). It is ADDITIVE — the caller merges this reading with
// the ordinary one, which scans substitution bodies as their own segments.
function parse(cmd, opts) {
  const rawText = cmd;

  try {
    if (!cmd || typeof cmd !== "string" || cmd.trim() === "") {
      return { segments: [], cmd0: "", argv: [], redirects: [], kind: "empty", rawText, separators: [], parseFailure: false };
    }

    // Fail-closed: unclosed quotes indicate malformed input
    if (hasUnclosedQuoteSpan(cmd, ["dq", "sq", "ansic"])) {
      return { segments: [], cmd0: "", argv: [], redirects: [], kind: "empty", rawText, separators: [], parseFailure: true };
    }

    const trimmed = cmd.trim();

    const isSubshell = trimmed.startsWith("(");
    const { segs: segStrings, seps } = splitSegmentsWithSeparators(cmd, opts);
    const kind = isSubshell ? "subshell" : segStrings.length > 1 ? "pipeline" : "simple";
    const segments = segStrings.map((s) => buildSegmentIR(s, isSubshell, opts));

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

// Strip env-prefix assignments (VAR=val) from the front of a segment IR, returning
// a full segmentIR rather than just the cmd0 string that segment-utils.js's
// resolveEffectiveCommand() yields. ASSIGN_RE is the shared constant owned by
// segment-utils.js (CPR-SSOT), imported at the top of this file.
// Returns null when every token is an assignment (no real command).
function stripEnvPrefix(seg) {
  if (!seg || seg.cmd0 == null) return null;
  if (!ASSIGN_RE.test(seg.cmd0)) return seg;
  if (!Array.isArray(seg.argv)) return null;
  const idx = seg.argv.findIndex((a) => !ASSIGN_RE.test(a));
  if (idx === -1) return null;
  return { ...seg, cmd0: seg.argv[idx], argv: seg.argv.slice(idx + 1), ...syncRaw(seg, idx + 1) };
}

// resolveEffectiveSegment(segmentIR) → effective SegmentIR, or null.
// Penetrates control-structure keywords: condition headers (if/elif/while/until)
// and body keywords (do/then/else) are stripped and the remainder IS the effective
// command; non-executable headers (for/select/case) and terminators (done/fi/esac)
// yield null. Env-prefix assignments are stripped afterwards, so `FOO=1 head`
// resolves to `head`. Non-control segments pass through the env-prefix strip only.
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
    const effective = {
      ...segmentIR,
      cmd0: segmentIR.argv[0],
      argv: segmentIR.argv.slice(1),
      ...syncRaw(segmentIR, 1)
    };
    // Compose with env-prefix stripping
    return stripEnvPrefix(effective);
  }

  // Non-control command: apply env-assignment stripping directly
  return stripEnvPrefix(segmentIR);
}

module.exports = { parse, isOsTempPath, resolveEffectiveSegment };
