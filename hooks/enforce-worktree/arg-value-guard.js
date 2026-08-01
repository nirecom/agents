"use strict";
// hooks/enforce-worktree/arg-value-guard.js
// Decision-layer argument VALUE safety, shared by every main-worktree-allows
// matcher that lets a caller-supplied word through (#1673).
//
// Sibling of arg-tail-guard.js, and the split between the two is the axis:
//   arg-tail-guard.js  — SHAPE of the whole tail and of each token (quoting,
//                        span structure, shell metacharacters by position)
//   arg-value-guard.js — VALUE of a single token once its shape is settled
//                        (reject set, identifier/slug shapes, plans-dir
//                        containment, path-suffix stripping)
//
// These helpers used to live in main-worktree-allows/finalize-worker-overlay.js,
// which #1673 deleted together with the Bash-tool `eval` path it guarded. They
// were moved here UNCHANGED so worker-dispatch-overlay.js — which outlived that
// file — keeps screening argument values against ONE reject set rather than two
// drifting copies (CPR-2). This module is now their sole owner.

const path = require("path");
const { normalizeCwd } = require("../lib/path-normalize");
const { normalizeForCompare } = require("./git-repo-detection");
const { getWorkflowPlansDir } = require("../lib/workflow-plans-dir");

// Value-level reject set, applied to EVERY argument a gate lets through.
//
// Whatever an overlay matches may be handed back to bash as an `eval` string,
// and a matched script can reflect its arguments into that stdout — so every
// byte of every argument can be re-parsed by the shell a second time. Quoting
// inside the payload is therefore not protection:
// `"<plans>/a';gh issue close 999;'b"` is a path under the plans dir by every
// structural check and a command separator by the time bash reads it. Anything
// the shell acts on — separators, redirects, substitution introducers, quotes,
// globs, brace/tilde expansion, comment and history markers, whitespace and
// control characters — is refused outright.
//
// `\` is deliberately ABSENT: it is a legitimate separator inside a Windows
// plans-dir path, and the argument is never re-quoted in a context where a lone
// backslash changes the word count.
const UNSAFE_ARG_VALUE_RE = /[\s'"`$;&|<>()[\]{}*?!#~]/;

// Control characters are checked by code point rather than by a regex range, so
// the intent survives every quoting layer this source passes through.
function hasControlChar(s) {
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c < 0x20 || c === 0x7f) return true;
  }
  return false;
}

// The `id` positions are opaque identifiers (issue numbers, session ids). Exact
// shape rather than "no metacharacters", so this validator is as strict as the
// enum one (CPR-5). The empty string is legal — run-initial.sh's third argument
// is a documented empty placeholder.
const ID_VALUE_RE = /^[A-Za-z0-9._-]*$/;

// owner/repo slug, bare repo name, or empty placeholder — all accepted for
// run-initial.sh arg3 (G2/G3 fix, #1679 S-6). Accepts:
//   ""            → empty placeholder (legacy current-repo form with 3 args)
//   "repo"        → bare repo name (current-repo form)
//   "owner/repo"  → cross-repo form (exactly one slash)
// `..` traversal rejected explicitly in the spec handler (CWE-22).
const REPO_SLUG_VALUE_RE = /^(?:[A-Za-z0-9._-]+(?:\/[A-Za-z0-9._-]+)?)?$/;

/**
 * True when `tok` is a single plain shell word whose value survives a second
 * round of shell parsing unchanged. Applied to every token regardless of
 * argSpec, so an argument position with no declared spec is still validated.
 *
 * `pieces.length === 1` is load-bearing on its own: `a"q"b` tokenizes to three
 * pieces and a CLEAN value of `aqb`, so a value-only check would accept it and
 * then re-emit a word carrying two live quote characters.
 */
function isSimpleArgValue(tok) {
  if (tok === null || typeof tok !== "object") return false;
  if (!Array.isArray(tok.pieces) || tok.pieces.length !== 1) return false;
  const kind = tok.pieces[0].kind;
  if (kind !== "unquoted" && kind !== "dq" && kind !== "sq") return false;
  if (typeof tok.value !== "string") return false;
  if (hasControlChar(tok.value)) return false;
  return !UNSAFE_ARG_VALUE_RE.test(tok.value);
}

// path.resolve + Windows-safe normalization + lowercase (identity-comparison form
// for script paths and env path values — matches worker-script.js's normScript).
function normLower(p) {
  return path.resolve(normalizeCwd(p) || p).toLowerCase();
}

// Separator semantics are PLATFORM-dependent, and the assumption is named here
// rather than branched implicitly at each split (CPR-8). On win32 both `/` and
// `\` delimit segments. On macOS/Linux `\` is an ordinary FILENAME character, so
// `/trusted/acd\skills/issue-close-finalize/...` is ONE directory literally named
// `acd\skills` — a name any writable directory can host. Treating it as a
// boundary would make stripRelSuffix report `/trusted/acd` as the implied root
// for a script that does not live under it, and the three-way cross-validation
// would then compare a trusted anchor against an untrusted script.
const IS_WIN32 = process.platform === "win32";
const ABS_SEP_RE = IS_WIN32 ? /[/\\]+/ : /\/+/;
const ABS_UNC_RE = IS_WIN32 ? /^[/\\]{2}/ : /^\/{2}/;
// `rel` is a repo-internal constant, always authored with `/`. Accepting `\` in
// it on every host is a spelling allowance for the registry, not a claim about
// the filesystem the invoked path came from.
const REL_SEP_RE = /[/\\]+/;

/**
 * Remove a registry entry's `/`-separated relative suffix from an absolute path
 * SEGMENT-wise and return the root it implies, normLower-ed. Returns null when
 * the path does not end with `rel` on segment boundaries (so `<root>/xskills/...`
 * and `<...>/run-initial.sh.bak` are refused, not silently trimmed).
 *
 * A character-count slice (`abs.slice(0, abs.length - rel.length)`) is forbidden:
 * `\` vs `/`, repeated separators and mixed separators all change the character
 * length of the suffix without changing its segment count.
 */
function stripRelSuffix(absPath, rel) {
  if (typeof absPath !== "string" || !absPath) return null;
  if (typeof rel !== "string" || !rel) return null;
  const relSegs = rel.split(REL_SEP_RE).filter((s) => s !== "");
  if (relSegs.length === 0) return null;
  const absSegs = absPath.split(ABS_SEP_RE);
  const k = relSegs.length;
  if (absSegs.length <= k) return null;
  // Case policy is normLower's: unconditional toLowerCase on both sides.
  for (let i = 0; i < k; i++) {
    const a = absSegs[absSegs.length - k + i];
    if (String(a).toLowerCase() !== relSegs[i].toLowerCase()) return null;
  }
  const rest = absSegs.slice(0, absSegs.length - k);

  // --- platform root reconstruction ---
  // path.join drops the root information that the split threw away, and each
  // root shape loses it differently: `path.join("c:", "git")` yields the
  // drive-RELATIVE `c:git`, and a leading empty segment (POSIX root `/x`, or a
  // UNC `//server/share`) simply disappears, turning an absolute path into a
  // cwd-relative one. Each shape is named explicitly here (CPR-8) rather than
  // left to path.join's defaults.
  let head = null;
  let tail = rest;
  if (rest.length > 0 && /^[a-zA-Z]:$/.test(rest[0])) {
    head = rest[0] + path.sep;              // drive root: c: -> c:\
    tail = rest.slice(1);
  } else if (rest.length > 0 && rest[0] === "") {
    // One leading separator run covers both POSIX root and UNC; only the raw
    // path text says which, so read the root marker from the original string.
    if (ABS_UNC_RE.test(absPath)) {
      // UNC root: the share root is `\\server\share`, and it must be handed to
      // path.join as ONE head — a bare `\\` head is normalized away, which would
      // demote the path to drive-relative on the next path.resolve.
      if (rest.length < 3) return null;   // `\\server` alone is not a valid root
      head = path.sep + path.sep + rest[1] + path.sep + rest[2];
      tail = rest.slice(3);
    } else {
      head = path.sep;                    // POSIX root: / -> path.sep
      tail = rest.slice(1);
    }
  }
  // --- end platform root reconstruction ---

  try {
    const joined = head === null ? path.join(...tail) : path.join(head, ...tail);
    return normLower(joined);
  } catch (_) {
    return null;
  }
}

// True when `token` resolves to a path genuinely inside the workflow plans dir.
// Uses path.resolve + separator-boundary containment (not naive string-prefix) so
// sibling-prefix lookalikes (<plans>-evil/...) and ..-traversal escapes are rejected.
function isUnderPlansDir(token) {
  try {
    // Same reject set the universal token gate uses (CPR-2) — so the predicate
    // is safe on its own terms, not only behind a matcher.
    if (typeof token !== "string") return false;
    if (hasControlChar(token) || UNSAFE_ARG_VALUE_RE.test(token)) return false;
    let plansDir;
    try {
      plansDir = getWorkflowPlansDir();
    } catch (_) {
      return false;
    }
    if (!plansDir) return false;
    const normPlans = normalizeForCompare(normalizeCwd(plansDir) || plansDir);
    const normTok = normalizeForCompare(normalizeCwd(token) || token);
    if (!normPlans || !normTok) return false;
    if (normTok === normPlans) return true;
    return normTok.startsWith(normPlans + path.sep) || normTok.startsWith(normPlans + "/");
  } catch (_) {
    return false;
  }
}

module.exports = {
  UNSAFE_ARG_VALUE_RE,
  ID_VALUE_RE,
  REPO_SLUG_VALUE_RE,
  hasControlChar,
  isSimpleArgValue,
  normLower,
  stripRelSuffix,
  isUnderPlansDir,
};
