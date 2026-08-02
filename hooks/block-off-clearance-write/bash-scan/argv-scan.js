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
// H-4 (#1780 round-4): `$ENV:` is the same scope prefix as `$env:` in
// PowerShell — this file's pwsh-assignment recognizers must fold it exactly as
// interpreter-scan.js does, or one scanner sanctions a spelling the other
// treats as unknown (CPR-5).
const { PWSH_ENV_PREFIX } = require("../../lib/case-insensitive-literal");

// H3 (security-scanner round 5): SHELL_CONFIG_VERB_SET's per-verb extractors
// (redirect/tee/pwsh/cp/mv) do not model every command that can create or
// mutate an arbitrary file. `ln -s <anything> <token>` forges the token via a
// symlink with no interpreter or redirect involved at all — the highest-
// severity gap, since it needs no write permission on the eventual read
// target, only on the token path. `sed -i`, `install`, `dd of=`, `truncate`,
// and `touch` similarly mutate or recreate a named file without ever being a
// "redirect". Rather than adding a dedicated extractor per verb (which would
// also change enforce-worktree.js's blast radius, since bash-write-targets.js
// is shared), this closes the class generically at the protected-path level: a
// segment whose argv carries a bare protected basename argument is a hit unless
// its effective command is a known plain-read command. Fail-closed: an
// unrecognized command naming a protected path on its argv is always a hit.
const READ_ONLY_ARG_COMMAND_RE = /^(?:cat|type|ls|dir|head|tail|wc|file|stat|readlink|less|more|findstr|grep|rg)(?:\.exe)?$/i;

// codex round-5 HIGH: membership above is granted to a COMMAND NAME, but
// read-only-ness is a property of the command AND its arguments. `less` breaks
// that assumption: `less -o FILE` / `-O FILE` / `--log-file=FILE` opens an
// input log and CREATES the named file — a literal, unobfuscated route to
// forging a marker through an "allowlisted reader".
//
// The rest of the allowlist was swept for the same class (any option that
// writes, logs, or edits in place). cat / type / ls / dir / head / tail / wc /
// file / stat / readlink / more / findstr / grep / rg all emit to stdout only;
// none has an output-file, log-file, or in-place-edit option. (Redirection of
// that stdout is a separate concern, already covered by the redirect
// extractor.) Re-run this sweep before adding any member — treat the allowlist
// as a class, not a list (CPR-4).
const LESS_LOG_OPT_RE = /^(?:-o(?![-\s])|--log-file(?:=|$))/i;

function readOnlyInvocation(cmdBase, argv) {
  if (!READ_ONLY_ARG_COMMAND_RE.test(cmdBase)) return false;
  if (/^less(?:\.exe)?$/i.test(cmdBase)) {
    return !argv.some((a) => typeof a === "string" && LESS_LOG_OPT_RE.test(a));
  }
  return true;
}

// supervisor-audit-5 item 3: `export A=<token>; ln -s /tmp/x $A` is already
// blocked, because `export`'s own argv literally carries "A=<token>" and
// classifyProtectedPath() matches its basename tail. But a preceding PLAIN
// (non-export) assignment segment — `A=<token>; ln -s /tmp/x $A` — sets a shell
// variable too (export is not required for a variable to be visible to a later
// command in the same shell), and `$A` in the ln segment's argv never
// spells the token out literally, so the bare-path check above misses
// it. Resolve `$NAME` / `${NAME}` / pwsh `$env:NAME` argv tokens against
// the contiguous run of plain-assignment segments immediately preceding
// this one (same chain bashHitsProtected already builds for the interpreter
// gate) and fail closed when the assignment names a protected path.
const VAR_REF_RE = new RegExp(String.raw`^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$|^\$${PWSH_ENV_PREFIX}([A-Za-z_][A-Za-z0-9_]*)$`);

// segmentArgvHitsProtectedArg(seg, precedingAssignText, ctx):
//   "token" | "marker" | "workflow-glob" | "workflow-dynamic" | null.
// `ctx` ({ workflowDir, cwd }) is optional — without it the workflow-dir glob
// qualifier simply does not fire, and the escape / quoting / assignment-splice
// normalization still applies.
function segmentArgvHitsProtectedArg(seg, precedingAssignText, ctx) {
  const eff = resolveEffectiveSegment(seg);
  if (!eff || !eff.cmd0) return null;

  // #1780 round-5 HIGH-1 (part 2, CPR-4): cmd0 gets the SAME protected-name
  // classification argv gets. Position zero was the one place a protected
  // basename could sit unexamined, and that is precisely where a mis-parsed
  // redirect operator deposits the real write target (`echo x >| s1.<marker>`
  // used to parse as a second segment whose cmd0 IS the marker). Beyond that
  // one bug it is the general defence: any future tokenizer gap that shifts a
  // target into command position now fails closed instead of silently passing.
  const cmd0Kind =
    classifyProtectedBashToken(seg && seg.cmd0Raw ? seg.cmd0Raw : eff.cmd0) ||
    classifyProtectedBashToken(eff.cmd0);
  if (cmd0Kind) return cmd0Kind;

  const cmdBase = path.basename(String(eff.cmd0).replace(/\\/g, "/")).toLowerCase();
  const argv = Array.isArray(eff.argv) ? eff.argv : [];
  // #1780 round-10 HIGH-2: the RAW spelling, index-aligned to eff.argv.
  //
  // cmd0 (above) and redirect targets (redirectRawTargetsHitProtected) already
  // classify the raw text the user typed; the argv loop was the one call site
  // still reading the COOKED token, so `touch $'<wf>/s1.workflow-of\x66'` was
  // measured ALLOW while the byte-identical `>` redirect form BLOCKed — an
  // asymmetry (CPR-5), and one the ANSI-C decoder in ../../lib/protected-basenames.js
  // exists precisely to close.
  //
  // resolveEffectiveSegment() strips a PREFIX of tokens (env assignments,
  // control keywords) but does not maintain argvRaw while doing so, so eff.argvRaw
  // is stale. eff.argv is however always a contiguous SUFFIX of seg.argv, and
  // seg.argvRaw is index-aligned with seg.argv — hence the offset. Any shape that
  // breaks that invariant disables the raw reading (offset < 0) and the loop
  // degrades to exactly its previous cooked-only behaviour rather than
  // mis-pairing two tokens.
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
  // classification), so it must see BOTH spellings: a `less -o FILE` whose flag
  // is spelled `$'\x2do'` is not read-only either. Passing the union can only
  // make the predicate answer false — the fail-closed direction.
  const argvBothSpellings = argv.concat(segArgvRaw.filter((r) => typeof r === "string"));
  if (readOnlyInvocation(cmdBase, argvBothSpellings)) return null;
  const assignText = typeof precedingAssignText === "string" ? precedingAssignText : "";
  // The bodies Tier 2 will actually judge, so the RD3 deferral below can be
  // limited to exactly those tokens (round 8 — see the comment there).
  //
  // DIRECTION DISCIPLINE (round 9 HIGH-1 — this is the same defect the
  // "DIRECTION DISCIPLINE" block in ../interpreter-scan.js names, hit from a
  // third side). This SET is consumed in the PERMISSION direction: membership
  // SKIPS bare-path classification and hands the token to Tier 2. It is built
  // from extractAllInterpreterBodies(), whose flag regex is deliberately WIDE
  // (FLAG_ALTS, an EXTRACTION alternation) and — crucially — does not require an
  // interpreter NAME anywhere in the segment, while Tier 2 only runs when
  // looksLikeInterpreterInvocation() says so. Round 8 wired the two together
  // without that gate, so any NON-interpreter command carrying a `-c`-cluster
  // flag got its next token swallowed by a deferral to a gate that then bailed,
  // and NOBODY judged it: `tar -cf '<marker>' /tmp/x`, `install … -c '<marker>'`,
  // `ar -rc`, `zip -c`, `cpio -oc`, `xz -c` and `find … -exec '<marker>' \;` were
  // all measured ALLOW — and `tar -cf` alone forges WORKFLOW_OFF/WORKTREE_OFF/
  // issue-close-verified, since hooks/lib/session-markers.js authorizes on file
  // EXISTENCE alone.
  //
  // The gate below is therefore mandatory and must stay paired with Tier 2's own
  // entry condition: defer ONLY to a judge that will actually run. Never derive
  // this set from FLAG_ALTS alone again.
  const segText = seg && typeof seg.rawText === "string" ? seg.rawText : "";
  const interpreterBodies = new Set(
    looksLikeInterpreterInvocation(segText) ? extractAllInterpreterBodies(segText).bodies : []
  );
  for (let ai = 0; ai < argv.length; ai++) {
    const a = argv[ai];
    if (typeof a !== "string") continue;
    const aRaw = rawArgvAt(ai);
    // F-2 (security-scanner round 6): the original gate skipped ANY argv
    // token containing whitespace, meant to exempt multi-word descriptive
    // arguments (`--detail "about sid.off-clearance"`) from being misread as
    // a write target. But post-tokenization, a genuine quoted path with a
    // spaced directory component (`'/w/My Dir/<sid>.off-clearance'` — real on
    // a Windows profile like `C:\Users\First Last\...`) is indistinguishable
    // from that descriptive text by whitespace alone — both are just one
    // argv token containing a space. Gate on path-separator presence
    // instead: a token with a `/` or `\` is a path candidate (spaces and
    // all), while pure free-text values normally contain no separator.
    //
    // RD3 (supervisor-audit-6): an interpreter's -c/-e/-Command flag body
    // arrives as ONE argv token holding a full nested command line, not a
    // literal path — `pwsh -Command "Get-Content -Raw '<token>'"` has the
    // whole read-only body as argv[1]. Its trailing `'<token>'` still looks
    // like a path (contains `/`), so treating it as a bare-path candidate
    // here misreads a proven-safe read as a write BEFORE Tier 2's
    // interpreter-body gate (hitsProtectedViaInterpreter) — which already
    // fail-closes on anything not an explicitly recognized read-only shape —
    // ever runs.
    //
    // Round 8: the deferral is per TOKEN, never per SEGMENT. It used to key on
    // `INTERPRETER_RE.test(seg.rawText)`, which suppressed classification of
    // EVERY argv token in the segment — including operands that are not bodies
    // at all — while Tier 2 only ever judges the extracted bodies. A protected
    // path parked in a sibling operand therefore fell between the two gates and
    // executed: `sh -c 'rm "$1"' _ <marker>`, `python3 -c 'os.remove(sys.argv[1])'
    // <marker>` and the perl/node/pwsh equivalents were all measured ALLOW.
    // INTERPRETER_RE is an EXTRACTION alternation (over-matching = read more
    // text = safe); using it as a PERMISSION predicate inverted that direction,
    // the same defect as round 8's proof-set bug in ../interpreter-scan.js. Only
    // a token that IS one of the extracted bodies may defer to the body gate.
    // Membership stays keyed on the COOKED token only: this set is consumed in
    // the PERMISSION direction, so adding the raw spelling to it would widen
    // what gets waved through to Tier 2 — the exact inversion the block comment
    // above warns about.
    const isInterpreterBody = interpreterBodies.has(a);
    // Both spellings are classified; they only differ when quoting or an ANSI-C
    // segment is in play, and then they are genuinely two different candidate
    // filenames. Over-detection is the correct direction here (denylist).
    for (const sp of aRaw !== null && aRaw !== a ? [a, aRaw] : [a]) {
      if (isInterpreterBody) continue;
      // #1780 round-11 CAUSE-1 — DIRECTION DISCIPLINE, fourth consecutive round
      // of the same defect (see the block above, and the block of the same name
      // in ../interpreter-scan.js). These two readings used to be MUTUALLY
      // EXCLUSIVE, selected by
      //     looksLikePath = /[\\/]/.test(sp) || !/\s/.test(sp)
      // so a token with interior whitespace and NO `/` took the word-split
      // branch ONLY, and classifyBashWriteTarget — the reading that carries the
      // workflow-dir / dynamic-target / unresolved-indirection qualifiers — was
      // never consulted for it. That is a classifier LOSING a candidate reading
      // in the DETECTION direction, which is always fail-open. Measured ALLOW:
      //
      //   cd <wf> && touch "$(printf '%s%s' s1.workflow -off)"
      //   cd <wf> && tee   "$(printf '%s%s' s1.workflow -off)" < /dev/null
      //   cd <wf> && touch "$(printf '%s%s' s1.off -clearance)"
      //   cd <wf> && touch "$(echo s1.workflow -off | tr -d ' ')"
      //
      // — while the byte-equivalent spelling with a `/` anywhere in the token
      // BLOCKed, purely because the `/` flipped the branch. The `printf` is
      // incidental: any command that assembles a name works (CPR-8), and
      // hooks/lib/session-markers.js authorizes on file EXISTENCE alone.
      //
      // The two readings are now ADDITIVE and unconditional: every token gets
      // the write-target classification, and every token that HOLDS whitespace
      // additionally gets word-split. Union of candidate readings is the
      // fail-closed direction for a denylist — a reading can only add a block,
      // never clear one — so no future edit may reintroduce an `else`.
      const kind = classifyBashWriteTarget(sp, assignText, ctx);
      if (kind) return kind;
      if (/\s/.test(sp)) {
        // #1780 round-5 HIGH-3 (part 2): a whitespace-bearing argv token is not
        // necessarily prose. For `eval`, `xargs -I{} sh -c …`, `find -exec sh -c
        // …`, `watch`, `ssh host …` and every other command whose ARGUMENT IS
        // COMMAND TEXT, it is an entire command line, and the separator gate
        // above reads it as one (non-matching) path. Split it into words and
        // classify each. This is a DENYLIST, so over-detection is the correct
        // direction to err; the WR15b control (`--detail "about the
        // off-clearance token feature"`) stays approved because a bare word
        // without the leading `.` is not a protected basename.
        for (const word of sp.split(/\s+/)) {
          const wordKind = classifyProtectedBashToken(word);
          if (wordKind) return wordKind;
        }
      }
    }
    // VAR_REF_RE is anchored on the WHOLE token, so it can only ever match the
    // unquoted (cooked) spelling — `"$A"` raw is not a bare variable reference.
    // The raw spelling is tried second for the shapes where the tokenizer
    // rewrote the token rather than merely unquoting it.
    const vm = VAR_REF_RE.exec(a) || (aRaw !== null && aRaw !== a ? VAR_REF_RE.exec(aRaw) : null);
    if (vm && assignText) {
      const varName = vm[1] || vm[2];
      // round-6 F-1 follow-up: `$env:` is one more valid prefix immediately
      // before `NAME=` (pwsh's own assignment form) alongside start/whitespace/
      // `;`/`&`/`|` — without it, a preceding `$env:A='<token>'` segment's
      // assignment is invisible to this lookup even though isAssignmentOnlySegment
      // (in ./assignment-text.js) now folds that segment's rawText into assignText.
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
