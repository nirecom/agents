"use strict";
// detectCaptureEcho(ir) — recognises "capture a command substitution into a
// variable, then do nothing but display that variable verbatim".
// FAIL-OPEN by design: a parse failure returns null (do not reject). This hook is
// an issuance-discipline UX guard, not a security boundary, so it deliberately
// diverges from hooks/enforce-worktree's Bash fail-CLOSED philosophy.
// Why rejecting is safe: for every shape matched below, reissuing the inner
// command bare and reading its stdout yields the identical information —
// decorative labels ("PLANS_DIR=") are for the reader, not the shell.

const { ASSIGN_RE, commandBasename } = require("../lib/bash-write-patterns/segment-utils");
const { resolveEffectiveSegment } = require("../lib/command-ir");
const { segHasHereInput } = require("../lib/bash-write-targets/here.js");

const DECL_KEYWORDS = new Set(["export", "declare", "local", "typeset", "readonly"]);
const ALLOWED_SEPARATORS = new Set([";", "&&"]);
const NAME_RE = /^([A-Za-z_][A-Za-z0-9_]*)=/;

function rawArgvOf(seg) {
  const argv = Array.isArray(seg && seg.argv) ? seg.argv : [];
  return seg && Array.isArray(seg.argvRaw) && seg.argvRaw.length === argv.length ? seg.argvRaw : argv;
}

// The assigned value must itself be a command substitution: `X=5` captures
// nothing, so displaying it is not a reissuable shape.
function isSubstitutionValue(value) {
  return /^\$\(/.test(value) || /^"\$\(/.test(value) || /^`/.test(value) || /^"`/.test(value);
}

// The text between `$(` and its matching `)`, or inside backticks. Returns "" when
// the value is not a shape this module recognises.
function extractInner(value) {
  const body = value.startsWith('"') ? value.slice(1) : value;
  if (body.startsWith("$(")) {
    let depth = 1;
    for (let i = 2; i < body.length; i++) {
      if (body[i] === "(") depth++;
      else if (body[i] === ")") {
        depth--;
        if (depth === 0) return body.slice(2, i);
      }
    }
    return "";
  }
  if (body.startsWith("`")) {
    const end = body.indexOf("`", 1);
    return end === -1 ? "" : body.slice(1, end);
  }
  return "";
}

// One raw assignment token (`NAME=<value>`) -> {name, value}, or null.
function parseAssignRaw(raw) {
  if (typeof raw !== "string") return null;
  const m = NAME_RE.exec(raw);
  if (!m) return null;
  return { name: m[1], value: raw.slice(m[0].length) };
}

// Raw assignment tokens carried by an "assignment segment", or null when the
// segment is not one: (a) a pure `NAME=value` segment, or (b) a declaration
// keyword whose every argument is an assignment.
function assignRawsOf(seg) {
  if (!seg || typeof seg.cmd0 !== "string" || seg.cmd0 === "") return null;
  const argv = Array.isArray(seg.argv) ? seg.argv : [];
  if (ASSIGN_RE.test(seg.cmd0)) {
    return argv.length === 0 ? [seg.cmd0Raw || seg.cmd0] : null;
  }
  if (DECL_KEYWORDS.has(commandBasename(seg.cmd0)) && argv.length > 0 && argv.every((a) => ASSIGN_RE.test(a))) {
    return rawArgvOf(seg).slice();
  }
  return null;
}

// Raw assignment tokens -> {names, inner}, or null when any value is not a
// command substitution (one non-capturing assignment disqualifies the whole run).
function resolveAssignments(raws) {
  const names = [];
  let inner = null;
  for (const raw of raws) {
    const parsed = parseAssignRaw(raw);
    if (!parsed || !isSubstitutionValue(parsed.value)) return null;
    names.push(parsed.name);
    if (inner === null) inner = extractInner(parsed.value);
  }
  return names.length === 0 ? null : { names, inner: inner === null ? "" : inner };
}

// An argument that does not start with a single quote and whose ONLY expansions
// are bare `$X` / `${X}` references to assigned variables. At least one such
// reference is required — `echo hello` displays no captured value.
function isDisplayOnlyArg(raw, names) {
  if (typeof raw !== "string" || raw.startsWith("'")) return false;
  let count = 0;
  for (let i = 0; i < raw.length; i++) {
    const ch = raw[i];
    if (ch === "`") return false;
    if (ch !== "$") continue;
    const rest = raw.slice(i + 1);
    const braced = /^\{([A-Za-z_][A-Za-z0-9_]*)\}/.exec(rest);
    if (braced) {
      if (!names.includes(braced[1])) return false;
      count++;
      i += braced[0].length;
      continue;
    }
    const bare = /^[A-Za-z_][A-Za-z0-9_]*/.exec(rest);
    if (!bare || !names.includes(bare[0])) return false;
    count++;
    i += bare[0].length;
  }
  return count > 0;
}

// A "value-reference token": quoting stripped, the body is EXACTLY `$X` or `${X}`
// for an assigned X. Surrounding literal text disqualifies it — printf pairs one
// conversion with one whole argument.
function isValueRefToken(raw, names) {
  if (typeof raw !== "string" || raw.startsWith("'")) return false;
  let body = raw;
  if (body.length >= 2 && body.startsWith('"') && body.endsWith('"')) body = body.slice(1, -1);
  const m = /^\$([A-Za-z_][A-Za-z0-9_]*)$/.exec(body) || /^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$/.exec(body);
  return m !== null && names.includes(m[1]);
}

function stripQuotes(raw) {
  if (typeof raw !== "string") return null;
  if (raw.length >= 2 && ((raw.startsWith("'") && raw.endsWith("'")) || (raw.startsWith('"') && raw.endsWith('"')))) {
    return raw.slice(1, -1);
  }
  return raw;
}

// Count `%s` conversions in a printf format, or null when the format does
// anything else: any other conversion, a flag/width/precision, an escape beyond
// \n \t \\, or a variable expansion — each of those transforms the value.
function countFormatSpecs(fmt) {
  let n = 0;
  for (let i = 0; i < fmt.length; i++) {
    const c = fmt[i];
    if (c === "$" || c === "`") return null;
    if (c === "\\") {
      const nx = fmt[i + 1];
      if (nx !== "n" && nx !== "t" && nx !== "\\") return null;
      i++;
      continue;
    }
    if (c === "%") {
      const nx = fmt[i + 1];
      if (nx === "%") { i++; continue; }
      if (nx !== "s") return null;
      n++;
      i++;
    }
  }
  return n;
}

// `-n` only suppresses the trailing newline; `-e` would interpret escapes, so it
// is not a display-only flag and falls through as an extra argument.
function checkEcho(argvRaw, names) {
  const args = argvRaw.length > 0 && argvRaw[0] === "-n" ? argvRaw.slice(1) : argvRaw;
  if (args.length !== 1) return false;
  return isDisplayOnlyArg(args[0], names);
}

function checkPrintf(argvRaw, names) {
  if (argvRaw.length === 0) return false;
  const fmt = stripQuotes(argvRaw[0]);
  if (fmt === null) return false;
  const n = countFormatSpecs(fmt);
  if (n === null || n < 1) return false;
  const args = argvRaw.slice(1);
  return args.length === n && args.every((a) => isValueRefToken(a, names));
}

// RAW OWNERSHIP: never judge here-input from outSeg.rawText — under Reading I it
// spans the assignment too, so a here-doc INSIDE the captured substitution would
// be misread as an output-side here-input. Reconstruct the output segment's own
// raw text from its cmd0Raw/argvRaw instead.
function isDisplayOnlyOutput(outSeg, names) {
  if (!outSeg || typeof outSeg.cmd0 !== "string") return false;
  const base = commandBasename(outSeg.cmd0);
  if (base !== "echo" && base !== "printf") return false;
  if (!Array.isArray(outSeg.redirects) || outSeg.redirects.length !== 0) return false;
  const argvRaw = rawArgvOf(outSeg);
  const outRaw = [outSeg.cmd0Raw || outSeg.cmd0].concat(argvRaw).join(" ");
  if (segHasHereInput({ ...outSeg, rawText: outRaw })) return false;
  return base === "echo" ? checkEcho(argvRaw, names) : checkPrintf(argvRaw, names);
}

// Reading S: `A=$(x); B=$(y); echo "$A$B"` — a leading run of assignment segments
// followed by EXACTLY one output segment.
function readingS(ir) {
  const segs = ir.segments;
  const raws = [];
  let i = 0;
  while (i < segs.length) {
    const found = assignRawsOf(segs[i]);
    if (!found) break;
    raws.push(...found);
    i++;
  }
  if (raws.length === 0 || segs.length - i !== 1) return null;
  return { raws, outSeg: segs[i] };
}

// Reading I: one segment, `A=$(x) echo "$A"`. IR-identical to the newline-joined
// form, and both are deliberately rejected — the true env-prefix prints the STALE
// pre-assignment value (a bug), the newline form is redundant; neither should be
// issued, so no distinction is needed. Redirects written on the assignment side
// can land in outSeg.redirects here; that contamination only pushes toward "do not
// reject", so it needs no separation.
function readingI(ir) {
  if (ir.segments.length !== 1) return null;
  const seg = ir.segments[0];
  if (typeof seg.cmd0 !== "string" || !ASSIGN_RE.test(seg.cmd0)) return null;
  const argv = Array.isArray(seg.argv) ? seg.argv : [];
  if (argv.length === 0) return null;
  const outSeg = resolveEffectiveSegment(seg);
  if (!outSeg) return null;
  const argvRaw = rawArgvOf(seg);
  const raws = [seg.cmd0Raw || seg.cmd0];
  for (let k = 0; k < argv.length; k++) {
    if (!ASSIGN_RE.test(argv[k])) break;
    raws.push(argvRaw[k]);
  }
  return { raws, outSeg };
}

function detectCaptureEcho(ir) {
  if (!ir || ir.parseFailure === true) return null;
  if (ir.kind === "empty") return null;
  if (!Array.isArray(ir.segments) || ir.segments.length === 0) return null;
  const seps = Array.isArray(ir.separators) ? ir.separators : [];
  if (!seps.every((s) => ALLOWED_SEPARATORS.has(s))) return null;

  const split = readingS(ir) || readingI(ir);
  if (!split) return null;

  const assigned = resolveAssignments(split.raws);
  if (!assigned) return null;
  if (!isDisplayOnlyOutput(split.outSeg, assigned.names)) return null;

  return { varNames: assigned.names, innerCommandText: assigned.inner };
}

module.exports = { detectCaptureEcho };
