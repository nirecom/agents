"use strict";
// hooks/enforce-worktree/main-worktree-allows/new-item.js
// Allow predicate for PowerShell New-Item / ni commands that create directories
// outside the session repo root (#1290, #1441).
//
// Contract: isAllowedNewItemCommand(head, repoRoot) → boolean
//   head     — the command string (already stripped of any trailing && cd … tail,
//              and passing the shared rejectInterpreterAndChaining / hasShellChaining
//              guards in the caller).
//   repoRoot — the resolved repo root string for the current CWD (may be null/undefined).
//
// Allow conditions (all required):
//   1. Token 0 of the command IS New-Item or ni (verified here — the predicate
//      does not rely on its caller's head-anchored dispatch; defense in depth).
//   2. -ItemType Directory (any casing) is present — -ItemType File → block.
//   3. A target path is extractable (fail-closed when absent).
//   4. The resolved path is OUTSIDE the repo root, OR under plans-dir, OR
//      under the session scratchpad allow root (lib/claude-scratchpad-base.js).
//
// PowerShell quote semantics: a SINGLE-quoted path is LITERAL — '$SCRATCHPAD/x'
// creates a directory literally named "$SCRATCHPAD" relative to the CWD. Env
// expansion is therefore applied ONLY to double-quoted and bare path tokens;
// single-quoted tokens containing `$` fail closed (they denote an in-CWD
// relative path the hook cannot vouch for).

const path = require("path");
const { isPathOutsideRepo } = require("../shared-cmd-utils");
const { findRepoRoot } = require("../git-repo-detection");
const { expandStaticShellTokens } = require("../../lib/bash-write-targets/helpers");
const { isAllowedScratchpadTarget } = require("../../lib/claude-scratchpad-base");

/**
 * True when head is a PowerShell New-Item / ni command that creates a directory
 * outside the session repo root (or under plans-dir / claude scratchpad).
 *
 * @param {string} head      - Command string (tail && cd stripped; chaining guards already applied).
 * @param {string} repoRoot  - Repo root for CWD (may be falsy for non-git CWD).
 * @returns {boolean}
 */
function isAllowedNewItemCommand(head, repoRoot) {
  // -ItemType Directory (any casing) required; anything else (File, etc.) → block (NI-5).
  if (!/\s-itemtype\s+directory\b/i.test(head)) return false;

  // Extract target path from -Path/-LiteralPath named flag or first positional arg.
  // Tokenize head into raw tokens (preserving quotes for later stripping).
  const rawTokens = [];
  const rawRe = /"([^"]*)"|'([^']*)'|(\S+)/g;
  let rm;
  while ((rm = rawRe.exec(head)) !== null) rawTokens.push(rm[0]);

  // argv0 verification (defense in depth): token 0 itself must be New-Item / ni —
  // the predicate must not rely on the caller's head-anchored dispatch.
  const argv0 = (rawTokens[0] || "").replace(/^["']|["']$/g, "");
  if (!/^(?:new-item|ni)$/i.test(argv0)) return false;

  // Skip the command head token (New-Item / ni) at index 0.
  let pathTok = null;
  let i = 1;
  while (i < rawTokens.length) {
    const tok = rawTokens[i];
    const tokLower = tok.replace(/^["']|["']$/g, "").toLowerCase();
    if (tokLower === "-path" || tokLower === "-literalpath") {
      // Named flag: next token is the value.
      if (i + 1 < rawTokens.length) {
        pathTok = rawTokens[i + 1];
      }
      break;
    }
    // Skip known value-consuming flags (-ItemType, -ErrorAction/-ea) and bare flags.
    if (/^-(?:itemtype|force|whatif|confirm|erroraction|ea)$/i.test(tokLower)) {
      if (/^-(?:itemtype|erroraction|ea)$/i.test(tokLower)) i++; // skip flag value
      i++;
      continue;
    }
    // First non-flag token after command head → positional path argument.
    if (!tok.startsWith("-")) {
      pathTok = tok;
      break;
    }
    i++;
  }

  if (!pathTok) return false; // no path found → fail-closed (NI-6)

  // Quote-type tracking (H1): in PowerShell a single-quoted string is LITERAL —
  // no env expansion happens. Only double-quoted and bare tokens are expandable.
  const isSingleQuoted = pathTok.startsWith("'");
  const rawPath = pathTok.replace(/^["']|["']$/g, "");

  if (isSingleQuoted) {
    // Literal semantics: a `$` here is a literal character, making the path a
    // relative in-CWD path (e.g. .\$SCRATCHPAD\x inside the repo) → fail-closed.
    if (rawPath.includes("$")) return false;
    // `~` is likewise treated literally (conservative: no expansion) — the path
    // falls through to the static outside-repo check below.
    return isPathOutsideRepo(rawPath, repoRoot);
  }

  // Env-var or tilde path (double-quoted or bare): expand, then check destination.
  if (rawPath.includes("$") || rawPath.includes("~")) {
    const expanded = expandStaticShellTokens(rawPath, { fromQuotedContext: "unquoted" });
    if (expanded === null) return false; // fail-closed: unresolvable $VAR

    // Allow if resolved under plans-dir.
    try {
      const { getWorkflowPlansDir } = require("../../lib/workflow-plans-dir");
      let plansDir;
      try { plansDir = getWorkflowPlansDir(); } catch (_) { plansDir = null; }
      if (plansDir) {
        const normP = path.resolve(plansDir).toLowerCase();
        const normE = path.resolve(expanded).toLowerCase();
        if (normE === normP || normE.startsWith(normP + path.sep) || normE.startsWith(normP + "/")) return true;
      }
    } catch (_) { /* fall through */ }

    // Allow if under the session scratchpad allow root AND outside every repo root
    // (F1: the outside-repo clause defends against a poisoned TEMP nesting the base in-repo).
    if (isAllowedScratchpadTarget(path.resolve(expanded), findRepoRoot)) return true;

    // Else: check if outside repo.
    return isPathOutsideRepo(expanded, repoRoot);
  }

  // Static path (no env-var/tilde): allow only when outside the repo (NI-1, NI-3).
  return isPathOutsideRepo(rawPath, repoRoot);
}

module.exports = { isAllowedNewItemCommand };
