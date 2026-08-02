// hooks/block-off-clearance-write/nested-bodies.js
// Extract, from a single parsed segment, every string the shell will go on to
// execute AS COMMAND TEXT — so ./bash-scan.js can recurse the whole scanner
// over it instead of leaving it as inert argv.
//
// #1780 round-5 HIGH-3 / MEDIUM-5. Two constructs make a plain argument (or a
// redirect target) become a command line, and neither reaches the interpreter
// gate in ./interpreter-scan.js, because that gate keys on an explicit
// `-c` / `-e` / `-Command` FLAG:
//
//   eval 'echo {} > s1.<marker>'     — `eval` takes no flag at all
//   sh <<< "echo x > s1.<marker>"    — the body arrives as a here-string, and
//   xargs -I{} sh -c '…' <<< s1.<marker>   the `-c` body is a harmless literal
//
// Both are handled here by returning the text and letting the CALLER re-run the
// full scan on it (depth-capped). That is deliberately more general than adding
// `eval` to the interpreter-name list would be: recursion reuses every redirect,
// argv, assignment and glob rule at once, so a nested construct is judged by
// exactly the same standard as a top-level one (CPR-4/CPR-8).
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
// than enumerating readers (an enumeration that always lags — CPR-8), the text
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
// approves (#1709 symmetry).
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

// ---------------------------------------------------------------------------
// Program text delivered on STDIN.
//
// #1780 round-5 follow-up. The here-string handling above routes every `<<<`
// body to the SHELL scanner, which is right only when the reader is a shell.
// `node`, `python3`, `perl`, `ruby`, `deno`, `bun` and `pwsh` all execute a
// program read from stdin too, and for them shell text is the wrong grammar:
// `node <<< 'require("fs").unlinkSync("<marker>")'` is one non-matching word to
// the shell scanner and sailed through, while the byte-identical `node -e` form
// blocked.
//
// The cut is therefore made on the RECEIVING COMMAND'S INTERPRETER IDENTITY,
// never on the delivery syntax (CPR-4/CPR-8) — otherwise closing `<<<` alone
// would leave `<<`, `|` and `<(…)` open, which is exactly how this class was
// discovered. Every route that can put program text on an interpreter's stdin
// is enumerated once, here, and classified by identity:
//
//   node <<< '…'          -> body known  -> classify in the interpreter's language
//   node <<EOF … EOF      -> body known  -> same
//   printf '…' | node     -> body OPAQUE -> fail closed if the upstream text
//                                           mentions a protected name
//   node < FILE           -> program is a file -> classify FILE as a path
//   node <(printf '…')    -> body OPAQUE -> fail closed on a protected mention
//
// The opaque cases take the same direction as the HIGH-2 parse-failure rule
// (CPR-5): "cannot analyse" means "cannot clear", not "nothing found".
// ---------------------------------------------------------------------------

// argvProvesInlineProgram(words, interpreterWord): does this word list carry an
// inline program? Two conditions, both required:
//
//   1. a word is an inline-program flag FOR THIS INTERPRETER — kind-scoped, so
//      a pwsh parameter name cannot clear `python3 -En -` (round 8);
//   2. that flag actually carries a body: attached (`--eval=code`) or in a
//      following word. The flag alone is not the proof — the program is its
//      BODY — so `printf '<program>' | node -e` (dangling `-e`, program on
//      stdin) stays a stdin-program route. Tier 2's own
//      `flagCount > bodies.length` rule takes the same view of a bodyless
//      flag (CPR-5).
function argvProvesInlineProgram(words, interpreterWord) {
  for (let i = 0; i < words.length; i++) {
    const w = words[i];
    if (!inlineProgramFlagProof(w, interpreterWord)) continue;
    if (w.indexOf("=") >= 0 || i < words.length - 1) return true;
  }
  return false;
}

// stdinProgramInterpreterKind(seg): "language" | "shell" | null — the kind of
// interpreter this segment is, reported whenever the program it runs is NOT
// provably on argv, i.e. whenever stdin may be CODE rather than data.
//
// The burden of proof is on the ALLOW side, deliberately. The first version of
// this function walked argv looking for the program operand ("a non-flag word
// before the redirect means argv carries the program"), and that shape-based
// walk was fail-OPEN: a flag's own VALUE is a non-flag word, so one shifted
// token cleared a byte-identical body —
//
//   node <<< '<program>'                    -> blocked
//   node --title x <<< '<program>'          -> ALLOWED   (`x` read as a program)
//   python3 -X importtime <<< '<program>'   -> ALLOWED
//
// Knowing that `--title` consumes a value requires a per-interpreter, per-
// version flag-arity table, which is the same enumeration-lag failure mode
// ./interpreter-scan.js records for MEDIUM-6 (CPR-8). So argv SHAPE is not
// consulted at all any more. The only accepted proof is a positive one: an
// inline-program flag (INLINE_PROGRAM_FLAG_RE — the same `-c`/`-e`/`--eval`/
// `-Command` family whose bodies the Tier-2 extractor already reads). Anything
// else is unproven, and unproven means the stdin body is treated as program
// text — the HIGH-2 direction, "cannot analyse" is "cannot clear" (CPR-5).
//
// Accepted consequence: a bare file operand cannot be proven without that same
// flag-arity knowledge, so `node script.js <<< '<text naming a marker>'` is now
// reported as a program route and blocks. That is over-block in the safe
// direction, and the shape (feeding marker-naming DATA to a script through a
// here-string) is rare; `cat <marker> | python3 -c '…'` and `printf hi | node`
// — the everyday data-on-stdin shapes — stay clear, the first because `-c`
// proves the program, the second because its text names nothing protected.
function stdinProgramInterpreterKind(seg) {
  const eff = resolveEffectiveSegment(seg);
  if (!eff || typeof eff.cmd0 !== "string") return null;
  let name = eff.cmd0;
  const argv = (Array.isArray(eff.argv) ? eff.argv : []).slice();
  while (COMMAND_WRAPPERS.has(baseName(name)) && argv.length > 0) name = argv.shift();
  const kind = interpreterKindOfWord(name);
  if (!kind) return null;
  return argvProvesInlineProgram(argv, name) ? null : kind;
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
// other routes (CPR-5) — the kind is reported unless an inline-program flag
// proves the program is on argv, so `node -e '…' <<EOF` treats the heredoc as
// data while `node script.js <<EOF` does not.
function readerKindOfHead(head) {
  const words = String(head || "").trim().split(/\s+/).filter(Boolean);
  let i = 0;
  while (i < words.length && ASSIGN_WORD_RE.test(words[i])) i++;
  while (i < words.length && COMMAND_WRAPPERS.has(baseName(words[i]))) i++;
  if (i >= words.length) return null;
  const kind = interpreterKindOfWord(words[i]);
  if (!kind) return null;
  return argvProvesInlineProgram(words.slice(i + 1), words[i]) ? null : kind;
}

// stdinProgramRoutes(cmdText, segments) ->
//   { bodies: [{body, gateText}], fileTargets: [string], opaqueTexts: [string] }
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
    const kind = stdinProgramInterpreterKind(seg);
    if (!kind) continue;
    // A shell's here-string is already recursed as shell text by
    // nestedCommandTextsOf; only a LANGUAGE interpreter needs the second,
    // language-aware reading of the same body.
    if (kind === "language") {
      for (const v of hereStringValuesOf(seg)) bodies.push({ body: v, gateText: seg.rawText });
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
    if (readerKindOfHead(m[1]) !== "language") continue;
    bodies.push({ body: m[4], gateText: m[1] + "\n" + m[4] });
  }
  // An UNTERMINATED heredoc yields no body but still delivers one at runtime —
  // the same "more invocations than extractable bodies" mismatch that
  // extractAllInterpreterBodies() fail-closes on (CPR-5).
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
  stdinProgramRoutes,
};
