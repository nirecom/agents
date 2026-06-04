"use strict";
// Staged-change evidence helpers: detect whether tests, docs, or any files are
// staged — provides the evidential basis for workflow step verification decisions.

const { execSync } = require("child_process");
const path = require("path");

// Evidence-based check: staged files contain tests/ changes.
//
// Symmetric-sibling note (#484): hasStagedDocChanges has a paired
// hasWorktreeNotesDocEvidence() that recognizes the WORKTREE_NOTES.md
// ## History Notes / ## Changelog Notes staging path introduced by #436.
// hasStagedTestChanges intentionally has NO such pair: there is no
// gitignored / worktree-local staging surface for tests — test changes
// must always land as staged tests/ files. If a future change adds a
// worktree-local test staging mechanism, mirror the docs treatment here.
function hasStagedTestChanges(repoDir) {
  try {
    const out = execSync("git diff --cached --name-only", {
      cwd: repoDir, encoding: "utf8", timeout: 5000, stdio: ["pipe", "pipe", "pipe"],
    });
    return out.trim().split("\n").some((f) => f.startsWith("tests/") || f.startsWith("test/"));
  } catch (e) {
    process.stderr.write(`workflow-gate: hasStagedTestChanges failed (cwd=${repoDir}): ${e.message}\n`);
    return false;
  }
}

// Allowlist of file patterns treated as human-facing documentation (not behavior code).
// Matches:
//   - any .md under docs/ (including nested: docs/architecture/foo.md)
//   - root-level human-facing .md files: README / CHANGELOG / CONTRIBUTING / LICENSE
// Intentionally excludes CLAUDE.md, SKILL.md, subdirectory README.md, etc. —
// those are behavior/prompt code that require the full workflow gate.
const DOCS_ONLY_ALLOWLIST = /^(docs\/.+\.md|(README|CHANGELOG|CONTRIBUTING|LICENSE)\.md)$/i;

// Evidence-based check: ALL staged files are human-facing docs (no behavior code)
function isDocsOnlyStaged(repoDir) {
  try {
    const out = execSync("git diff --cached --name-only", {
      cwd: repoDir, encoding: "utf8", timeout: 5000, stdio: ["pipe", "pipe", "pipe"],
    });
    const files = out.trim().split("\n").filter(Boolean);
    return files.length > 0 && files.every((f) => DOCS_ONLY_ALLOWLIST.test(f));
  } catch (e) {
    process.stderr.write(`workflow-gate: isDocsOnlyStaged failed (cwd=${repoDir}): ${e.message}\n`);
    return false;
  }
}

// Detect whether docs/ points to a separate git repository (junction / symlink pattern).
// Returns the external repo root if docs/ resolves to a different git tree, else null.
function resolveExternalDocsRepo(repoDir) {
  const docsPath = path.join(repoDir, "docs");
  try {
    const out = execSync("git rev-parse --show-toplevel", {
      cwd: docsPath, encoding: "utf8", timeout: 5000, stdio: ["pipe", "pipe", "pipe"],
    }).trim();
    const norm = (p) => p.replace(/\\/g, "/").replace(/\/$/, "").toLowerCase();
    if (norm(out) !== norm(repoDir)) return out;
  } catch (e) {}
  return null;
}

// Evidence-based check: staged files contain docs/*.md or *.md changes
function hasStagedDocChanges(repoDir) {
  const hasDocs = (dir) => {
    try {
      const out = execSync("git diff --cached --name-only", {
        cwd: dir, encoding: "utf8", timeout: 5000, stdio: ["pipe", "pipe", "pipe"],
      });
      return out.trim().split("\n").some((f) => f.startsWith("docs/") || /\.md$/i.test(f));
    } catch (e) {
      return false;
    }
  };
  if (hasDocs(repoDir)) return true;
  const externalRepo = resolveExternalDocsRepo(repoDir);
  return externalRepo !== null && hasDocs(externalRepo);
}

// Return true if dir has any staged changes.
function hasStagedChanges(dir) {
  try {
    const out = execSync("git diff --cached --name-only", {
      cwd: dir, encoding: "utf8", timeout: 5000, stdio: ["pipe", "pipe", "pipe"],
    });
    return out.trim().length > 0;
  } catch (e) {
    return false;
  }
}

module.exports = { DOCS_ONLY_ALLOWLIST, hasStagedTestChanges, isDocsOnlyStaged, resolveExternalDocsRepo, hasStagedDocChanges, hasStagedChanges };
