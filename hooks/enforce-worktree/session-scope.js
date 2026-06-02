"use strict";

const fs = require("fs");
const path = require("path");
const { resolveRepoRoot } = require("./git-repo-detection");

// Cache for payload-derived absolute paths for the CURRENT hook invocation.
// Populated once at the dispatch site by setPayloadDerivedPaths(); read by
// getSessionRepoRoots(). Implicitly reset per process (one invocation = one
// process). Issue #321 — payload-derived repo resolution.
let _payloadDerivedPaths = [];

function setPayloadDerivedPaths(paths) {
  _payloadDerivedPaths = (paths || []).filter(Boolean);
}

function _getPayloadDerivedPaths() { return _payloadDerivedPaths.slice(); }

// Returns the set of repo roots considered "in session scope" for gh write commands.
// Composition:
//   - process.cwd() repo root (always included if it resolves to a repo)
//   - Each path listed in ENFORCE_WORKTREE_EXTRA_REPOS (semicolon-separated)
// Behaviour:
//   - Whitespace around entries is trimmed; empty entries are skipped.
//   - Nonexistent paths are silently skipped (not an error).
//   - Paths are passed to git rev-parse via cwd — never to a shell — so
//     metacharacters in env values cannot be exec'd.
function getSessionRepoRoots() {
  const roots = new Set();
  const cwdRoot = resolveRepoRoot(process.cwd());
  if (cwdRoot) roots.add(cwdRoot);
  // Include payload-derived paths from the CURRENT hook invocation (issue #321).
  // Scope is limited to THIS command's explicitly named paths — we do NOT
  // enumerate all linked worktrees of cwdRoot (that would broaden the gh-write
  // guard beyond user intent).
  for (const p of _payloadDerivedPaths) {
    const r = resolveRepoRoot(p);
    if (r) roots.add(r);
  }
  const extra = (process.env.ENFORCE_WORKTREE_EXTRA_REPOS || "")
    .split(";").map((s) => s.trim()).filter(Boolean);
  for (const dir of extra) {
    let resolved;
    try { resolved = path.resolve(dir); } catch (e) { continue; }
    if (!fs.existsSync(resolved)) continue;
    const root = resolveRepoRoot(resolved);
    if (root) {
      roots.add(root);
    } else {
      // Not a git repo itself — scan immediate subdirectories (depth 1).
      try {
        for (const entry of fs.readdirSync(resolved, { withFileTypes: true })) {
          if (!entry.isDirectory()) continue;
          const sub = resolveRepoRoot(path.join(resolved, entry.name));
          if (sub) roots.add(sub);
        }
      } catch (e) { /* skip non-readable dirs */ }
    }
  }
  return roots;
}

module.exports = { setPayloadDerivedPaths, _getPayloadDerivedPaths, getSessionRepoRoots };
