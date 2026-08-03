// hooks/block-off-clearance-write/bash-scan/argv-scan.js
// "Does any argv token of this segment name a protected path?" — the argv half
// of ./scan.js (file-split, rules/coding/file-split.md Pattern A).
"use strict";

const path = require("path");
const { resolveEffectiveSegment } = require("../../lib/command-ir");
const {
  classifyProtectedBashToken,
  mentionsProtectedName,
  TOKEN_MENTION_RE,
} = require("../../lib/protected-basenames");
const { classifyBashWriteTarget } = require("../bash-target-context");
const {
  extractAllInterpreterBodies,
  looksLikeInterpreterInvocation,
} = require("../interpreter-scan");
// `$ENV:` is the same scope prefix as `$env:` in PowerShell — fold it the
// same way interpreter-scan.js does, or one scanner sanctions a spelling the
// other treats as unknown (CPR-5).
const { PWSH_ENV_PREFIX } = require("../../lib/case-insensitive-literal");

// Verbs like `ln -s`, `sed -i`, `install`, `dd of=`, `truncate`, and `touch`
// can create or mutate an arbitrary file without ever looking like a
// "redirect". Rather than a per-verb extractor, treat any argv token naming
// a protected basename as a hit unless the command is a known read-only
// verb — fail-closed for anything unrecognized.
const READ_ONLY_ARG_COMMAND_RE = /^(?:cat|type|ls|dir|head|tail|wc|file|stat|readlink|less|more|findstr|grep|rg)(?:\.exe)?$/i;

// `less -o FILE` / `-O FILE` / `--log-file=FILE` opens a log and CREATES the
// named file, so read-only-ness is a property of command+args, not just the
// name. The rest of the allowlist emits to stdout only with no output/log/
// in-place-edit option — re-verify that before adding a new member (CPR-4).
const LESS_LOG_OPT_RE = /^(?:-o(?![-\s])|--log-file(?:=|$))/i;

function readOnlyInvocation(cmdBase, argv) {
  if (!READ_ONLY_ARG_COMMAND_RE.test(cmdBase)) return false;
  if (/^less(?:\.exe)?$/i.test(cmdBase)) {
    return !argv.some((a) => typeof a === "string" && LESS_LOG_OPT_RE.test(a));
  }
  return true;
}

// A plain (non-export) `A=<token>; ln -s /tmp/x $A` sets a shell variable
// visible to later commands without ever spelling the token literally in
// argv. Resolve `$NAME` / `${NAME}` / pwsh `$env:NAME` against the
// contiguous run of preceding plain-assignment segments and fail closed
// when the assignment names a protected path.
const VAR_REF_RE = new RegExp(String.raw`^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$|^\$${PWSH_ENV_PREFIX}([A-Za-z_][A-Za-z0-9_]*)$`);

// segmentArgvHitsProtectedArg(seg, precedingAssignText, ctx):
//   "token" | "marker" | "workflow-glob" | "workflow-dynamic" | null.
// `ctx` ({ workflowDir, cwd }) is optional — without it the workflow-dir glob
// qualifier simply does not fire, and the escape / quoting / assignment-splice
// normalization still applies.
function segmentArgvHitsProtectedArg(seg, precedingAssignText, ctx) {
  const eff = resolveEffectiveSegment(seg);
  if (!eff || !eff.cmd0) return null;

  // cmd0 gets the same protected-name classification argv does: a mis-parsed
  // redirect operator can deposit the real write target at position zero
  // (`echo x >| s1.<marker>`), and this is the general defence against any
  // future tokenizer gap that shifts a target into command position (CPR-4).
  const cmd0Kind =
    classifyProtectedBashToken(seg && seg.cmd0Raw ? seg.cmd0Raw : eff.cmd0) ||
    classifyProtectedBashToken(eff.cmd0);
  if (cmd0Kind) return cmd0Kind;

  const cmdBase = path.basename(String(eff.cmd0).replace(/\\/g, "/")).toLowerCase();
  const argv = Array.isArray(eff.argv) ? eff.argv : [];
  // The RAW spelling, index-aligned to eff.argv. cmd0 and redirect targets
  // already classify the raw text typed; the argv loop is the one site that
  // would otherwise read only the COOKED token, letting an ANSI-C-escaped
  // target slip past a byte-identical redirect that blocks (CPR-5).
  // resolveEffectiveSegment() strips a token PREFIX but leaves argvRaw stale,
  // so eff.argv is a suffix of seg.argv; rawOffset recovers the alignment,
  // and disables raw reading (rather than mis-pairing tokens) if that
  // invariant ever breaks.
  const segArgv = seg && Array.isArray(seg.argv) ? seg.argv : [];
  const segArgvRaw = seg && Array.isArray(seg.argvRaw) ? seg.argvRaw : [];
  const rawOffset =
    segArgvRaw.length === segArgv.length && segArgv.length >= argv.length
      ? segArgv.length - argv.length
      : -1;
  const rawArgvAt = (i) => {
    if (rawOffset < 0) return null;
    const r = segArgvRaw[rawOffset + i];
    return typeof r === "string" && r !== "" ? r : null;
  };
  // readOnlyInvocation is consumed in the PERMISSION direction (true SKIPS
  // classification), so it must see BOTH spellings — an escaped `less -o`
  // flag is still not read-only. The union can only push it toward false.
  const argvBothSpellings = argv.concat(segArgvRaw.filter((r) => typeof r === "string"));
  if (readOnlyInvocation(cmdBase, argvBothSpellings)) return null;
  const assignText = typeof precedingAssignText === "string" ? precedingAssignText : "";
  // DIRECTION DISCIPLINE: this Set is consumed in the PERMISSION direction —
  // membership SKIPS bare-path classification and defers to Tier 2. It must
  // hold only tokens Tier 2 will actually judge (looksLikeInterpreterInvocation
  // + extractAllInterpreterBodies), never derived from the wider FLAG_ALTS
  // extraction alone: a non-interpreter command with a `-c`-shaped flag
  // (`tar -cf`, `install -c`, `ar -rc`, `find -exec`) would otherwise have its
  // target swallowed by a deferral that never runs, and nothing judges it —
  // and `tar -cf` alone can forge a session-override marker (file EXISTENCE
  // alone authorizes it; hooks/lib/session-markers.js).
  const segText = seg && typeof seg.rawText === "string" ? seg.rawText : "";
  const interpreterBodies = new Set(
    looksLikeInterpreterInvocation(segText) ? extractAllInterpreterBodies(segText).bodies : []
  );
  for (let ai = 0; ai < argv.length; ai++) {
    const a = argv[ai];
    if (typeof a !== "string") continue;
    const aRaw = rawArgvAt(ai);
    // A whitespace-containing argv token isn't necessarily prose: a genuine
    // quoted path with a spaced directory (e.g. Windows "C:\Users\First
    // Last\...") is indistinguishable from descriptive text by whitespace
    // alone. Gate on path-separator presence instead.
    //
    // An interpreter's -c/-e/-Command body arrives as ONE argv token holding
    // a full nested command line, not a literal path — treating it as a
    // bare-path candidate here would misread a proven-safe read as a write
    // before Tier 2's own interpreter-body gate ever runs.
    //
    // The deferral must be per TOKEN, not per SEGMENT: keying on a
    // segment-wide interpreter regex used to suppress classification of
    // every argv token in the segment, letting a protected path in a
    // sibling operand slip through (`sh -c 'rm "$1"' _ <marker>`). Only a
    // token that IS one of the extracted bodies may defer; membership stays
    // keyed on the cooked token only, since this set is consumed in the
    // PERMISSION direction (widening it would widen what reaches Tier 2).
    const isInterpreterBody = interpreterBodies.has(a);
    // Both spellings are classified — they only differ under quoting or
    // ANSI-C escapes, where they are genuinely different candidate filenames.
    for (const sp of aRaw !== null && aRaw !== a ? [a, aRaw] : [a]) {
      if (isInterpreterBody) continue;
      // DIRECTION DISCIPLINE: the write-target and word-split readings below
      // are ADDITIVE, not mutually exclusive. Picking only one based on
      // whether the token contains `/` used to drop the workflow-dir /
      // dynamic-target reading for any whitespace-bearing token without a
      // `/` (`touch "$(printf '%s%s' s1.workflow -off)"`) — a fail-open loss
      // of a candidate reading. Every token now gets both classifications; a
      // denylist may only gain readings, never lose one.
      const kind = classifyBashWriteTarget(sp, assignText, ctx);
      if (kind) return kind;
      if (/\s/.test(sp)) {
        // A whitespace-bearing argv token can be an entire command line
        // (`eval`, `xargs -I{} sh -c …`, `find -exec sh -c …`, `ssh host …`)
        // that the separator gate above reads as one non-matching path.
        // Split into words and classify each — over-detection is correct
        // for a denylist.
        for (const word of sp.split(/\s+/)) {
          const wordKind = classifyProtectedBashToken(word);
          if (wordKind) return wordKind;
        }
      }
    }
    // VAR_REF_RE matches only the unquoted (cooked) spelling; the raw
    // spelling is tried second for tokens the tokenizer rewrote rather than
    // merely unquoted.
    const vm = VAR_REF_RE.exec(a) || (aRaw !== null && aRaw !== a ? VAR_REF_RE.exec(aRaw) : null);
    if (vm && assignText) {
      const varName = vm[1] || vm[2];
      // `$env:` is one more valid prefix before `NAME=` (pwsh's assignment
      // form) alongside start/whitespace/`;`/`&`/`|`.
      const assignRe = new RegExp("(?:^|[\\s;&|]|\\$" + PWSH_ENV_PREFIX + ")" + varName + "=(\\S+)", "m");
      const am = assignRe.exec(assignText);
      if (am && mentionsProtectedName(am[1])) {
        return TOKEN_MENTION_RE.test(am[1]) ? "token" : "marker";
      }
    }
  }
  return null;
}

module.exports = {
  READ_ONLY_ARG_COMMAND_RE,
  LESS_LOG_OPT_RE,
  readOnlyInvocation,
  VAR_REF_RE,
  segmentArgvHitsProtectedArg,
};
