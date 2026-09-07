"use strict";

const { parse } = require("../../command-ir");
const {
  resolveEffectiveCommand,
  resolveEffectiveArgv,
  commandBasename,
  scanWrappedInterpreter,
} = require("../../bash-write-patterns/segment-utils");
const {
  UNRESOLVABLE_RE,
  languageBodyLooksLikeRecursiveDelete,
  interpreterBodiesOf,
  interpreterBodyTruncated,
} = require("./interpreter-bodies");
const { scanSpans, spanAwareNewlineSplit } = require("../../quote-spans");
const { stripHeredocBody } = require("../../strip-quoted-args");
const { hasRecursiveRmFlag } = require("../rm");
const { hasRecursivePwshFlag, hasRecursivePwshPipelineFlag } = require("../pwsh");
const { hasRecursiveCmdExeFlag } = require("../cmd-exe");
const {
  segTokens,
  isPureAssignmentSegment,
  applyAssignments,
  applyUnset,
  ASSIGNMENT_CARRYING_CMDS,
  applyAssignmentCarryingCommand,
  referencesRecursiveFlagVar,
} = require("./var-tracking");
const { wrapperScriptBodies } = require("./wrapper-bodies");
const {
  pwshCommandPipelineScript,
  isShellInterpreter,
  languageInterpreterLang,
  readsStdinAsScript,
  stdinConsumer,
  producerLiteralText,
  producerTextUnresolvable,
} = require("./stdin-delivery");
const { peelTransparentHeads } = require("./head-peeling");
const { extractHeredocs } = require("./heredoc-openers");

// Recursion budget: pathological nesting fails closed rather than being walked.
const MAX_DEPTH = 8;

// One interpreter body's verdict, shared by the effective-command path and the
// mid-argv net so both fail closed identically (CPR-SSOT).
function interpreterBodyBlocks(found, depth) {
  if (found.kind === "unresolvable") return true;
  if (found.kind === "language") return languageBodyLooksLikeRecursiveDelete(found.lang, found.body);
  if (UNRESOLVABLE_RE.test(found.body)) return true;
  return scanCommandTextForRecursiveDelete(found.body, depth + 1);
}

// Judge a script body delivered to `seg` via stdin (pipe, herestring, process
// substitution). A LANGUAGE-kind consumer (`python`, `pwsh -Command -`) must
// be judged as that language's body, not re-parsed as shell command text —
// re-parsing `import shutil; shutil.rmtree("d")` as bash would silently
// approve it, since it is not valid shell syntax for a delete (#2210
// security-scanner C26).
function judgeStdinScript(seg, text, depth) {
  const lang = languageInterpreterLang(seg);
  if (lang) return languageBodyLooksLikeRecursiveDelete(lang, text);
  return scanCommandTextForRecursiveDelete(text, depth + 1);
}

// Heredoc route: `python <<EOF ... EOF` delivers its script over STDIN exactly
// as `<<<` / `|` / `<(...)` do, but the `<<` operator is not tokenized as a
// redirect at all (command-parser.js REDIRECT_OP_ALT stops at `<<<`) and the
// newline route strips heredoc bodies wholesale — so the body was never judged
// (#2210 round-13). The consumer is the command text preceding `<<`, parsed on
// its own, mirroring the herestring case; a non-interpreter consumer (`cat
// <<EOF`) carries DATA, not a script, and is left alone.
function heredocScriptsBlock(rawCmd, depth) {
  for (const { head, body } of extractHeredocs(rawCmd)) {
    const ir = parse(head);
    const segs = ir && !ir.parseFailure ? ir.segments || [] : [];
    const seg = segs[segs.length - 1];
    if (!seg) continue;
    if (!isShellInterpreter(seg) && !languageInterpreterLang(seg)) continue;
    if (judgeStdinScript(seg, body, depth)) return true;
  }
  return false;
}

// Recurse into every command substitution ($(...) / `...`) hidden inside the
// segment's RAW tokens — a quoted "$(rm -rf x)" never becomes its own segment.
// An unscannable fragment fails closed. Contract: detail.md Step 4 2c.
function substitutionsBlock(seg, depth) {
  const cmd0Raw = typeof seg.cmd0Raw === "string" ? [seg.cmd0Raw] : [];
  const argvRaw = Array.isArray(seg.argvRaw) ? seg.argvRaw : [];
  for (const frag of [...cmd0Raw, ...argvRaw]) {
    if (typeof frag !== "string" || frag === "") continue;
    const sr = scanSpans(frag);
    if (!sr || sr.ok === false) return true;
    for (const span of sr.spans || []) {
      if (span.kind !== "cmdsubst" && span.kind !== "backtick") continue;
      if (scanCommandTextForRecursiveDelete(frag.slice(span.innerStart, span.innerEnd), depth + 1)) return true;
    }
  }
  return false;
}

// True when EVERY newline sits inside a quote / substitution span, i.e. it is
// data (or substitution content step 2c already recursed into), never a
// statement separator. `git commit -m "$(cat <<EOF ... EOF)"` is the shape that
// needs this: splitting it would hand a `)"` fragment to the parser and
// fail closed on a command that deletes nothing.
function newlinesAreAllSpanned(rawCmd) {
  const sr = scanSpans(rawCmd);
  if (!sr || sr.ok === false) return false;
  const spans = sr.spans || [];
  for (let i = 0; i < rawCmd.length; i++) {
    const ch = rawCmd[i];
    if (ch !== "\n" && ch !== "\r") continue;
    if (!spans.some((sp) => sp.innerStart <= i && i < sp.innerEnd)) return false;
  }
  return true;
}

// A per-segment `null` (recursive-capable command, unresolvable flag content)
// folds to "block" here — the scan layer is two-valued.
function segmentJudgmentBlocks(seg) {
  for (const judge of [hasRecursiveRmFlag, hasRecursivePwshFlag, hasRecursiveCmdExeFlag]) {
    const verdict = judge(seg);
    if (verdict === true || verdict === null) return true;
  }
  return false;
}

/**
 * scanCommandTextForRecursiveDelete(rawCmd, depth) — does this command text
 * perform a recursive delete anywhere, through any of the four concealment
 * routes (newline injection, interpreter wrappers, command substitution,
 * env-prefix flag variables)? Two-valued: true = block, false = clean.
 * Unparseable text, an unscannable fragment, an unresolvable interpreter body
 * and over-deep nesting all fail closed. Contract: detail.md Step 4.
 */
function scanCommandTextForRecursiveDelete(rawCmd, depth = 0, inheritedVars = null) {
  if (depth > MAX_DEPTH) return true;
  if (typeof rawCmd !== "string" || rawCmd === "") return false;

  const ir = parse(rawCmd);
  if (!ir || ir.parseFailure === true) return true;

  if (heredocScriptsBlock(rawCmd, depth)) return true;

  // `inheritedVars`, when passed, is the SAME map used by an earlier sibling
  // line of the same newline-joined command (see the newline-route call
  // below) — carrying an assignment like `FLAGS=-rf` on one line forward to a
  // `rm $FLAGS dir` on the next, since each line would otherwise be scanned
  // as an independent, memory-less recursive call (#2210 round8 item 7).
  const envVarValues = inheritedVars instanceof Map ? inheritedVars : new Map();
  const segments = ir.segments || [];
  for (let segIdx = 0; segIdx < segments.length; segIdx++) {
    const seg = segments[segIdx];
    if (!seg) continue;
    // Upstream-recursion pipeline form (`gci -Recurse | Remove-Item`) — judged
    // across ADJACENT segments, so it cannot live in the per-segment judges.
    if (hasRecursivePwshPipelineFlag(segments, segIdx, ir.separators)) return true;
    const pwshScript = pwshCommandPipelineScript(segments, segIdx, ir.separators);
    if (pwshScript !== null && scanCommandTextForRecursiveDelete(pwshScript, depth + 1)) return true;

    // Stdin-fed shell forms (#2210 N2): the script text never lands in argv,
    // so none of the argv-driven judges below ever see it.
    const sepsAligned = Array.isArray(ir.separators) && ir.separators.length === segments.length - 1;
    // Herestring: `bash <<< "rm -rf dir"` / `python <<< "..."` — the operator
    // itself proves stdin delivery, independent of segment alignment or
    // consumer kind (shell or language, #2210 security-scanner C26).
    if (isShellInterpreter(seg) || languageInterpreterLang(seg)) {
      for (const r of Array.isArray(seg.redirects) ? seg.redirects : []) {
        if (r.op === "<<<" && typeof r.target === "string" &&
            judgeStdinScript(seg, r.target, depth)) return true;
      }
    }
    // Pipe: `echo "rm -rf dir" | bash` / `echo "..." | python`.
    if (sepsAligned && segIdx > 0 && ir.separators[segIdx - 1] === "|" && stdinConsumer(seg)) {
      // An opaque printf format (unresolvable — see stdin-delivery.js) fails
      // closed here rather than falling through to scan its incomplete
      // substitute text, the same convention wrapperScriptBodies' UNRESOLVABLE_RE
      // check below applies to its own class of unresolved content.
      if (producerTextUnresolvable(segments[segIdx - 1])) return true;
      const producerText = producerLiteralText(segments[segIdx - 1]);
      if (producerText !== null && judgeStdinScript(seg, producerText, depth)) return true;
    }
    // Process substitution: `bash <(echo "rm -rf dir")` — command-ir splits the
    // substituted body into its own segment on the bare `(`/`)`, leaving the
    // owning segment's raw text ending in the `<`/`>` that opened it. The `(`
    // that opens a substitution is ALWAYS the separator recorded at this exact
    // index (each flush pushes its segment immediately before its trailing
    // separator token — see command-parser.js splitSegmentsWithSeparators), so
    // this direct index read holds even when a paired `)` leaves `separators`
    // longer than `segments.length - 1` and fails the generic sepsAligned
    // invariant the adjacent-pipeline checks above need.
    if (Array.isArray(ir.separators) && segIdx + 1 < segments.length && ir.separators[segIdx] === "(" &&
        /[<>]\s*$/.test(seg.rawText || "") && readsStdinAsScript(seg)) {
      if (producerTextUnresolvable(segments[segIdx + 1])) return true;
      const producerText = producerLiteralText(segments[segIdx + 1]);
      if (producerText !== null && judgeStdinScript(seg, producerText, depth)) return true;
    }

    if (isPureAssignmentSegment(seg)) {
      applyAssignments(seg, envVarValues);
      continue;
    }
    if (resolveEffectiveCommand(seg) === "unset") {
      applyUnset(seg, envVarValues);
      continue;
    }
    if (ASSIGNMENT_CARRYING_CMDS.has(commandBasename(resolveEffectiveCommand(seg)))) {
      applyAssignmentCarryingCommand(seg, envVarValues);
      continue;
    }
    // A dynamic COMMAND NAME itself (`$cmd arg`, `` `gen` arg ``) can't be
    // resolved at all, so fail closed here (#2210 F7) — this is narrower than
    // blanket-testing every extraScript candidate text, which wrongly denied
    // benign literal scripts merely referencing a variable as an argument
    // (`trap 'kill $PID' EXIT`); those are left to recursion below instead.
    const effCmd0 = resolveEffectiveCommand(seg);
    if (typeof effCmd0 === "string" && UNRESOLVABLE_RE.test(effCmd0)) return true;
    if (interpreterBodyTruncated(rawCmd, seg)) return true;
    const { effSegs, extraScripts } = peelTransparentHeads(seg);
    for (const script of extraScripts) {
      if (scanCommandTextForRecursiveDelete(script, depth + 1)) return true;
    }
    // Judge the ORIGINAL segment too, never only the peeled candidate(s)
    // (#2210 N3) — a peel is a hypothesis about what the command underneath
    // is, not proof the original segment's own reading was wrong.
    const candidates = [seg, ...effSegs.filter((s) => s !== seg)];
    for (const judgeSeg of candidates) {
      if (segmentJudgmentBlocks(judgeSeg)) return true;
      if (referencesRecursiveFlagVar(judgeSeg, envVarValues)) return true;

      // Script bodies a wrapper hands to a shell (`env -S`, `flock -c`, `su -c`,
      // `watch '...'`) are command TEXT, so they are re-scanned from the top.
      for (const script of wrapperScriptBodies(judgeSeg)) {
        if (UNRESOLVABLE_RE.test(script)) return true;
        if (scanCommandTextForRecursiveDelete(script, depth + 1)) return true;
      }

      for (const found of interpreterBodiesOf(judgeSeg)) {
        if (interpreterBodyBlocks(found, depth)) return true;
      }
    }
    // Mid-argv interpreter net: an unclassifiable wrapper option makes the peel
    // AMBIGUOUS and resolveEffectiveCommand hands back the WRAPPER, so the
    // `-c` body above is never reached (`env --bogusopt sh -c 'rm -rf d'`,
    // `nice -X`, `sudo -B`); a non-wrapper head (`find . -exec sh -c ...`) is
    // never peeled at all. Scanning the raw tokens covers both (#2210 round-5).
    for (const found of scanWrappedInterpreter(segTokens(seg))) {
      if (interpreterBodyBlocks(found, depth)) return true;
    }
    if (substitutionsBlock(seg, depth)) return true;
  }

  if (!/[\r\n]/.test(rawCmd)) return false;
  if (newlinesAreAllSpanned(rawCmd)) return false;

  // Newline route: runCommands joins its elements with "\n", and parse() does
  // not treat a newline as a segment separator. Heredoc BODIES are removed
  // first so a mentioned command inside one is not scanned as a statement.
  const split = spanAwareNewlineSplit(stripHeredocBody(rawCmd));
  if (!split || split.ok === false) return true;
  const lines = split.lines || [];
  if (lines.length < 2) return false;
  for (const line of lines) {
    if (scanCommandTextForRecursiveDelete(line, depth + 1, envVarValues)) return true;
  }
  return false;
}

module.exports = { scanCommandTextForRecursiveDelete };
