"use strict";

// A gh write does not have to appear at the top level of the command line: it
// can sit inside `bash -c '...'`, inside `eval`, inside a here-string fed to a
// shell, or inside a command substitution. This module answers ONE question for
// each of those shapes — can the guard read the executed text well enough to
// attribute a forge target to it? A body it can read re-enters the scan; a body
// it cannot read is not "probably fine", it is unresolved, and the caller turns
// that into an ask. Nothing here executes, dequotes by shelling out, or reads a
// file: every answer comes from the already-parsed IR and the quote spans.
const { scanSpans, foldNewlinesInSpans, spanAwareNewlineSplit } = require("../lib/quote-spans");
const { parse } = require("../lib/command-ir");
const { stripHeredocBody } = require("../lib/strip-quoted-args");
const { extractSubstitutionContents } = require("../lib/command-parser");
const { commandBasename, WRAPPER_SPECS } = require("../lib/bash-write-patterns/segment-utils");
const { interpreterKindOfWord, inlineProgramFlagProof } = require("../block-clearance-token-write/interpreter-scan");
const { evalBodyOf, stdinProgramInterpreterKind } = require("../block-clearance-token-write/nested-bodies");
const { MAX_NESTED_SCAN_DEPTH } = require("../block-clearance-token-write/bash-scan/scan");

const LITERAL_QUOTE_KINDS = ["dq", "sq", "ansic"];

// Deliberately generous: it gates REASONS that would otherwise fire on ordinary
// unrelated commands, so a false positive costs a prompt and a false negative
// costs a silent cross-repo write. `gh` plus `api`, or `gh` plus both `issue`
// and `create`, anywhere in the raw text — a commit message that talks about
// `gh issue create` matches on purpose (M-7c).
function mentionsForgeWrite(text) {
  if (typeof text !== "string" || text === "") return false;
  if (!/\bgh\b/.test(text)) return false;
  if (/\bapi\b/.test(text)) return true;
  return /\bissue\b/.test(text) && /\bcreate\b/.test(text);
}

function spansOf(text) {
  try {
    return scanSpans(text);
  } catch (_e) {
    return { spans: [], ok: false };
  }
}

// A here-string is stdin, and stdin is a PROGRAM when the receiver executes it.
// `sh <<< $CMD` runs text the guard cannot see; `jq . <<< "$json"` does not.
function hereStringProgramUnreadable(seg) {
  const redirects = Array.isArray(seg && seg.redirects) ? seg.redirects : [];
  const here = redirects.filter((r) => r && r.op === "<<<");
  if (here.length === 0) return false;
  if (!stdinProgramInterpreterKind(seg)) return false;
  return here.some((r) => dequoteWholeToken(typeof r.targetRaw === "string" ? r.targetRaw : r.target) === null);
}

// Fold, split and sanity-check a command payload into single-line commands.
// `lines` is always the best available split — a stage may set `ok:false` while
// the text it produced is still the right thing for the caller to log.
function normalizeToLines(cmd) {
  if (typeof cmd !== "string") return { ok: false, lines: [], reason: "unmodeled-body-quoting" };
  const stripped = stripHeredocBody(cmd);
  let reason = null;
  const scan = spansOf(stripped);
  if (!scan.ok) reason = "unmodeled-body-quoting";
  if (reason === null) {
    for (const sp of scan.spans) {
      if (LITERAL_QUOTE_KINDS.indexOf(sp.kind) === -1) continue;
      const inner = stripped.slice(sp.innerStart, sp.innerEnd);
      if (/[\r\n]/.test(inner) && mentionsForgeWrite(stripped)) { reason = "quoted-newline-in-body"; break; }
    }
  }
  const folded = foldNewlinesInSpans(stripped, LITERAL_QUOTE_KINDS);
  const text = (folded.ok ? folded.out : stripped).replace(/\\[ \t]*\r?\n/g, " ");
  if (!folded.ok && reason === null) reason = "unmodeled-body-quoting";
  const split = spanAwareNewlineSplit(text);
  const lines = split.lines && split.lines.length ? split.lines : (text.trim() === "" ? [] : [text.trim()]);
  if (!split.ok && reason === null) reason = "unmodeled-body-quoting";
  if (reason === null) {
    for (const line of lines) {
      let ir = null;
      try { ir = parse(line); } catch (_e) { ir = null; }
      if (!ir || ir.parseFailure) { reason = "unmodeled-body-quoting"; break; }
      if ((ir.segments || []).some(hereStringProgramUnreadable)) { reason = "unmodeled-body-quoting"; break; }
    }
  }
  return { ok: reason === null, lines, reason: reason || undefined };
}

// The dequoted content of a token that is EXACTLY one closed literal quote span,
// or null. A double-quoted span carrying `$`, a backtick or a backslash is not
// literal — the shell would rewrite it before the interpreter ever saw it.
function dequoteWholeToken(rawTok) {
  if (typeof rawTok !== "string" || rawTok.length < 2) return null;
  const scan = spansOf(rawTok);
  if (!scan.ok) return null;
  for (const sp of scan.spans) {
    if (sp.start !== 0 || sp.end !== rawTok.length || !sp.closed) continue;
    const inner = rawTok.slice(sp.innerStart, sp.innerEnd);
    if (sp.kind === "sq") return inner;
    if (sp.kind === "dq") return /[$`\\]/.test(inner) ? null : inner;
    return null;
  }
  return null;
}

function unresolved(reason) {
  return { kind: "unresolved", reason };
}

function inlineProgramCandidate(seg) {
  const argv = Array.isArray(seg.argv) ? seg.argv : [];
  const argvRaw = Array.isArray(seg.argvRaw) ? seg.argvRaw : argv;
  const name = commandBasename(seg.cmd0);
  const kind = interpreterKindOfWord(name);
  if (!kind) return null;
  for (let i = 0; i < argv.length; i++) {
    if (!inlineProgramFlagProof(argv[i], name)) continue;
    if (i + 1 >= argv.length) return { kind, raw: null };
    return { kind, raw: typeof argvRaw[i + 1] === "string" ? argvRaw[i + 1] : argv[i + 1] };
  }
  return null;
}

function hereStringCandidate(seg) {
  const kind = stdinProgramInterpreterKind(seg);
  if (!kind) return null;
  const redirects = Array.isArray(seg.redirects) ? seg.redirects : [];
  for (const r of redirects) {
    if (!r || r.op !== "<<<") continue;
    return { kind, raw: typeof r.targetRaw === "string" ? r.targetRaw : r.target };
  }
  return null;
}

function evalCandidate(seg) {
  let body = null;
  try { body = evalBodyOf(seg); } catch (_e) { body = null; }
  if (typeof body !== "string" || body.trim() === "") return null;
  const argvRaw = Array.isArray(seg.argvRaw) ? seg.argvRaw : [];
  const raw = argvRaw.length === 1 ? argvRaw[0] : null;
  return { kind: "shell", raw, eval: true };
}

function bodyCandidateOf(seg) {
  return inlineProgramCandidate(seg) || evalCandidate(seg) || hereStringCandidate(seg);
}

// Does this segment hide its executed body behind a wrapper whose own options
// the guard only models heuristically? `nice bash -c '...'` is such a shape: the
// interpreter is real but the peel that found it is not proof.
function wrapperHidesInterpreter(seg) {
  const head = commandBasename(seg && seg.cmd0);
  if (!head || !WRAPPER_SPECS[head]) return false;
  const argv = Array.isArray(seg.argv) ? seg.argv : [];
  return argv.some((tok) => interpreterKindOfWord(commandBasename(tok)));
}

// How many further interpreter levels a raw body text spells out. Quote and
// backslash characters are separators here because the escaping is exactly what
// made the body unreadable; the interpreter vocabulary itself stays shared.
function inlineNestingLevels(text) {
  if (typeof text !== "string" || text === "") return 0;
  let n = 0;
  for (const tok of text.split(/[\s"'\\`]+/)) {
    if (tok && interpreterKindOfWord(commandBasename(tok))) n += 1;
  }
  return n;
}

// The single verdict on one segment's nested body: none / resolved / unresolved.
function nestedBodyOf(seg, depth) {
  if (!seg || typeof seg !== "object") return { kind: "none" };
  const d = typeof depth === "number" && depth > 0 ? depth : 0;
  const raws = typeof seg.rawText === "string" ? seg.rawText : "";
  const mentions = mentionsForgeWrite(raws);
  if (wrapperHidesInterpreter(seg)) return mentions ? unresolved("wrapper-peeled-body") : { kind: "none" };
  const cand = bodyCandidateOf(seg);
  if (!cand) return { kind: "none" };
  if (cand.kind === "language") return mentions ? unresolved("language-interpreter-body") : { kind: "none" };
  if (d + 1 > MAX_NESTED_SCAN_DEPTH) return unresolved("depth-cap");
  if (typeof cand.raw !== "string" || cand.raw === "") return unresolved("body-missing");
  const body = dequoteWholeToken(cand.raw);
  if (body === null) {
    // An unreadable body whose own text already spells out more interpreter
    // levels than the cap allows is capped, not merely unquotable: descending
    // would have stopped at the cap anyway, so the cap is the honest reason.
    return d + 1 + inlineNestingLevels(cand.raw) > MAX_NESTED_SCAN_DEPTH
      ? unresolved("depth-cap")
      : unresolved("unmodeled-body-quoting");
  }
  if (body.trim() === "") return unresolved("body-missing");
  let ir = null;
  try { ir = parse(body); } catch (_e) { ir = null; }
  const single = ir && !ir.parseFailure && Array.isArray(ir.segments) && ir.segments.length === 1
    && (!Array.isArray(ir.separators) || ir.separators.length === 0) && !/[\r\n]/.test(body);
  if (!single) {
    return (mentions || mentionsForgeWrite(body)) ? unresolved("multi-command-body") : { kind: "none" };
  }
  return { kind: "resolved", body };
}

// Command substitutions are counted, not just extracted: `extractSubstitutionContents`
// reads the INNERMOST body of a nest, so a line whose opener count exceeds its
// body count is carrying text the guard never saw. Contents of single-quoted and
// ANSI-C spans are blanked first, because a `$(` in there opens nothing.
function substitutionBodiesOf(line) {
  const result = { openers: 0, bodies: [] };
  if (typeof line !== "string" || line === "") return result;
  const scan = spansOf(line);
  let masked = line;
  if (scan.ok) {
    for (const sp of scan.spans) {
      if (sp.kind === "cmdsubst" || sp.kind === "backtick") result.openers += 1;
    }
    for (const sp of scan.spans) {
      if (sp.kind !== "sq" && sp.kind !== "ansic") continue;
      const width = sp.innerEnd - sp.innerStart;
      if (width <= 0) continue;
      masked = masked.slice(0, sp.innerStart) + " ".repeat(width) + masked.slice(sp.innerEnd);
    }
  } else {
    result.openers = (line.match(/\$\(|`/g) || []).length;
  }
  try {
    result.bodies = extractSubstitutionContents(masked) || [];
  } catch (_e) {
    result.bodies = [];
  }
  return result;
}

function hasAnsicSpan(text) {
  if (typeof text !== "string" || text.indexOf("$'") === -1) return false;
  const scan = spansOf(text);
  if (!scan.ok) return true;
  return scan.spans.some((sp) => sp.kind === "ansic");
}

module.exports = {
  normalizeToLines,
  nestedBodyOf,
  mentionsForgeWrite,
  substitutionBodiesOf,
  dequoteWholeToken,
  hasAnsicSpan,
  MAX_NESTED_SCAN_DEPTH,
};
