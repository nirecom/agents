// hooks/block-off-clearance-write/bash-scan/scan.js
// Top-level Bash command scan for the block-off-clearance-write entrypoint:
// parse, merge in the substitution-span reading, then run the redirect / argv /
// nested-body / interpreter rules (file-split, rules/coding/file-split.md
// Pattern A). Moved from ../bash-scan.js; the behavioural change is that every
// predicate now covers PROTECTED SESSION MARKERS as well as the OFF-clearance
// token (#1780 H-1/H-2, CPR-5) and reports WHICH kind was hit so the block
// message can name the right remediation.
"use strict";

const { parse } = require("../../lib/command-ir");
const { extractSubstitutionContents } = require("../../lib/command-parser");
const { collectWriteTargetsFromSegments, SHELL_CONFIG_VERB_SET } = require("../../lib/bash-write-targets");
const {
  classifyProtectedPath,
  mentionsProtectedName,
  TOKEN_MENTION_RE,
} = require("../../lib/protected-basenames");
const { classifyBashWriteTarget, commandCwd, resolveWorkflowDir } = require("../bash-target-context");
const {
  hitsProtectedViaInterpreter,
  interpreterBodyHitsProtected,
} = require("../interpreter-scan");
const { nestedCommandTextsOf, stdinProgramRoutes } = require("../nested-bodies");
const { tagSourceOrder } = require("../../lib/substitution-spans");
const { isAssignmentOnlySegment, priorAssignmentsText } = require("./assignment-text");
const { segmentArgvHitsProtectedArg } = require("./argv-scan");
const { redirectRawTargetsHitProtected } = require("./redirect-scan");

// unparsedVerdict(cmd): the verdict for command text this scanner could NOT
// structurally analyse.
//
// #1780 round-5 HIGH-2: a parse failure used to ABANDON the structural scan and
// fall through to the interpreter heuristic alone, so appending a single
// unterminated quote inside a bash COMMENT (`echo x > <wf>/s1.<marker> #'`) —
// legal, executable bash — disabled every redirect, argv and glob rule at once.
// "Cannot analyse" must mean "cannot clear", not "nothing found": when the text
// mentions a protected name at all and the parser could not prove where that
// mention lands, it fails CLOSED.
//
// The kind is reported as `unparsed-token` / `unparsed-marker` so the block
// message can say that PARSING failed — a false positive here is otherwise
// unexplainable to the person hitting it.
function unparsedVerdict(cmd) {
  if (mentionsProtectedName(cmd)) {
    return TOKEN_MENTION_RE.test(cmd) ? "unparsed-token" : "unparsed-marker";
  }
  return hitsProtectedViaInterpreter(cmd) ? "interpreter" : null;
}

// Recursion cap for command text nested inside command text (eval bodies,
// here-strings, command substitutions). Three levels is far past anything
// legitimate and keeps a crafted deeply-nested payload from costing time.
const MAX_NESTED_SCAN_DEPTH = 3;

// substitutionSpanSegments(cmd, ir): the segments of a SECOND parse in which an
// unquoted `$( … )` / `` ` … ` `` / `$(( … ))` / `${ … }` span is kept WHOLE,
// minus the ones the ordinary parse already produced.
//
// #1780 round-11 CAUSE-2. The ordinary parse tears an unquoted substitution
// apart: `$( )` because `(` and `)` are segment separators, and every spelling
// because the tokenizer split on the whitespace INSIDE the span. Neither
// fragment is the path the shell writes to, so no rule ever judged the real
// target. Measured ALLOW:
//
//   touch `printf '%s%s' <wf>/s1.workflow -off`
//   touch $(printf '%s%s' <wf>/s1.workflow -off)
//   echo x > `printf '%s%s' <wf>/s1.workflow -off`
//
// DIRECTION DISCIPLINE — this reading is ADDED to the ordinary one, never
// substituted for it. The ordinary `( )` split is load-bearing: it is what
// promotes a substitution body, a subshell body and a process-substitution body
// `<(cmd)` / `>(cmd)` to their own scanned segments, so `$(rm <marker>)` and
// `tee >(cat > <marker>)` block TODAY because of it. A parser change that made
// the span survive as one token INSTEAD would have silently traded four blocks
// for three. Both readings are scanned; a denylist may only gain candidate
// readings, never lose them.
//
// Fail-soft: if the second parse fails, the caller keeps exactly its previous
// behaviour rather than losing the ordinary reading too.
function substitutionSpanSegments(cmd, ir) {
  const base = ir && Array.isArray(ir.segments) ? ir.segments : [];
  let spanIr;
  try {
    spanIr = parse(cmd, { preserveSubstitutionSpans: true });
  } catch (_e) {
    return [];
  }
  if (!spanIr || spanIr.parseFailure === true || !Array.isArray(spanIr.segments)) return [];
  // #1780 round-13: record each span segment's position in ITS OWN reading
  // BEFORE the dedup filter below drops some of them, so the order-sensitive
  // helpers (commandCwd / priorAssignmentsText) can recover true source order
  // once these segments are appended to the ordinary list — array position in
  // the merged list does not carry it. See ../../lib/substitution-spans.js.
  tagSourceOrder(spanIr.segments);
  // Dedup key = the segment TEXT *and* its token structure. rawText alone is
  // wrong: a backtick span never contained a `(`, so the two parses cut the
  // command into byte-identical segments and differ only in how the TOKENIZER
  // walked them (`` touch `printf '%s%s' <wf>/s1.workflow -off` `` is one
  // segment either way, but four argv tokens under the ordinary parse and one
  // under this one). Keying on rawText discarded exactly the segments this
  // second reading exists to contribute.
  const seen = new Set(base.map(segmentKey));
  return spanIr.segments.filter((s) => s && typeof s.rawText === "string" && !seen.has(segmentKey(s)));
}

// Structural identity of a segment: its text, its token cut, and its redirect
// cut. All three must participate — the two parses can agree on the text and
// the argv and still disagree on where a redirect TARGET ends
// (`` echo x > `printf '%s%s' <wf>/s1.workflow -off` ``).
//
// codex MEDIUM/scanner A: these used to be raw control bytes (NUL / SOH) typed
// directly into the source, which makes the file appear binary to git/GitHub
// (diffs and review tools refuse to render it as text). Computing them at
// runtime via String.fromCharCode keeps the source pure ASCII/diffable while
// the resulting separator values are unchanged; the key space is unaffected
// because both bytes are still guaranteed absent from any of the joined parts
// (rawText / cmd0Raw / op / targetRaw are shell command text, which cannot
// contain either control byte).
const SEG_KEY_SEP = String.fromCharCode(0);
const SEG_KEY_ITEM_SEP = String.fromCharCode(1);

function redirectKeyPart(seg) {
  const redirects = Array.isArray(seg.redirects) ? seg.redirects : [];
  return redirects
    .map((r) => String((r && r.op) || "") + SEG_KEY_ITEM_SEP + String((r && r.targetRaw) || (r && r.target) || ""))
    .join(SEG_KEY_SEP);
}

function segmentKey(seg) {
  if (!seg || typeof seg.rawText !== "string") return null;
  const argvRaw = Array.isArray(seg.argvRaw) ? seg.argvRaw : [];
  return [seg.rawText, seg.cmd0Raw || "", argvRaw.length, redirectKeyPart(seg), argvRaw.join(SEG_KEY_SEP)].join(
    SEG_KEY_SEP
  );
}

// bashHitsProtected(cmd, opts):
//   "token" | "marker" | "workflow-glob" | "workflow-dynamic" | "interpreter" |
//   "unparsed-token" | "unparsed-marker" | null.
// `opts.cwd` is the tool's working directory when the harness supplies it; it
// is only ever used to resolve a RELATIVE write target's directory for the
// workflow-dir glob qualifier (an absent cwd disables that resolution rather
// than widening the deny set).
function bashHitsProtected(cmd, opts, _depth) {
  if (!cmd || typeof cmd !== "string") return null;
  const depth = typeof _depth === "number" ? _depth : 0;
  const toolCwd = opts && typeof opts.cwd === "string" ? opts.cwd : null;
  const workflowDir = resolveWorkflowDir();
  try {
    const ir = parse(cmd);
    if (!ir || ir.parseFailure) return unparsedVerdict(cmd);
    // MEDIUM-4 (#1780 round-5, CPR-5): a COMMAND SUBSTITUTION body is command
    // text and must be scanned as such. `$( … )` only appeared to be covered
    // because `(` / `)` are segment separators, which accidentally promoted
    // its body to a segment; backticks have no such accident, so
    // `` echo x > `printf s1.<marker>` `` was invisible. Recursing every
    // substitution body — both spellings — removes the asymmetry at its root
    // instead of patching one more literal test.
    if (depth < MAX_NESTED_SCAN_DEPTH) {
      for (const sub of extractSubstitutionContents(cmd)) {
        const kind = bashHitsProtected(sub, opts, depth + 1);
        if (kind) return kind;
      }
    }
    // The substitution-span reading, appended AFTER the ordinary segments so the
    // ordinary reading keeps its own indices. The appended tail's array position
    // is NOT source order, so the index-based helpers (commandCwd,
    // priorAssignmentsText) recover it from the tag applied in
    // substitutionSpanSegments above (#1780 round-13).
    const extraSegments = substitutionSpanSegments(cmd, ir);
    const segments = extraSegments.length > 0 ? ir.segments.concat(extraSegments) : ir.segments;
    // codex MEDIUM/scanner B: this used to read `ir.segments` — the ORDINARY
    // parse only — so a write target hidden inside a round-11 substitution
    // span (see substitutionSpanSegments above) was invisible to the
    // write-target collector even though the redirect/argv scans below
    // already consult the merged `segments`. DIRECTION DISCIPLINE applies
    // here too: the merged reading is additive, so this can only gain
    // candidate targets, never lose the ones `ir.segments` alone already gave.
    const { targets } = collectWriteTargetsFromSegments(segments, { verbs: SHELL_CONFIG_VERB_SET });
    if (targets) {
      for (const t of targets) {
        const kind = t && classifyProtectedPath(t.path);
        if (kind) return kind;
      }
    }
    const rawRedirectKind = redirectRawTargetsHitProtected(segments, { workflowDir, cwd: toolCwd });
    if (rawRedirectKind) return rawRedirectKind;
    for (let idx = 0; idx < segments.length; idx++) {
      const ctx = { workflowDir, cwd: commandCwd(segments, idx, toolCwd) };
      const kind = segmentArgvHitsProtectedArg(segments[idx], priorAssignmentsText(segments, idx), ctx);
      if (kind) return kind;
      // HIGH-3 / MEDIUM-5: `eval <text>` and `<reader> <<< <text>` hand a
      // string back to the shell as a command line. Re-run the WHOLE scan on
      // it rather than enumerating readers or adding one more interpreter
      // name (see ../nested-bodies.js).
      if (depth < MAX_NESTED_SCAN_DEPTH) {
        for (const body of nestedCommandTextsOf(segments[idx])) {
          const nested = bashHitsProtected(body, opts, depth + 1);
          if (nested) return nested;
        }
      }
    }
    // Program text delivered on an interpreter's STDIN (here-string, heredoc,
    // pipe, `< file`, process substitution). Routed by the RECEIVING command's
    // interpreter identity rather than by delivery syntax — see the block
    // comment in ../nested-bodies.js.
    const stdinRoutes = stdinProgramRoutes(cmd, segments);
    for (const b of stdinRoutes.bodies) {
      // Judged in the interpreter's own language, exactly as a `-e`/`-c` body is.
      if (interpreterBodyHitsProtected(b.body, b.gateText)) return "interpreter";
    }
    for (const t of stdinRoutes.fileTargets) {
      // `node < <marker>` EXECUTES the file. Classify it as a path — this is
      // narrower than the mention rule on purpose, so a plain `cat < <marker>`
      // read (no interpreter) stays approved.
      const kind = classifyBashWriteTarget(t, "", { workflowDir, cwd: toolCwd });
      if (kind) return kind;
    }
    for (const t of stdinRoutes.opaqueTexts) {
      if (mentionsProtectedName(t)) return "interpreter";
    }
    // Interpreter heuristic runs PER SEGMENT, not on the whole cmd string
    // (supervisor-audit-4): a `cd` into a path containing "off-clearance", or
    // an unrelated --detail argument describing the token, lives in a
    // different segment than an interpreter invocation elsewhere on the same
    // line and must not make that unrelated invocation look suspicious.
    // The Tier-1 mention gate, however, also needs to see any IMMEDIATELY
    // PRECEDING assignment-only segments (`P=<token>; node -e $BODY`): a
    // shell variable set there can flow into this segment's own unquoted
    // interpreter body, and that indirection must still fail closed (M1 /
    // #1780 WR5) even though the assignment lives in a different segment.
    // Non-assignment preceding segments (`cd ...`, an unrelated program's
    // `--detail` flag) are never folded in — only a contiguous run of pure
    // `VAR=val` segments immediately before the current one.
    const interpreterHit = segments.some((seg, idx) => {
      let gateText = seg.rawText;
      for (let j = idx - 1; j >= 0; j--) {
        const prev = segments[j];
        if (!isAssignmentOnlySegment(prev)) break;
        gateText = prev.rawText + "\n" + gateText;
      }
      return hitsProtectedViaInterpreter(seg.rawText, gateText);
    });
    return interpreterHit ? "interpreter" : null;
  } catch (_e) {
    // An analysis that THREW proved nothing either — same fail-closed rule.
    return unparsedVerdict(cmd);
  }
}

module.exports = {
  unparsedVerdict,
  substitutionSpanSegments,
  bashHitsProtected,
  MAX_NESTED_SCAN_DEPTH,
};
