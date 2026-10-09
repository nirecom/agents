"use strict";
// hooks/enforce-worktree/main-worktree-allows/worker-script.js
// isAllowedWorkerScriptInvocation — allow predicate for sanctioned worker-script
// invocations whose write targets all land in registered linked worktrees.
// Extracted from standard.js (file-split per rules/coding/file-split.md Pattern A).

const path = require("path");
const { spawnSync } = require("child_process");
const { normalizeCwd } = require("../../lib/path-normalize");
const { normalizeForCompare } = require("../git-repo-detection");
const { collectBashWriteTargets } = require("../bash-write-scope");
const { matchWorkerDispatchOverlay } = require("./worker-dispatch-overlay");
const { foldNewlinesInSpans } = require("../../lib/quote-spans");
const { resolveScriptCheckoutRoot } = require("../../lib/script-checkout-root");
const { rejectsUnsafeArgTail } = require("../arg-tail-guard");
const { splitShellCommands } = require("../../lib/shell-segments");
const { parse } = require("../../lib/command-ir");
const { detectWritePredicate } = require("../write-detector");

// Companion-segment env-mutation guard (#1679):
// Blocks companion segments whose cmd0 is a shell env-mutation keyword.
// Prevents a confused-deputy attack where a companion segment sets
// AGENTS_MAIN_ROOT=/evil before the sanctioned eval.
// Checked at cmd0 level (parsed IR) to avoid false positives on
// `echo "export ..."` where the keyword is an argument, not the command.
const ENV_MUTATION_CMDS = new Set([
  "export", "unset", "declare", "typeset", "readonly",
  "set", "source", "eval", "alias", "env",
]);
// Bare IDENT=value at cmd0 position signals an env-assignment segment.
const ASSIGN_RE = /^[A-Za-z_][A-Za-z0-9_]*=/;

// Sanctioned worker scripts. Any new worker script that must write inside a
// linked worktree must be listed here (SSOT for the legacy SANCTIONED path).
//
// Entry criterion: a prompt-facing step runs the script through the Bash TOOL
// from the main worktree. A script reachable only as a CHILD of another script
// never reaches this predicate — PreToolUse inspects the command head only — so
// listing it grants nothing and only widens the matchable surface (#1673).
// tests/hooks/fix-1600-sanctioned-coverage-audit.sh pins the surviving set.
const SANCTIONED = [
  "bin/check-unstaged-tracked.sh",
  "bin/probe-remote-bootstrap.sh",
  "bin/github-issues/issue-create-dispatch.sh",
  "skills/issue-create/scripts/run-bulk-dispatch.sh",
  "skills/issue-create/scripts/run-phase5-record.sh",
  "skills/issue-close-finalize/scripts/pre-flight.sh",
  "skills/review-code-security/scripts/run-quality-gates.sh",
];

/**
 * True when `seg` (a single split segment with no &&/||/; separators) matches
 * exactly one of the sanctioned worker-script invocation patterns.
 * Does NOT call writeTargetsAllInLinkedWorktrees — write-scope runs once on the
 * WHOLE command in the caller (CPR-SC: one scope check, not one per segment).
 */
function isSanctionedSingleInvocation(seg, repoRoot) {
  const SCRIPT_CHECKOUT_ROOT = resolveScriptCheckoutRoot();
  if (!SCRIPT_CHECKOUT_ROOT) return false;

  // (a0) Worker-dispatch overlay (#1643): the single plain-script dispatch entry
  // point. HARD-validates identity (Lock 1), the argv target-main-root against the repo
  // under judgement (Lock 2) and against the session's trusted anchor set (Lock 3),
  // plus worker enum and payload scope. The canonical form carries no redirect —
  // the overlay's own metacharacter screen refuses `>` outright — so there is no
  // write target left for the (c)/(d) tail to inspect.
  if (matchWorkerDispatchOverlay(seg, repoRoot) !== null) return true;

  // (a) Identity: eval "$(bash "<path>")" [2>&1] [|| exit 0]  (#1484)
  //           OR: bash "<path>" [args…]
  let scriptPath, argTail;
  const mEval = seg.match(
    /^\s*eval\s+"\$\(bash\s+"([^"]+)"\s*\)"\s*(?:2>&1\s*)?(?:\|\|\s*exit\s+0\s*)?\s*$/
  );
  if (mEval) {
    scriptPath = mEval[1];
    argTail = "";
    // A path that still carries an unexpanded variable is never rewritten here: the
    // shell expands it after this hook, so the file judged and the file run could
    // differ (#2561). It fails the SANCTIONED comparison below and is blocked.
  } else {
    const m = seg.match(/^\s*(?:[A-Za-z_][A-Za-z0-9_]*=[^\s'"]*\s+)*bash\s+"([^"]+)"(\s[\s\S]*)?$/);
    if (!m) return false;
    scriptPath = m[1];
    argTail = m[2] || "";
  }

  let normScript;
  try {
    normScript = path.resolve(normalizeCwd(scriptPath) || scriptPath).toLowerCase();
  } catch (e) { return false; }

  const matched = SANCTIONED.some((rel) => {
    try {
      const expected = path.join(SCRIPT_CHECKOUT_ROOT, rel);
      const norm = path.resolve(normalizeCwd(expected) || expected).toLowerCase();
      return normScript === norm;
    } catch (e) { return false; }
  });
  if (!matched) return false;

  // (b) Structural argTail scan — reject chaining/substitution but allow redirects.
  // A newline inside a DQ span is argument text, not a command separator, so it is
  // folded to a space first; every other newline still rejects the command.
  const folded = foldNewlinesInSpans(argTail, ["dq"]);
  if (folded.ok !== true) return false;
  if (rejectsUnsafeArgTail(folded.out, "worker-script")) return false;

  return true;
}

/**
 * True when `seg` is a safe companion segment (a &&/||/; neighbour of the
 * sanctioned eval): no writes to the filesystem, no mutation of shell/env state.
 * Fail-closed: any parse failure or unrecognized form → false.
 */
function isCompanionSafe(seg) {
  let ir;
  try { ir = parse(seg); } catch (_) { return false; }
  if (!ir || ir.parseFailure === true) return false;

  // Must not be a write operation (same gate the main hook uses at line 195).
  if (detectWritePredicate(ir) !== null) return false;

  // Must not mutate shell/env state. A companion like `export AGENTS_MAIN_ROOT=/evil`
  // or bare `AGENTS_MAIN_ROOT=/evil` is a confused-deputy attack vector.
  // Checked at cmd0 (parsed) to avoid FP on `echo "export ..."` (argument position).
  if (!ir.segments) return false;
  for (const s of ir.segments) {
    const cmd0 = s.cmd0 || "";
    if (ENV_MUTATION_CMDS.has(cmd0.toLowerCase())) return false;
    if (ASSIGN_RE.test(cmd0)) return false;
  }
  return true;
}

/**
 * True when cmd is a sanctioned worker-script invocation whose write targets
 * (log redirects etc.) all resolve inside registered linked worktrees of repoRoot.
 *
 * Identity: bash "<script checkout root>/bin/<sanctioned-script>" — double-quote only,
 * written as a literal path.
 * Fail-closed: any parse failure, spawnSync error, or main-worktree target → false.
 * Multi-segment commands (#1679) pass when exactly one segment is the sanctioned
 * invocation and every other one is companion-safe.
 */
function isAllowedWorkerScriptInvocation(cmd, repoRoot) {
  if (!cmd || typeof cmd !== "string") return false;
  // Marker-validated checkout of this hook (#1630): derived from the module's own
  // path, so no environment value can redirect it. null keeps the fail-closed contract.
  if (!resolveScriptCheckoutRoot()) return false;
  if (!repoRoot) return false;

  // Split by shell operators (&&/||/;) to detect companion segments.
  // Single-segment commands take the same path as before — no performance cost.
  const segs = splitShellCommands(cmd);
  if (segs.length === 0) return false;

  // Classify each segment: sanctioned invocation OR companion-safe bystander.
  // Invariant 1: exactly 1 sanctioned segment (0 = not authorized;
  //              2+ = confused-deputy risk, two evals could race or conflict).
  // Invariant 2: every non-sanctioned segment must be companion-safe.
  let sanctionedCount = 0;
  for (const seg of segs) {
    if (isSanctionedSingleInvocation(seg, repoRoot)) {
      sanctionedCount++;
    } else if (!isCompanionSafe(seg)) {
      return false;
    }
  }
  if (sanctionedCount !== 1) return false;

  // (c)/(d) Shared write-scope tail: all write targets in the WHOLE command must
  // land inside registered linked worktrees (never the main worktree).
  return writeTargetsAllInLinkedWorktrees(cmd, repoRoot);
}

// (c)/(d) Write-target scope tail: extract write targets and require every one to
// land inside a registered linked worktree of repoRoot (never the main worktree).
// Shared by the legacy SANCTIONED path and the worker-dispatch overlay.
function writeTargetsAllInLinkedWorktrees(cmd, repoRoot) {
  // (c) Extract write targets
  const { targets, parseFailure } = collectBashWriteTargets(cmd);
  if (parseFailure) return false;
  if (targets === null || targets.length === 0) return true; // no write targets → no main-wt write

  // (d) All targets must be inside registered linked worktrees (not repoRoot itself)
  try {
    const r = spawnSync("git", ["-C", repoRoot, "worktree", "list", "--porcelain"], {
      encoding: "utf8", timeout: 2000,
    });
    if (r.error || r.status !== 0) return false;

    const normRoot = normalizeForCompare(repoRoot);

    // Collect registered linked worktrees (exclude the main worktree = repoRoot)
    const linkedWts = [];
    for (const line of (r.stdout || "").split("\n")) {
      const match = line.match(/^worktree\s+(.+)$/);
      if (!match) continue;
      const wtNorm = normalizeForCompare(match[1].trim());
      if (!wtNorm || wtNorm === normRoot) continue; // skip main worktree
      linkedWts.push(wtNorm);
    }
    if (linkedWts.length === 0) return false; // no linked worktrees → fail-closed

    const sep = path.sep;
    for (const target of targets) {
      const rawTarget = String(target.path).replace(/^["']|["']$/g, ""); // strip surrounding quotes
      const tNorm = normalizeForCompare(rawTarget);
      if (!tNorm) return false;
      // Linked-worktree membership is decided FIRST: a registered linked
      // worktree may be nested under the main worktree tree (e.g. <root>/.wt/x),
      // in which case the target also starts with normRoot. Accepting it here
      // before the main-worktree-prefix reject avoids a false block.
      const inLinked = linkedWts.some((wt) =>
        tNorm === wt || tNorm.startsWith(wt + sep) || tNorm.startsWith(wt + "/")
      );
      if (inLinked) continue;
      // Not in any linked worktree → must be rejected (covers main-worktree
      // targets and any out-of-registry path). Fail-closed.
      return false;
    }
    return true;
  } catch (e) { return false; }
}

const VARIABLE_SCRIPT_PATH_RE = /\bbash\s+"(\$\{?[A-Za-z_][A-Za-z0-9_]*\}?)[\\/]([^"]+)"/;

/**
 * Block-message hint for a command that names a sanctioned script through an
 * unexpanded variable. "" when the command has no such path.
 */
function describeVariableScriptPath(cmd) {
  if (!cmd || typeof cmd !== "string") return "";
  const m = cmd.match(VARIABLE_SCRIPT_PATH_RE);
  if (!m) return "";
  const rel = m[2].replace(/\\/g, "/");
  if (!SANCTIONED.includes(rel)) return "";
  const root = resolveScriptCheckoutRoot();
  const literal = root ? path.join(root, rel).replace(/\\/g, "/") : `<absolute path>/${rel}`;
  return (
    `\nHint: ${rel} is allowed from the main worktree, but this command names it through ${m[1]}.\n` +
    "This hook reads the command before the shell expands variables, so it cannot confirm which file will run.\n" +
    `Write the path literally instead: bash "${literal}"`
  );
}

module.exports = { isAllowedWorkerScriptInvocation, describeVariableScriptPath };
