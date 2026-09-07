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

// Shared by the effective-command path and the mid-argv net so both fail
// closed identically.
function interpreterBodyBlocks(found, depth) {
  if (found.kind === "unresolvable") return true;
  if (found.kind === "language") return languageBodyLooksLikeRecursiveDelete(found.lang, found.body);
  if (UNRESOLVABLE_RE.test(found.body)) return true;
  return scanCommandTextForRecursiveDelete(found.body, depth + 1);
}

// A LANGUAGE-kind consumer must be judged as that language: re-parsing
// `import shutil; shutil.rmtree("d")` as bash silently approves it.
function judgeStdinScript(seg, text, depth) {
  const lang = languageInterpreterLang(seg);
  if (lang) return languageBodyLooksLikeRecursiveDelete(lang, text);
  return scanCommandTextForRecursiveDelete(text, depth + 1);
}

// `python <<EOF` delivers a script over stdin, but `<<` is not tokenized as a
// redirect and the newline route strips heredoc bodies wholesale, so the body
// went unjudged (#2210). A non-interpreter consumer (`cat <<EOF`) carries
// DATA, not a script, and is left alone.
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

// Substitutions hidden in RAW tokens: a quoted "$(rm -rf x)" never becomes its
// own segment. An unscannable fragment fails closed.
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

// EVERY newline inside a span is data, not a statement separator. Splitting
// `git commit -m "$(cat <<EOF ... EOF)"` hands a `)"` fragment to the parser
// and fails closed on a command that deletes nothing.
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

// A judge's `null` (unresolvable flag content) folds to "block" — this layer
// is two-valued.
function segmentJudgmentBlocks(seg) {
  for (const judge of [hasRecursiveRmFlag, hasRecursivePwshFlag, hasRecursiveCmdExeFlag]) {
    const verdict = judge(seg);
    if (verdict === true || verdict === null) return true;
  }
  return false;
}

/**
 * Does this command text delete recursively anywhere, through any concealment
 * route (newline injection, interpreter wrappers, substitution, flag
 * variables)? Two-valued: true = block. Unparseable text, an unscannable
 * fragment, an unresolvable body and over-deep nesting all fail closed.
 */
function scanCommandTextForRecursiveDelete(rawCmd, depth = 0, inheritedVars = null) {
  if (depth > MAX_DEPTH) return true;
  if (typeof rawCmd !== "string" || rawCmd === "") return false;

  const ir = parse(rawCmd);
  if (!ir || ir.parseFailure === true) return true;

  if (heredocScriptsBlock(rawCmd, depth)) return true;

  // Shared with the newline route's sibling lines, so `FLAGS=-rf` on one line
  // reaches `rm $FLAGS dir` on the next.
  const envVarValues = inheritedVars instanceof Map ? inheritedVars : new Map();
  const segments = ir.segments || [];
  for (let segIdx = 0; segIdx < segments.length; segIdx++) {
    const seg = segments[segIdx];
    if (!seg) continue;
    // `gci -Recurse | Remove-Item` spans ADJACENT segments, so it cannot live
    // in the per-segment judges.
    if (hasRecursivePwshPipelineFlag(segments, segIdx, ir.separators)) return true;
    const pwshScript = pwshCommandPipelineScript(segments, segIdx, ir.separators);
    if (pwshScript !== null && scanCommandTextForRecursiveDelete(pwshScript, depth + 1)) return true;

    // Stdin-fed forms: the script text never lands in argv, so no argv-driven
    // judge below ever sees it.
    const sepsAligned = Array.isArray(ir.separators) && ir.separators.length === segments.length - 1;
    // Herestring: the operator itself proves stdin delivery, independent of
    // segment alignment or consumer kind.
    if (isShellInterpreter(seg) || languageInterpreterLang(seg)) {
      for (const r of Array.isArray(seg.redirects) ? seg.redirects : []) {
        if (r.op === "<<<" && typeof r.target === "string" &&
            judgeStdinScript(seg, r.target, depth)) return true;
      }
    }
    // Pipe: `echo "rm -rf dir" | bash` / `echo "..." | python`.
    if (sepsAligned && segIdx > 0 && ir.separators[segIdx - 1] === "|" && stdinConsumer(seg)) {
      // An opaque printf format fails closed rather than falling through to
      // scan its incomplete substitute text.
      if (producerTextUnresolvable(segments[segIdx - 1])) return true;
      const producerText = producerLiteralText(segments[segIdx - 1]);
      if (producerText !== null && judgeStdinScript(seg, producerText, depth)) return true;
    }
    // Process substitution: `bash <(echo "rm -rf dir")`. The opening `(` is
    // ALWAYS the separator at this exact index (splitSegmentsWithSeparators
    // pushes each segment immediately before its trailing separator), so the
    // direct read holds even where a paired `)` breaks the sepsAligned
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
    // Only a dynamic COMMAND NAME fails closed here. Testing every candidate
    // text instead denied benign scripts like `trap 'kill $PID' EXIT` (#2210).
    const effCmd0 = resolveEffectiveCommand(seg);
    if (typeof effCmd0 === "string" && UNRESOLVABLE_RE.test(effCmd0)) return true;
    if (interpreterBodyTruncated(rawCmd, seg)) return true;
    const { effSegs, extraScripts } = peelTransparentHeads(seg);
    for (const script of extraScripts) {
      if (scanCommandTextForRecursiveDelete(script, depth + 1)) return true;
    }
    // The ORIGINAL segment is judged too: a peel is a hypothesis, not proof
    // that the original reading was wrong.
    const candidates = [seg, ...effSegs.filter((s) => s !== seg)];
    for (const judgeSeg of candidates) {
      if (segmentJudgmentBlocks(judgeSeg)) return true;
      if (referencesRecursiveFlagVar(judgeSeg, envVarValues)) return true;

      // A wrapper's script body is command TEXT, so it is re-scanned from the top.
      for (const script of wrapperScriptBodies(judgeSeg)) {
        if (UNRESOLVABLE_RE.test(script)) return true;
        if (scanCommandTextForRecursiveDelete(script, depth + 1)) return true;
      }

      for (const found of interpreterBodiesOf(judgeSeg)) {
        if (interpreterBodyBlocks(found, depth)) return true;
      }
    }
    // Mid-argv net: an unclassifiable wrapper option makes the peel AMBIGUOUS
    // and hands back the WRAPPER (`env --bogusopt sh -c 'rm -rf d'`), while a
    // non-wrapper head (`find . -exec sh -c ...`) is never peeled at all.
    for (const found of scanWrappedInterpreter(segTokens(seg))) {
      if (interpreterBodyBlocks(found, depth)) return true;
    }
    if (substitutionsBlock(seg, depth)) return true;
  }

  if (!/[\r\n]/.test(rawCmd)) return false;
  if (newlinesAreAllSpanned(rawCmd)) return false;

  // runCommands joins its elements with "\n", which parse() does not treat as
  // a segment separator. Heredoc BODIES are stripped first so a command merely
  // mentioned inside one is not scanned as a statement.
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
