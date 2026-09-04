// hooks/block-clearance-token-write/bash-scan/scan.js
// Top-level Bash command scan for the block-clearance-token-write entrypoint:
// parse, merge in the substitution-span reading, then run the redirect / argv /
// nested-body / interpreter rules (file-split, rules/coding/file-split.md
// Pattern A). Every predicate covers protected session markers as well as the
// OFF-clearance token (CPR-ORTH), and reports WHICH kind was hit so the block
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
// structurally analyse. A parse failure must not fall through to "nothing
// found" — a single unterminated quote inside a bash comment is legal,
// executable bash that would otherwise disable every redirect/argv/glob rule.
// "Cannot analyse" means "cannot clear": if the text mentions a protected
// name and parsing can't prove where it lands, it fails CLOSED. The kind is
// reported as `unparsed-token`/`unparsed-marker` so the block message can
// say parsing failed, rather than leaving a false positive unexplainable.
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
// The ordinary parse tears an unquoted substitution apart on its internal `(`/`)`
// and whitespace, so neither fragment is the real write target. This reading is
// ADDED to the ordinary one, never substituted for it: the ordinary `( )` split is
// what promotes substitution/subshell bodies to their own scanned segments, so
// replacing it would lose that coverage. Fail-soft on a failed second parse.
function substitutionSpanSegments(cmd, ir) {
  const base = ir && Array.isArray(ir.segments) ? ir.segments : [];
  let spanIr;
  try {
    spanIr = parse(cmd, { preserveSubstitutionSpans: true });
  } catch (_e) {
    return [];
  }
  if (!spanIr || spanIr.parseFailure === true || !Array.isArray(spanIr.segments)) return [];
  // Record each span segment's position in ITS OWN reading before the dedup
  // filter drops some of them, so order-sensitive helpers (commandCwd /
  // priorAssignmentsText) can recover true source order once these segments
  // are appended to the ordinary list — array position alone doesn't carry
  // it. See ../../lib/substitution-spans.js.
  tagSourceOrder(spanIr.segments);
  // Dedup key = the segment TEXT *and* its token structure. rawText alone
  // would drop exactly the segments this reading exists to contribute: the
  // two parses can cut byte-identical text into a different argv (one token
  // here vs. several under the ordinary tokenizer).
  const seen = new Set(base.map(segmentKey));
  return spanIr.segments.filter((s) => s && typeof s.rawText === "string" && !seen.has(segmentKey(s)));
}

// Structural identity of a segment: its text, its token cut, and its redirect
// cut. All three must participate — the two parses can agree on text and argv
// and still disagree on where a redirect TARGET ends. The separators are
// computed via String.fromCharCode (rather than literal control bytes) to
// keep the source pure ASCII/diffable; both bytes are guaranteed absent from
// the joined shell-text parts, so the key space is unaffected.
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
  // #2108: rides alongside `workflowDir`/`cwd` in the per-segment ctx without
  // changing what either of those means. Self-recursion re-passes `opts` whole,
  // so nested bodies inherit it automatically.
  const sessionCtx = opts && opts.sessionCtx;
  try {
    const ir = parse(cmd);
    if (!ir || ir.parseFailure) return unparsedVerdict(cmd);
    // A command-substitution body is command text and must be scanned as
    // such — `$( … )` only appeared covered because `(`/`)` are segment
    // separators; backticks have no such accident. Recursing every
    // substitution body (both spellings) removes the asymmetry at the root
    // (CPR-ORTH).
    if (depth < MAX_NESTED_SCAN_DEPTH) {
      for (const sub of extractSubstitutionContents(cmd)) {
        const kind = bashHitsProtected(sub, opts, depth + 1);
        if (kind) return kind;
      }
    }
    // The substitution-span reading, appended AFTER the ordinary segments so
    // the ordinary reading keeps its own indices. The appended tail's array
    // position is NOT source order; index-based helpers (commandCwd,
    // priorAssignmentsText) recover it from the tag applied above.
    const extraSegments = substitutionSpanSegments(cmd, ir);
    const segments = extraSegments.length > 0 ? ir.segments.concat(extraSegments) : ir.segments;
    // Must read the merged `segments`, not just `ir.segments` — a write
    // target hidden inside a substitution span is otherwise invisible to the
    // write-target collector even though redirect/argv scans below already
    // consult the merged list. The merge is additive: it can only gain
    // candidate targets, never lose ones the ordinary parse already gave.
    const { targets } = collectWriteTargetsFromSegments(segments, { verbs: SHELL_CONFIG_VERB_SET });
    if (targets) {
      for (const t of targets) {
        const kind = t && classifyProtectedPath(t.path, { sessionCtx });
        if (kind) return kind;
      }
    }
    const rawRedirectKind = redirectRawTargetsHitProtected(segments, { workflowDir, cwd: toolCwd, sessionCtx });
    if (rawRedirectKind) return rawRedirectKind;
    for (let idx = 0; idx < segments.length; idx++) {
      const ctx = { workflowDir, cwd: commandCwd(segments, idx, toolCwd), sessionCtx };
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
      if (interpreterBodyHitsProtected(b.body, b.gateText, b.lang)) return "interpreter";
    }
    for (const t of stdinRoutes.fileTargets) {
      // `node < <marker>` EXECUTES the file. Classify it as a path — this is
      // narrower than the mention rule on purpose, so a plain `cat < <marker>`
      // read (no interpreter) stays approved.
      const kind = classifyBashWriteTarget(t, "", { workflowDir, cwd: toolCwd, sessionCtx });
      if (kind) return kind;
    }
    for (const t of stdinRoutes.opaqueTexts) {
      if (mentionsProtectedName(t)) return "interpreter";
    }
    // Interpreter heuristic runs PER SEGMENT, not on the whole cmd string: a
    // `cd` into a path containing "off-clearance", or an unrelated --detail
    // argument, must not make an interpreter invocation elsewhere on the
    // same line look suspicious. The Tier-1 mention gate does still need to
    // see any IMMEDIATELY PRECEDING assignment-only segments
    // (`P=<token>; node -e $BODY`) — a shell variable set there can flow
    // into this segment's own interpreter body — so only a contiguous run
    // of pure `VAR=val` segments is folded in.
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
