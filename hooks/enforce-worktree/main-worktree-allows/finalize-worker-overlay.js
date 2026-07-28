"use strict";
// hooks/enforce-worktree/main-worktree-allows/finalize-worker-overlay.js
// Sole HARD gate for env VALUES and path/enum ARGUMENTS of the finalize-worker
// scripts: their internal fs.writeFileSync calls are invisible to
// collectBashWriteTargets' outer-redirect-only scan, so identity alone is not
// enough — env and args must be validated structurally here.
// G5_DECISION_VALUES must be kept in sync with run-loop-step.js's accepted
// decision values in the same diff if they ever change.

const path = require("path");
const { normalizeCwd } = require("../../lib/path-normalize");
const { normalizeForCompare } = require("../git-repo-detection");
const { getWorkflowPlansDir } = require("../../lib/workflow-plans-dir");
const {
  rejectsUnsafeArgTail, rejectsUnsafeToken, tokenizeArgTail,
} = require("../arg-tail-guard");

// SSOT enum for the enum-g5 argSpec — mirrors run-loop-step.js's accepted decisions.
const G5_DECISION_VALUES = ["accept", "decline", "llm_declined", "recurse_done"];

// Value-level reject set, applied to EVERY argument this gate lets through.
//
// Whatever the overlay matches is handed back to bash as an `eval` string, and
// run-loop-step.js reflects its arguments into that stdout — so every byte of
// every argument is re-parsed by the shell a second time. Quoting inside the
// payload is therefore not protection: `"<plans>/a';gh issue close 999;'b"` is a
// path under the plans dir by every structural check and a command separator by
// the time bash reads it. Anything the shell acts on — separators, redirects,
// substitution introducers, quotes, globs, brace/tilde expansion, comment and
// history markers, whitespace and control characters — is refused outright.
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

// Per-script HARD-validation metadata. `rel` is the repo-relative script path;
// `matchable:false` entries are registry-known but never matched at top level
// (step-g5-loop.sh is a subprocess-only child of run-loop-step.js / run-initial.sh).
const FINALIZE_OVERLAY_REGISTRY = [
  {
    rel: "skills/issue-close-finalize/scripts/run-initial.sh",
    interpreter: "bash",
    requiredEnv: ["AGENTS_CONFIG_DIR", "FINALIZE_SCRIPTS_DIR", "MAIN_WORKTREE_PATH"],
    argCountMin: 2,
    argCountMax: 3,
    argSpec: ["id", "id", "repo-slug"],
    matchable: true,
  },
  {
    rel: "skills/issue-close-finalize/scripts/run-loop-step.js",
    interpreter: "node",
    requiredEnv: ["AGENTS_CONFIG_DIR", "FINALIZE_SCRIPTS_DIR"],
    argCountMin: 2,
    argCountMax: 2,
    argSpec: ["path-plansdir", "enum-g5"],
    matchable: true,
  },
  {
    rel: "skills/issue-close-finalize/scripts/run-finalize-terminal.sh",
    interpreter: "bash",
    requiredEnv: ["AGENTS_CONFIG_DIR"],
    argCountMin: 3,
    argCountMax: 3,
    argSpec: ["path-plansdir", "id", "path-plansdir"],
    matchable: true,
  },
  {
    rel: "skills/issue-close-finalize/scripts/step-g5-loop.sh",
    interpreter: "bash",
    requiredEnv: ["AGENTS_CONFIG_DIR"],
    argCountMin: 2,
    argCountMax: 3,
    argSpec: ["id", "id", "id"],
    matchable: false,
  },
];

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
    // is safe on its own terms, not only behind matchFinalizeWorkerOverlay.
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

// True when the hook process's own AGENTS_CONFIG_DIR env var agrees with the
// marker-validated anchor (normLower'd). Fail-closed when env is absent or
// disagrees — keeps the $AGENTS_CONFIG_DIR literal-prefix resolution safe.
function acdEnvAgreesWithAnchor(anchorAcd) {
  const envAcd = process.env.AGENTS_CONFIG_DIR;
  if (!envAcd) return false;
  try {
    return normLower(envAcd) === anchorAcd;
  } catch (_) {
    return false;
  }
}

// Resolve a `$AGENTS_CONFIG_DIR/...` or `${AGENTS_CONFIG_DIR}/...` literal prefix
// in `literal` to the actual acd path. Returns the resolved string, the original
// `literal` unchanged (when no ACD prefix), or null (env-anchor mismatch → fail
// closed). Bare `$` / backtick / `~` that are NOT an ACD prefix are left in place
// so the caller's remaining `[$`~]` check still fires on them.
function resolveAcdPrefix(literal, acd) {
  if (typeof literal !== "string" || typeof acd !== "string") return null;
  const hasBrace = literal.startsWith("${AGENTS_CONFIG_DIR}");
  const hasPlain = !hasBrace && literal.startsWith("$AGENTS_CONFIG_DIR");
  if (!hasBrace && !hasPlain) return literal; // no ACD prefix — return as-is
  if (!acdEnvAgreesWithAnchor(normLower(acd))) return null;
  const prefixLen = hasBrace ? "${AGENTS_CONFIG_DIR}".length : "$AGENTS_CONFIG_DIR".length;
  return acd + literal.slice(prefixLen);
}

/**
 * HARD-validate a single-line finalize-worker `eval` invocation. Returns
 * { scriptPath: <normalized> } on a full pass, or null on any rejection
 * (fail-closed). The caller then defers only to the shared write-scope tail.
 */
function matchFinalizeWorkerOverlay(cmd, acd, repoRoot) {
  if (!cmd || typeof cmd !== "string") return null;
  if (!acd) return null;
  if (cmd.includes("\n") || cmd.includes("\r")) return null;

  // Outer wrapper: eval "$(...)" with an optional `|| exit 0` tail and nothing else.
  const mOuter = cmd.match(/^\s*eval\s+"\$\((.+)\)"\s*(?:2>&1\s*)?(?:\|\|\s*exit\s+0\s*)?$/);
  if (!mOuter) return null;
  const inner = mOuter[1];

  // Inner: (env KEY="VALUE" span) (bash|node) "script-path-literal" (arg tail).
  const mInner = inner.match(
    /^\s*((?:[A-Za-z_][A-Za-z0-9_]*="[^"]*"\s+)*)(bash|node)\s+"([^"]+)"\s*([\s\S]*)$/
  );
  if (!mInner) return null;
  const envSpan = mInner[1] || "";
  const interpreter = mInner[2];
  const scriptLiteral = mInner[3];
  const argTail = (mInner[4] || "").trim();

  // Script path: resolve $AGENTS_CONFIG_DIR literal prefix when the hook's own
  // env agrees with the anchor (#1679 S-7), then reject remaining indirection.
  const resolvedScriptLiteral = resolveAcdPrefix(scriptLiteral, acd);
  if (resolvedScriptLiteral === null) return null;
  if (/[$`~]/.test(resolvedScriptLiteral)) return null;

  let normScript;
  try {
    normScript = normLower(resolvedScriptLiteral);
  } catch (_) {
    return null;
  }

  // Anchor: the config dir the caller resolved (worker-script.js passes the
  // marker-validated resolveAgentsConfigDir() value — #1630 C4). The overlay
  // never resolves it itself; a single anchor per decision, resolved once.
  let anchorAcd;
  try {
    anchorAcd = normLower(acd);
  } catch (_) {
    return null;
  }
  if (!anchorAcd) return null;

  // Identity: which registry script is this, structurally? Derived by stripping
  // the entry's relative suffix off the invoked path — identification and
  // anchoring are separated (CPR-3) so the anchor comparison below is an
  // independent, individually load-bearing lock rather than a side effect of a
  // string join.
  let entry = null;
  let derivedAcd = null;
  for (const e of FINALIZE_OVERLAY_REGISTRY) {
    if (!e.matchable) continue;
    const d = stripRelSuffix(normScript, e.rel);
    if (d) {
      entry = e;
      derivedAcd = d;
      break;
    }
  }
  if (!entry) return null;

  // Cross-validation lock 1 of 2 (#1630 C5): the root implied by the script path
  // must BE the anchor. Fail-closed on an underivable root.
  if (derivedAcd === null) return null;
  if (derivedAcd !== anchorAcd) return null;

  // Interpreter binding — exact, case-sensitive.
  if (interpreter !== entry.interpreter) return null;

  // Env HARD gate: whitelist keys, no indirection in values, values match canonicals,
  // and the present key SET must exactly equal requiredEnv.
  const WHITELIST = new Set(["AGENTS_CONFIG_DIR", "FINALIZE_SCRIPTS_DIR", "MAIN_WORKTREE_PATH"]);
  const fsdNorm = normLower(path.join(acd, "skills", "issue-close-finalize", "scripts"));
  const rootNorm = normalizeForCompare(normalizeCwd(repoRoot) || repoRoot);
  const present = new Set();
  // anchorAcd / derivedAcd / payloadAcd all go through the SAME normLower — a
  // three-way comparison where one side used a different normalizer is the
  // classic path-confusion accident.
  let payloadAcd = null;
  const envRe = /([A-Za-z_][A-Za-z0-9_]*)="([^"]*)"/g;
  let em;
  while ((em = envRe.exec(envSpan)) !== null) {
    const key = em[1];
    const val = em[2];
    if (!WHITELIST.has(key)) return null;
    if (present.has(key)) return null; // duplicate key
    present.add(key);
    const resolvedVal = resolveAcdPrefix(val, acd);
    if (resolvedVal === null) return null;
    if (/[$`~]/.test(resolvedVal)) return null;
    if (key === "AGENTS_CONFIG_DIR") {
      payloadAcd = normLower(resolvedVal);
    } else if (key === "FINALIZE_SCRIPTS_DIR") {
      if (normLower(resolvedVal) !== fsdNorm) return null;
    } else if (key === "MAIN_WORKTREE_PATH") {
      const vNorm = normalizeForCompare(normalizeCwd(resolvedVal) || resolvedVal);
      if (!vNorm || !rootNorm || vNorm !== rootNorm) return null;
    }
  }
  if (present.size !== entry.requiredEnv.length) return null;
  for (const k of entry.requiredEnv) {
    if (!present.has(k)) return null;
  }

  // Cross-validation lock 2 of 2 (#1630 C5): the payload's own inline
  // AGENTS_CONFIG_DIR must agree with the anchor. Every registry entry lists
  // AGENTS_CONFIG_DIR in requiredEnv, so an unset payloadAcd here means the
  // value never parsed — fail-closed.
  if (!payloadAcd) return null;
  if (anchorAcd !== payloadAcd) return null;

  // Argument HARD gate: shape scan, count bound, per-position type validation.
  if (rejectsUnsafeArgTail(argTail, "overlay")) return null;
  const { tokens, ok } = tokenizeArgTail(argTail);
  if (!ok) return null;
  if (tokens.length < entry.argCountMin || tokens.length > entry.argCountMax) return null;
  for (let i = 0; i < tokens.length; i++) {
    const tok = tokens[i];
    // Structural and value-level checks run for EVERY token, before the spec
    // lookup. Ordering them after `if (spec === undefined) continue` made any
    // position past the end of argSpec accept an UNVALIDATED word — a trapdoor
    // that opens the moment an entry's argCountMax is widened (CPR-8).
    if (rejectsUnsafeToken(tok)) return null;
    if (!isSimpleArgValue(tok)) return null;
    const spec = entry.argSpec[i];
    // No declared spec: the universal checks above are all this position gets,
    // and that is deliberate — the entry table below also forbids the situation.
    if (spec === undefined) continue;
    if (spec === "id") {
      if (!ID_VALUE_RE.test(tok.value)) return null;
    } else if (spec === "enum-g5") {
      if (!G5_DECISION_VALUES.includes(tok.value)) return null;
    } else if (spec === "path-plansdir") {
      if (!isUnderPlansDir(tok.value)) return null;
    } else if (spec === "repo-slug") {
      if (!REPO_SLUG_VALUE_RE.test(tok.value)) return null;
      const slugParts = tok.value === "" ? [] : tok.value.split("/");
      if (slugParts.length > 2) return null; // belt-and-suspenders (regex already prevents)
      if (slugParts.some((p) => p === "." || p === "..")) return null;
    } else {
      return null; // unknown spec → fail-closed
    }
  }

  return { scriptPath: normScript };
}

module.exports = {
  FINALIZE_OVERLAY_REGISTRY,
  G5_DECISION_VALUES,
  matchFinalizeWorkerOverlay,
  stripRelSuffix,
};
