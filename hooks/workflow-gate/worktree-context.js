"use strict";
// Worktree context detection: distinguish linked worktrees from the main checkout,
// and detect staged doc evidence via WORKTREE_NOTES.md History/Changelog sections.

const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");

// Evidence-based check: WORKTREE_NOTES.md ## History Notes or ## Changelog Notes
// contains real bullets (post-#436 staging path under ENFORCE_WORKTREE=on).
// Mirrors bin/compose-doc-append-entry's extract_section parsing rules:
//   - "## <heading>" exact match opens the section
//   - next "## " line closes it
//   - within section, "- " bullets with content != "(none)" are real evidence
// Returns false when not in a worktree context, when WORKTREE_NOTES.md is
// absent (resolved at the worktree top-level, not at any subdir repoDir),
// or when both sections are empty / contain only "- (none)".
function hasWorktreeNotesDocEvidence(repoDir) {
  if (!isWorktreeContext(repoDir)) return false;
  // resolveRepoDir may return a subdirectory (e.g., `git -C subdir`); the
  // notes file always lives at the worktree root, so resolve toplevel first.
  let topLevel;
  try {
    topLevel = execSync("git rev-parse --show-toplevel", {
      cwd: repoDir, encoding: "utf8", timeout: 5000, stdio: ["pipe", "pipe", "pipe"],
    }).trim();
  } catch (e) {
    return false;
  }
  const notesPath = path.join(topLevel, "WORKTREE_NOTES.md");
  let text;
  try {
    text = fs.readFileSync(notesPath, "utf8");
  } catch (e) {
    return false;
  }
  const HEADINGS = ["## History Notes", "## Changelog Notes"];
  const lines = text.split(/\r?\n/);
  for (const heading of HEADINGS) {
    let inSection = false;
    for (const line of lines) {
      if (line === heading) { inSection = true; continue; }
      if (inSection && line.startsWith("## ")) break;
      if (inSection && line.startsWith("- ")) {
        const content = line.slice(2).trim();
        if (content && content !== "(none)") return true;
      }
    }
  }
  return false;
}

// Returns true when the commit is happening inside a linked worktree on a
// non-protected branch. Used to skip user_verification at commit time —
// verification is enforced later at the merge boundary instead.
function isWorktreeContext(repoDir) {
  try {
    const common = execSync("git rev-parse --git-common-dir", {
      cwd: repoDir, encoding: "utf8", timeout: 5000, stdio: ["pipe", "pipe", "pipe"],
    }).trim();
    const dir = execSync("git rev-parse --git-dir", {
      cwd: repoDir, encoding: "utf8", timeout: 5000, stdio: ["pipe", "pipe", "pipe"],
    }).trim();
    const norm = (p) => path.resolve(repoDir, p).toLowerCase();
    if (norm(common) === norm(dir)) return false;  // main worktree
    const branch = execSync("git rev-parse --abbrev-ref HEAD", {
      cwd: repoDir, encoding: "utf8", timeout: 5000, stdio: ["pipe", "pipe", "pipe"],
    }).trim();
    if (!branch || branch === "HEAD") return false;  // detached HEAD
    const envBranches = (process.env.DEFAULT_BRANCHES || "").split(",")
      .map((s) => s.trim()).filter(Boolean);
    const protectedBranches = envBranches.length ? envBranches : ["main", "master"];
    return !protectedBranches.includes(branch);
  } catch (e) {
    return false;
  }
}

// isLinkedWorktree — narrower than isWorktreeContext: returns true iff `path`
// is a valid git directory AND its common-dir differs from its git-dir
// (i.e., a linked worktree, not the main worktree). Used by resolveRepoDir to
// gate the payload-cwd tier without conflating repo resolution with the
// user_verification skip policy at line 431.
function isLinkedWorktree(dirPath) {
  if (!dirPath) return false;
  try {
    const common = execSync('git rev-parse --git-common-dir', {
      cwd: dirPath, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'], timeout: 5000,
    }).trim();
    const dir = execSync('git rev-parse --git-dir', {
      cwd: dirPath, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'], timeout: 5000,
    }).trim();
    const norm = (p) => path.resolve(dirPath, p).toLowerCase();
    return norm(common) !== norm(dir);
  } catch {
    return false;
  }
}

module.exports = { isWorktreeContext, isLinkedWorktree, hasWorktreeNotesDocEvidence };
