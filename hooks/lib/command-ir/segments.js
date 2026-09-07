"use strict";
// hooks/lib/command-ir/segments.js — SegmentIR construction and raw/value sync.
//
// INVARIANT (argv/argvRaw positional correspondence): argvRaw.length === argv.length
// and argvRaw[i] is the RAW (quote-preserving) spelling of argv[i]; cmd0Raw likewise.
// Any transform that shifts tokens off the front of argv MUST shift argvRaw by the
// same count via syncRaw(). Consumers index the two against each other — see
// docs/architecture/claude-code/shell-command-parsing.md for the consumer list.

const { tokenizeSegmentWithQuotes, REDIRECT_RE, ATTACHED_REDIRECT_RE } = require("../command-parser");

// File descriptor of a redirect operator: "1" for `>`/`1>`, "2" for `2>`, "&" for `&>`.
function extractFd(op) {
  if (op.length > 0 && /^\d/.test(op)) return op[0];
  if (op.startsWith("&")) return "&";
  return "1";
}

// Build a SegmentIR { cmd0, cmd0Raw, argv, argvRaw, redirects, kind, rawText, sub }.
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

  // targetRaw is NON-ENUMERABLE so JSON.stringify(redirects) stays byte-identical
  // to the pre-migration {op,fd,target} shape while the raw spelling stays readable.
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
      const target = attachedMatch[1];
      const op = tok.slice(0, tok.length - target.length);
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

/**
 * Recompute {cmd0Raw, argvRaw} after `shiftCount` tokens were shifted off argv.
 * Guards before it indexes: this module backs security hooks, so a desynced or
 * missing argvRaw degrades to a copy of argv rather than throwing them OPEN.
 */
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

module.exports = { extractFd, buildSegmentIR, syncRaw };
