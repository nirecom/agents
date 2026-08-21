// hooks/lib/bash-write-patterns/dispatch-provenance.js
// #2064: derive dispatch provenance from an INTACT top-level IR, so that a
// downstream fragment re-parse (which has already lost quoted spans and heredoc
// bodies) can still tell that the whole command is a dispatcher / gh Group-A
// invocation. Two-value contract: { dispatchCleared: true } or null.
//
// Fail-closed: anything uncertain — parse failure, an empty IR, a lazy require
// that does not resolve — yields null (no provenance, current behavior kept).

const { GH_GROUP_A_REGEX, isKnownDispatchPath, resolveGhSegmentArgv, resolveGhSubArgv, isGitWriteIR } = require("./patterns");

const DISPATCH_SHELLS = new Set(["bash", "sh", "zsh", "dash"]);

// Shell options that carry no value. Anything else in option position is refused:
// a value-taking option puts an attacker-chosen path where the script token is
// read from (`bash --rcfile <dispatch> /tmp/evil.sh`), which would launder a
// non-dispatcher command into a cleared dispatch. Unknown options are refused
// too — guessing their arity is what creates the hole.
const SHELL_BOOLEAN_OPTS = new Set([
  "-e", "-u", "-x", "-v", "-n", "-f", "-h", "-k", "-p", "-t", "-B", "-C", "-E", "-H", "-P", "-T",
  "-l", "--login", "--posix", "--norc", "--noprofile", "--noediting", "--restricted", "--verbose", "--debug",
]);

// The script token is the first non-option token, but only when every token
// before it is a known boolean option (or the `--` terminator). Otherwise null.
function resolveShellScriptToken(argv) {
  if (!Array.isArray(argv)) return null;
  for (let i = 0; i < argv.length; i += 1) {
    const tok = argv[i];
    if (typeof tok !== "string" || tok.length === 0) return null;
    if (tok === "--") return typeof argv[i + 1] === "string" ? argv[i + 1] : null;
    if (tok[0] !== "-") return tok;
    if (!SHELL_BOOLEAN_OPTS.has(tok)) return null;
  }
  return null;
}

// Narrow IR write predicates live in bash-write-targets.js, which requires this
// module's siblings — take them via in-function lazy require to avoid a cycle.
function loadNarrowWritePredicates() {
  try {
    const T = require("../bash-write-targets");
    const { isPkgMgrWriteIR } = require("../bash-write-targets/pkg-mgr");
    const preds = [
      T.isPosixRedirWriteIR, T.isPwshWriteIR, T.isFileOpWriteIR, isGitWriteIR,
      isPkgMgrWriteIR, T.isInterpreterCWriteIR, T.isEncodedCommandWriteIR, T.isExtendedFileOpWriteIR,
      T.isExoticExecWriteIR,
    ];
    if (preds.some((f) => typeof f !== "function")) return null;
    // `isExoticExecWriteIR` self-derives provenance when ctx is undefined, which
    // would recurse back into this module. Pin an explicit ctx instead. The ctx
    // is `cleared` on purpose: layer 1 asks "setting the truncated-heredoc false
    // positive aside, does anything here actually write?", so an eval body that is
    // only a quoted `cat <<'EOF'` opener stays read while `eval 'touch f'` does not.
    const EXOTIC_CTX = { dispatchCleared: true };
    return preds.map((f) => (f === T.isExoticExecWriteIR ? (irArg) => f(irArg, EXOTIC_CTX) : f));
  } catch (e) {
    return null;
  }
}

/**
 * Returns "known-dispatch" | "gh-group-a" for a segment that invokes a known
 * dispatcher script or a gh Group-A coordination command, else null.
 * IR-token based — no new regex is applied to raw surface text.
 */
function segmentDispatchKind(seg) {
  try {
    if (!seg || typeof seg.cmd0 !== "string") return null;
    if (DISPATCH_SHELLS.has(seg.cmd0) && Array.isArray(seg.argv)) {
      const scriptTok = resolveShellScriptToken(seg.argv);
      if (scriptTok && isKnownDispatchPath(scriptTok)) return "known-dispatch";
    }
    const ghArgv = resolveGhSegmentArgv(seg);
    if (Array.isArray(ghArgv) && ghArgv.length > 0) {
      // Reuse GH_GROUP_A_REGEX purely as the Group-A verb vocabulary (SSOT in
      // patterns.js); WHICH tokens it sees is decided by the IR, not by surface text.
      const subArgv = resolveGhSubArgv(ghArgv);
      const normalized = ["gh", subArgv[0], subArgv[1]].filter((t) => typeof t === "string").join(" ");
      if (GH_GROUP_A_REGEX.test(normalized)) return "gh-group-a";
    }
    return null;
  } catch (e) {
    return null;
  }
}

// Command substitutions carry write commands that no segment-level predicate
// sees (`--title "$(rm -rf x)"`). Layer 1 must inspect them too, or provenance
// would clear a command that genuinely writes. Fail-closed on anything opaque.
function substHasNarrowWrite(seg, preds, depth) {
  if (depth > 4) return true;
  let extractCommandSubstitutions;
  let parse;
  try {
    ({ extractCommandSubstitutions } = require("../bash-write-targets"));
    ({ parse } = require("../command-ir"));
  } catch (e) {
    return true;
  }
  if (typeof extractCommandSubstitutions !== "function" || typeof parse !== "function") return true;
  const frags = [];
  if (Array.isArray(seg.argvRaw)) frags.push(...seg.argvRaw);
  if (seg.cmd0Raw) frags.push(seg.cmd0Raw);
  for (const frag of frags) {
    if (typeof frag !== "string" || frag.indexOf("$(") === -1 && frag.indexOf("`") === -1) continue;
    const { ok, subs } = extractCommandSubstitutions(frag);
    if (!ok) return true;
    for (const inner of subs) {
      if (!inner || !inner.trim()) continue;
      let innerIr;
      try { innerIr = parse(inner); } catch (e) { return true; }
      if (!innerIr || innerIr.parseFailure === true) return true;
      for (const pred of preds) {
        if (pred(innerIr)) return true;
      }
      for (const innerSeg of innerIr.segments || []) {
        if (substHasNarrowWrite(innerSeg, preds, depth + 1)) return true;
      }
    }
  }
  return false;
}

function segmentIr(seg) {
  return {
    rawText: seg.rawText, segments: [seg], parseFailure: false,
    cmd0: seg.cmd0, cmd0Raw: seg.cmd0Raw || "", argv: seg.argv, argvRaw: seg.argvRaw || [],
    redirects: seg.redirects, kind: seg.kind, separators: [],
  };
}

/**
 * Layer 1. { dispatchCleared: true } only when (1) the IR is intact and
 * non-empty, (2) at least one segment is a dispatcher / gh Group-A invocation,
 * and (3) NO segment trips any narrow IR write predicate. Condition 3 is what
 * stops `bash <dispatch> … && rm -rf repo` from ever raising provenance.
 */
function deriveDispatchProvenance(ir) {
  try {
    if (!ir || ir.parseFailure === true) return null;
    if (!Array.isArray(ir.segments) || ir.segments.length === 0) return null;
    const preds = loadNarrowWritePredicates();
    if (!preds) return null;
    let sawDispatch = false;
    for (const seg of ir.segments) {
      if (!seg) return null;
      if (segmentDispatchKind(seg) !== null) sawDispatch = true;
      const segIr = segmentIr(seg);
      for (const pred of preds) {
        if (pred(segIr)) return null;
      }
      if (substHasNarrowWrite(seg, preds, 0)) return null;
    }
    return sawDispatch ? { dispatchCleared: true } : null;
  } catch (e) {
    return null;
  }
}

module.exports = { segmentDispatchKind, deriveDispatchProvenance };
