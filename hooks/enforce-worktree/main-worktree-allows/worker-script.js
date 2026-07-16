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

/**
 * True when cmd is a sanctioned worker-script invocation whose write targets
 * (log redirects etc.) all resolve inside registered linked worktrees of repoRoot.
 *
 * Identity: bash "<AGENTS_CONFIG_DIR>/bin/<sanctioned-script>" — double-quote only.
 * Write targets: extracted via collectBashWriteTargets(); all must land in a
 * registered linked worktree (git -C repoRoot worktree list --porcelain).
 * Fail-closed: any parse failure, spawnSync error, or main-worktree target → false.
 */
function isAllowedWorkerScriptInvocation(cmd, repoRoot) {
  if (!cmd || typeof cmd !== "string") return false;
  const acd = (process.env.AGENTS_CONFIG_DIR || "").trim();
  if (!acd) return false;
  if (!repoRoot) return false;

  // (a) Identity: bash "<sanctioned-script-path>" [args...]
  const m = cmd.match(/^\s*bash\s+"([^"]+)"(\s[\s\S]*)?$/);
  if (!m) return false;
  const scriptPath = m[1];
  const argTail    = m[2] || "";

  const SANCTIONED = [
    "bin/check-unstaged-tracked.sh",
    "bin/probe-remote-bootstrap.sh",
    "bin/issue-close-gate.sh",
    "bin/github-issues/issue-close-stage-triage.sh",
    "bin/github-issues/parent-body-update.sh",
  ];

  let normScript;
  try {
    normScript = path.resolve(normalizeCwd(scriptPath) || scriptPath).toLowerCase();
  } catch (e) { return false; }

  const matched = SANCTIONED.some((rel) => {
    try {
      const expected = path.join(acd, rel);
      const norm = path.resolve(normalizeCwd(expected) || expected).toLowerCase();
      return normScript === norm;
    } catch (e) { return false; }
  });
  if (!matched) return false;

  // (b) Structural argTail scan — reject chaining/substitution but allow redirects
  if (/\|\||&&|;|\$\(|`|<\(|>\(|\n/.test(argTail)) return false;
  // Reject bare & (background operator): `cmd & evil` runs evil in main worktree.
  // &> / &>> (redirect-both forms) are exempt — their & is followed by >.
  if (/&(?!>)/.test(argTail)) return false;

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

module.exports = { isAllowedWorkerScriptInvocation };
