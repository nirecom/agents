// hooks/block-clearance-token-write/bash-target-context/classify.js
// classifyBashWriteTarget() — the single decision point every Bash write-target
// call site in ../bash-scan.js routes through, plus the directory-containment
// resolvers it is built on. Split out of bash-target-context.js under the
// file-split HARD limit (rules/coding/file-split.md); see
// ../bash-target-context.js's header for the full N-1/N-2 bypass background,
// and ./cwd-tracking.js for the cwd-model half that feeds ctx.cwd into
// resolveAgainstCwd() below.
"use strict";

const path = require("path");
const {
  classifyProtectedPath,
  classifyProtectedBashToken,
  unquoteBashWord,
  mentionsProtectedName,
  TOKEN_MENTION_RE,
} = require("../../lib/protected-basenames");
const { hasGlobMetachar } = require("../../lib/basename-glob-normalize");
const { resolvesUnder } = require("../../lib/path-containment");
// The SAME static expander marker-gate.js and scope-checks.js already use for
// $HOME / ~ (CPR-2) — one spelling of "what does this directory resolve to".
const { expandStaticShellTokens } = require("../../lib/bash-write-targets/helpers");
const { substituteAssignments, EXPANSION_CHAR_RE } = require("./substitute");

// A `NAME=value` prefix on an argv token is an OPERAND, not a path component
// (`dd of=<wf>/s1*`). Stripped only for DIRECTORY extraction — the basename
// matchers already ignore it, since they read the tail.
const OPERAND_PREFIX_RE = /^[A-Za-z_][A-Za-z0-9_]*=/;
const WIN_ABS_RE = /^[A-Za-z]:[\\/]/;
const UNRESOLVABLE_DIR_RE = /[$`*?[\]]/;

// resolveWorkflowDir(): the SAME getWorkflowDir() the rest of the hook chain
// uses (CPR-2). Lazy-required and fail-soft: an unresolvable workflow dir
// simply disables the containment qualifier rather than blocking everything.
// The raw directory is returned; a lexical `startsWith` check was wrong here
// (misses symlinks, and misjudges case-insensitive volumes that aren't
// Windows) — resolution is delegated to resolvesUnder() instead.
function resolveWorkflowDir() {
  try {
    const { getWorkflowDir } = require("../../workflow-state");
    const dir = getWorkflowDir();
    return dir ? String(dir) : null;
  } catch (_e) {
    return null;
  }
}

// A Bash word can be read two ways; test both so neither spelling escapes.
function pathSpellings(rawText) {
  const unquoted = unquoteBashWord(rawText);
  const folded = String(rawText).replace(/\\/g, "/");
  return unquoted === folded ? [unquoted] : [unquoted, folded];
}

// resolveDirSpelling(dir, workflowDir): the directory a target's dirname
// actually names, with `~`, `$HOME`/`${HOME}` and `$CLAUDE_WORKFLOW_DIR`
// resolved. Returns the input unchanged when nothing could be resolved.
//
// DIRECTION DISCIPLINE: this resolver runs in the DETECTION direction — its
// only consumer asks "does this directory land inside the workflow dir?",
// where resolving one more spelling can only ADD a block, never clear one.
// The workflow dir's canonical spelling is `~/.claude/projects/workflow`, so
// bailing out on the first `$` or `~` used to let every natural spelling
// (`$HOME/…`, `${HOME}/…`, `~/…`, `$CLAUDE_WORKFLOW_DIR/…`) bypass a rule the
// literal spelling enforced. Bailing is now reserved for spellings that
// survive expansion.
const ENV_REF_RE = /\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)/g;
const WORKFLOW_DIR_ENV_NAME = "CLAUDE_WORKFLOW_DIR";

function resolveDirSpelling(dir, workflowDir) {
  if (typeof dir !== "string" || dir === "") return dir;
  let out = dir;
  if (out[0] === "~" || out.includes("$")) {
    try {
      const expanded = expandStaticShellTokens(out, { fromQuotedContext: "unquoted" });
      if (typeof expanded === "string" && expanded !== "") out = expanded;
    } catch (_e) { /* fail-soft: keep the literal spelling and let the caller decide */ }
  }
  // expandStaticShellTokens is scoped to $HOME / ~ / the plans dir, so the one
  // env var that NAMES this very directory is resolved here — from the resolved
  // workflow dir itself (CPR-2: getWorkflowDir is the SSOT), falling back to the
  // process environment for any other variable whose value is a plain path.
  if (out.includes("$")) {
    out = out.replace(ENV_REF_RE, (m, braced, bare) => {
      const name = braced || bare;
      const value = name === WORKFLOW_DIR_ENV_NAME
        ? (workflowDir || resolveWorkflowDir() || process.env[name])
        : process.env[name];
      if (typeof value !== "string" || value === "" || UNRESOLVABLE_DIR_RE.test(value)) return m;
      return value;
    });
  }
  return out;
}

// resolveAgainstCwd(p, ctx): `p` as an absolute path, or null when it cannot be
// made absolute (still dynamic, or relative with no known cwd). One spelling of
// the resolution step both qualifiers below need (CPR-2).
function resolveAgainstCwd(p, ctx, wfDir) {
  let out = resolveDirSpelling(p, wfDir);                // ~ / $HOME / $CLAUDE_WORKFLOW_DIR
  if (UNRESOLVABLE_DIR_RE.test(out)) return null;        // STILL dynamic or itself a glob
  if (!path.isAbsolute(out) && !WIN_ABS_RE.test(out)) {
    if (!ctx || !ctx.cwd) return null;                   // unresolvable → prior behavior
    out = path.resolve(ctx.cwd, out);
  }
  return out;
}

// A glob metachar is only one member of the class "the name the write lands
// on is NOT the name the hook can see". A residual expansion (`$(`, a
// backtick, or an unresolved `$`) is the stronger sibling: a glob can only
// match a file that already exists, while a substitution can CREATE the
// exact protected basename (CPR-4).
const RESIDUAL_EXPANSION_RE = /[$`]/;

// targetBaseInsideWorkflowDir(rawText, ctx, baseIsSuspect): true iff some
// spelling of the target has a basename `baseIsSuspect` rejects as statically
// resolvable AND a DIRECTORY that resolves at/under the workflow dir.
function targetBaseInsideWorkflowDir(rawText, ctx, baseIsSuspect) {
  if (typeof rawText !== "string" || rawText === "") return false;
  const wfDir = ctx && ctx.workflowDir;
  if (!wfDir) return false;
  for (const spelling of pathSpellings(rawText)) {
    const stripped = spelling.replace(OPERAND_PREFIX_RE, "");
    const cut = Math.max(stripped.lastIndexOf("/"), stripped.lastIndexOf("\\"));
    const base = cut === -1 ? stripped : stripped.slice(cut + 1);
    if (!baseIsSuspect(base)) continue;
    const dir = resolveAgainstCwd(cut === -1 ? "." : (stripped.slice(0, cut) || "/"), ctx, wfDir);
    if (dir === null) continue;
    // allowEqual: true — a target whose directory IS the workflow dir
    // (`<wf>/s1*`, `<wf>/s1.workflow$(…)`) is exactly the case this exists for.
    // onUnknown: true (codex scanner C) — this predicate ARMS a block; an
    // unresolvable directory (e.g. a symlink chain crafted to make
    // realResolve() throw) must not be silently treated as "not contained".
    if (resolvesUnder(dir, wfDir, { allowEqual: true, onUnknown: true })) return true;
  }
  return false;
}

// globTargetInsideWorkflowDir(rawText, ctx): true iff the target's BASENAME
// carries a glob metachar AND its DIRECTORY resolves at/under the workflow dir.
function globTargetInsideWorkflowDir(rawText, ctx) {
  return targetBaseInsideWorkflowDir(rawText, ctx, hasGlobMetachar);
}

// dynamicTargetInsideWorkflowDir(rawText, ctx): the sibling for the OTHER member
// of the class — a basename carrying a residual expansion.
function dynamicTargetInsideWorkflowDir(rawText, ctx) {
  return targetBaseInsideWorkflowDir(rawText, ctx, (base) => RESIDUAL_EXPANSION_RE.test(base));
}

// textNamesPathInsideWorkflowDir(text, ctx): a path-like fragment ANYWHERE in
// the text — including inside a substitution BODY — that resolves at/under
// the workflow dir. This is the third evidence source, and the only one that
// survives a target assembled INSIDE the substitution (no usable dirname to
// extract, but the workflow directory is still spelled out in plain text).
// Consulted only when the target carries residual indirection, so a fully
// static write keeps its existing verdict.
const PATH_FRAGMENT_RE = /[^\s'"`$(){}[\],;|&<>]*[\\/][^\s'"`$(){}[\],;|&<>]*/g;

function textNamesPathInsideWorkflowDir(text, ctx) {
  const wfDir = ctx && ctx.workflowDir;
  if (!wfDir || typeof text !== "string" || text === "") return false;
  const fragments = text.match(PATH_FRAGMENT_RE);
  if (!fragments) return false;
  for (const fragment of fragments) {
    const stripped = fragment.replace(OPERAND_PREFIX_RE, "");
    if (stripped === "" || stripped === "/" || stripped === "\\") continue;
    const resolved = resolveAgainstCwd(stripped, ctx, wfDir);
    if (resolved === null) continue;
    // onUnknown: true — same detection-direction reasoning as above.
    if (resolvesUnder(resolved, wfDir, { allowEqual: true, onUnknown: true })) return true;
  }
  return false;
}

function literalKind(text) {
  return classifyProtectedBashToken(text) || classifyProtectedPath(text);
}

// classifyBashWriteTarget(raw, assignText, ctx): "token" | "marker" |
// "workflow-glob" | "workflow-dynamic" | null — the single decision point every
// Bash write-target call site in ../bash-scan.js routes through.
function classifyBashWriteTarget(raw, assignText, ctx) {
  if (typeof raw !== "string" || raw === "") return null;
  const direct = literalKind(raw);
  if (direct) return direct;
  if (globTargetInsideWorkflowDir(raw, ctx)) return "workflow-glob";
  if (!EXPANSION_CHAR_RE.test(raw)) return null;
  const sub = substituteAssignments(raw, assignText);
  if (sub.substituted) {
    const kind = literalKind(sub.text);
    if (kind) return kind;
    if (globTargetInsideWorkflowDir(sub.text, ctx)) return "workflow-glob";
  }
  // Everything below is the RESIDUAL-INDIRECTION clause: the scanner could not
  // finish resolving this target, so it decides on EVIDENCE instead. Blanket
  // fail-closed is not acceptable here — `> $LOG`, `> "$(mktemp)"` etc. are
  // ordinary idioms — so each evidence source must name the workflow dir or a
  // protected file.
  if (!sub.unresolved) return null;

  // The mention check covers all three texts in scope: the assignment chain,
  // the raw target, and its partially-substituted form all carry the same
  // kind of evidence (CPR-5).
  for (const evidence of [assignText, raw, sub.text]) {
    if (mentionsProtectedName(evidence)) {
      return TOKEN_MENTION_RE.test(evidence) ? "token" : "marker";
    }
  }

  // (b) the basename is not statically resolvable and its directory is the
  // workflow dir; (c) the text names a path under the workflow dir anywhere,
  // including inside the substitution body that assembles the target.
  //
  // Named exception (CPR-8): a target assembled ENTIRELY inside a
  // substitution that references neither the workflow dir nor any protected
  // fragment (e.g. reconstructed from pieces, or decoded) leaves no evidence
  // here and is still approved. The backstop for that case is the
  // substitution-body re-scan in ../bash-scan.js and the Phase2 human
  // approval prompt, not this clause.
  if (dynamicTargetInsideWorkflowDir(raw, ctx) ||
      dynamicTargetInsideWorkflowDir(sub.text, ctx) ||
      textNamesPathInsideWorkflowDir(raw, ctx) ||
      textNamesPathInsideWorkflowDir(sub.text, ctx)) {
    return "workflow-dynamic";
  }
  return null;
}

module.exports = {
  resolveWorkflowDir,
  resolveDirSpelling,
  WIN_ABS_RE,
  globTargetInsideWorkflowDir,
  dynamicTargetInsideWorkflowDir,
  textNamesPathInsideWorkflowDir,
  classifyBashWriteTarget,
};
