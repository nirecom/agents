// hooks/block-clearance-token-write/nested-bodies.js
// Extract, from a parsed segment, every string the shell will execute as
// COMMAND TEXT so ./bash-scan.js can recurse the scanner over it. `eval` (no
// flag) and here-strings (`sh <<< "..."`) both turn a plain argument into a
// command line without tripping the flag-based interpreter gate in
// ./interpreter-scan.js. Recursing the full scanner here is more general than
// enumerating `eval`-like names: it reuses every redirect/argv/assignment/glob
// rule at once (CPR-E2C/CPR-UNV).
"use strict";

const path = require("path");
const { resolveEffectiveSegment } = require("../lib/command-ir");
const { interpreterKindOfWord, inlineProgramFlagProof } = require("./interpreter-scan");

// Wrappers that only prefix a real command and pass the rest through, so
// `command eval …` / `builtin eval …` must not launder the eval away.
const COMMAND_WRAPPERS = new Set(["command", "builtin", "exec", "nohup", "time"]);

function baseName(word) {
  if (typeof word !== "string" || word === "") return "";
  return path.basename(word.replace(/\\/g, "/")).toLowerCase();
}

// evalBodyOf(seg): the command text `eval` will execute, or null.
// `eval` concatenates its arguments with a space and re-parses the result, so
// joining argv is the faithful model — and it also means a body split across
// several words (`eval echo x '>' s1.<marker>`) is reassembled here.
function evalBodyOf(seg) {
  const eff = resolveEffectiveSegment(seg);
  if (!eff || typeof eff.cmd0 !== "string") return null;
  let name = baseName(eff.cmd0);
  const argv = (Array.isArray(eff.argv) ? eff.argv : []).slice();
  while (COMMAND_WRAPPERS.has(name) && argv.length > 0) name = baseName(argv.shift());
  if (name !== "eval") return null;
  const body = argv.join(" ").trim();
  return body === "" ? null : body;
}

function hereStringRedirects(seg) {
  return ((seg && seg.redirects) || []).filter((r) => r && r.op === "<<<");
}

// hereStringBodiesOf(seg): every `<<<` target on the segment, RAW (outer quotes
// preserved) — the form the shell scanner wants, since it re-tokenizes.
// A here-string is stdin, so it is command text only when the reader executes
// it — which is exactly what `sh <<< …`, `xargs … <<< …` and friends do. Rather
// than enumerating readers (an enumeration that always lags — CPR-UNV), the text
// is scanned unconditionally: a here-string spelling a protected path is not a
// shape any legitimate command in this repo needs.
function hereStringBodiesOf(seg) {
  const out = [];
  for (const r of hereStringRedirects(seg)) {
    const raw = typeof r.targetRaw === "string" && r.targetRaw !== "" ? r.targetRaw : r.target;
    if (typeof raw === "string" && raw.trim() !== "") out.push(raw);
  }
  return out;
}

// hereStringValuesOf(seg): the same targets QUOTE-STRIPPED — the form an
// interpreter actually receives on stdin, and therefore the only form the
// anchored read-only body shapes in ./interpreter-scan.js can match. Feeding
// them the raw `"…"` spelling would fail every `^…$` shape and fail-closed
// block `node <<< "console.log(fs.readFileSync(…))"`, which its `-e` sibling
// approves (CPR-ORTH symmetry).
function hereStringValuesOf(seg) {
  const out = [];
  for (const r of hereStringRedirects(seg)) {
    const v = typeof r.target === "string" ? r.target : "";
    if (v.trim() !== "") out.push(v);
  }
  return out;
}

// nestedCommandTextsOf(seg): every string above, deduplicated.
function nestedCommandTextsOf(seg) {
  const texts = [];
  const ev = evalBodyOf(seg);
  if (ev) texts.push(ev);
  for (const hs of hereStringBodiesOf(seg)) texts.push(hs);
  return texts.filter((t, i) => texts.indexOf(t) === i);
}

// Program text delivered on STDIN. node/python/perl/ruby/deno/bun/pwsh read a
// program from stdin — the wrong grammar for shell text (`node <<< '...'` was
// invisible while `node -e` blocked). The cut is the interpreter's IDENTITY,
// not delivery syntax (`<<<`, `<<`, `|`, `<(...)` all count): a known body is
// judged in its language, an opaque body fails closed on any protected
// mention, a file operand is classified as a path.

// argvProvesInlineProgram(words, interpreterWord): a word is an inline-program
// flag FOR THIS INTERPRETER (kind-scoped) AND carries a body — attached
// (`--eval=code`) or in the next word. A bodyless flag is not proof.
function argvProvesInlineProgram(words, interpreterWord) {
  for (let i = 0; i < words.length; i++) {
    const w = words[i];
    if (!inlineProgramFlagProof(w, interpreterWord)) continue;
    if (w.indexOf("=") >= 0 || i < words.length - 1) return true;
  }
  return false;
}

// stdinProgramInterpreterOf(seg): { kind, word } for the command reading stdin,
// reported whenever the program is NOT provably on argv (stdin may be CODE, not
// data). Burden of proof is on the ALLOW side: only a positive inline-program
// flag clears it, so `node script.js <<< data` over-blocks — accepted, rare.
// `word` is carried alongside `kind` because the read-only body shapes are
// scoped to the delivering interpreter's grammar (#1821).
const NO_STDIN_INTERPRETER = { kind: null, word: null };

function stdinProgramInterpreterOf(seg) {
  const eff = resolveEffectiveSegment(seg);
  if (!eff || typeof eff.cmd0 !== "string") return NO_STDIN_INTERPRETER;
  let name = eff.cmd0;
  const argv = (Array.isArray(eff.argv) ? eff.argv : []).slice();
  while (COMMAND_WRAPPERS.has(baseName(name)) && argv.length > 0) name = argv.shift();
  const kind = interpreterKindOfWord(name);
  if (!kind) return NO_STDIN_INTERPRETER;
  return argvProvesInlineProgram(argv, name) ? NO_STDIN_INTERPRETER : { kind, word: name };
}

function stdinProgramInterpreterKind(seg) {
  return stdinProgramInterpreterOf(seg).kind;
}

// segmentOffsets(cmdText, segments): where each segment's rawText sits in the
// original command, or null when that cannot be established. Segments are
// emitted in source order and are verbatim slices, so a forward scan is exact —
// and it is the only way to recover which SEPARATOR joined two segments:
// parse()'s `separators` array is documented to record leading/trailing
// separators too, so it is deliberately not index-aligned with `segments`.
function segmentOffsets(cmdText, segments) {
  const out = [];
  let cursor = 0;
  for (const s of segments) {
    if (!s || typeof s.rawText !== "string") return null;
    const at = cmdText.indexOf(s.rawText, cursor);
    if (at < 0) return null;
    out.push({ start: at, end: at + s.rawText.length });
    cursor = at + s.rawText.length;
  }
  return out;
}

// upstreamPipelineTexts(...): the text of every segment feeding this one
// through a pipe, walking the whole pipeline back (`cat <marker> | tr -d x |
// node` must fail closed on the `cat`, not just the adjacent `tr`).
function upstreamPipelineTexts(cmdText, segments, idx, offsets) {
  const texts = [];
  for (let j = idx; j > 0; j--) {
    const gap = cmdText.slice(offsets[j - 1].end, offsets[j].start).trim();
    if (gap !== "|" && gap !== "|&") break;
    texts.push(segments[j - 1].rawText);
  }
  return texts;
}

// Heredoc: `<<WORD` / `<<-WORD` / `<<'WORD'`. The head group excludes separator
// characters so the reader word is the command actually receiving the heredoc
// (`x && node <<EOF` resolves to `node`, not `x`).
const HEREDOC_HEAD = String.raw`(?:^|[\n;&|])([^\n;&|]*?)<<-?[ \t]*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\2`;
const HEREDOC_TERMINATED_RE = new RegExp(HEREDOC_HEAD + String.raw`[^\n]*\n([\s\S]*?)\n[ \t]*\3[ \t]*(?:\n|$)`, "g");
const HEREDOC_OPENER_RE = new RegExp(HEREDOC_HEAD, "g");

const ASSIGN_WORD_RE = /^[A-Za-z_][A-Za-z0-9_]*=/;

// readerKindOfHead(head): the interpreter kind of the command a heredoc feeds,
// under the SAME burden of proof stdinProgramInterpreterKind() applies to the
// other routes (CPR-ORTH) — the kind is reported unless an inline-program flag
// proves the program is on argv, so `node -e '…' <<EOF` treats the heredoc as
// data while `node script.js <<EOF` does not.
function readerInterpreterOfHead(head) {
  const words = String(head || "").trim().split(/\s+/).filter(Boolean);
  let i = 0;
  while (i < words.length && ASSIGN_WORD_RE.test(words[i])) i++;
  while (i < words.length && COMMAND_WRAPPERS.has(baseName(words[i]))) i++;
  if (i >= words.length) return NO_STDIN_INTERPRETER;
  const kind = interpreterKindOfWord(words[i]);
  if (!kind) return NO_STDIN_INTERPRETER;
  return argvProvesInlineProgram(words.slice(i + 1), words[i])
    ? NO_STDIN_INTERPRETER
    : { kind, word: words[i] };
}

function readerKindOfHead(head) {
  return readerInterpreterOfHead(head).kind;
}

// stdinProgramRoutes(cmdText, segments) ->
//   { bodies: [{body, gateText, lang}], fileTargets: [string], opaqueTexts: [string] }
// The caller judges each list with the matching classifier: `bodies` in the
// interpreter's own language, `fileTargets` as paths, `opaqueTexts` by
// protected-name mention alone.
function stdinProgramRoutes(cmdText, segments) {
  const bodies = [];
  const fileTargets = [];
  const opaqueTexts = [];
  const text = typeof cmdText === "string" ? cmdText : "";
  const segs = Array.isArray(segments) ? segments : [];
  const offsets = segmentOffsets(text, segs);

  for (let idx = 0; idx < segs.length; idx++) {
    const seg = segs[idx];
    const { kind, word } = stdinProgramInterpreterOf(seg);
    if (!kind) continue;
    // A shell's here-string is already recursed as shell text by
    // nestedCommandTextsOf; only a LANGUAGE interpreter needs the second,
    // language-aware reading of the same body.
    if (kind === "language") {
      for (const v of hereStringValuesOf(seg)) {
        bodies.push({ body: v, gateText: seg.rawText, lang: word });
      }
    }
    for (const r of (seg && seg.redirects) || []) {
      if (!r || r.op !== "<") continue;
      const rawTarget = typeof r.targetRaw === "string" && r.targetRaw !== "" ? r.targetRaw : r.target;
      const t = typeof rawTarget === "string" ? rawTarget.trim() : "";
      // `<<WORD` reaches buildSegmentIR as an attached `<` whose target starts
      // with `<`; the heredoc pass below owns that shape.
      if (t.charAt(0) === "<") continue;
      // Empty target = the source was split off by the tokenizer, which is what
      // a process substitution `<(…)` looks like from here: the program exists
      // but not in this segment. Unresolvable -> fail closed on mention.
      if (t === "") opaqueTexts.push(text);
      else fileTargets.push(t);
    }
    if (idx > 0) {
      if (offsets) for (const u of upstreamPipelineTexts(text, segs, idx, offsets)) opaqueTexts.push(u);
      else opaqueTexts.push(text); // cannot locate the segments -> cannot clear them
    }
  }

  let terminated = 0;
  let m;
  HEREDOC_TERMINATED_RE.lastIndex = 0;
  while ((m = HEREDOC_TERMINATED_RE.exec(text)) !== null) {
    terminated++;
    const reader = readerInterpreterOfHead(m[1]);
    if (reader.kind !== "language") continue;
    bodies.push({ body: m[4], gateText: m[1] + "\n" + m[4], lang: reader.word });
  }
  // An UNTERMINATED heredoc yields no body but still delivers one at runtime —
  // the same "more invocations than extractable bodies" mismatch that
  // extractAllInterpreterBodies() fail-closes on (CPR-ORTH).
  let openers = 0;
  let interpreterOpener = false;
  HEREDOC_OPENER_RE.lastIndex = 0;
  while ((m = HEREDOC_OPENER_RE.exec(text)) !== null) {
    openers++;
    if (readerKindOfHead(m[1])) interpreterOpener = true;
  }
  if (openers > terminated && interpreterOpener) opaqueTexts.push(text);

  return { bodies, fileTargets, opaqueTexts };
}

module.exports = {
  evalBodyOf,
  hereStringBodiesOf,
  hereStringValuesOf,
  nestedCommandTextsOf,
  stdinProgramInterpreterKind,
  stdinProgramInterpreterOf,
  stdinProgramRoutes,
};
