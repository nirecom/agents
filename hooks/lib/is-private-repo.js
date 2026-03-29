// Shared module: dynamically check if a git repo is private via GitHub API
// Returns true if repo is private, false otherwise (fail-open on any error)

const { execSync } = require("child_process");
const path = require("path");

// Normalize path for shell commands (Windows backslashes → forward slashes)
function shellPath(p) {
  return p.split(path.sep).join("/");
}

// Extract repo directory from a git command string (supports git -C <path>)
function extractRepoDirFromCommand(command) {
  const match = command.match(/git\s+-C\s+(\S+)/);
  return match ? match[1] : null;
}

// Extract hostname from a git remote URL
// Supports: git@host:path, https://host/path, ssh://user@host:port/path
function extractHost(remoteUrl) {
  if (!remoteUrl) return null;
  // ssh://user@host:port/path or https://host/path
  const urlMatch = remoteUrl.match(/^(?:ssh|https?):\/\/(?:[^@]+@)?([^/:]+)/);
  if (urlMatch) return urlMatch[1];
  // git@host:path (SCP-style)
  const scpMatch = remoteUrl.match(/^[^@]+@([^:]+):/);
  if (scpMatch) return scpMatch[1];
  return null;
}

// Get owner/repo identifier from a git remote URL
// Supports SSH (git@github.com:owner/repo.git) and HTTPS (https://github.com/owner/repo.git)
function extractRepoId(remoteUrl) {
  const match = remoteUrl.match(/[/:]([^/]+\/[^/]+?)(?:\.git)?$/);
  return match ? match[1] : null;
}

// Check if a repo is private using gh CLI
// repoDir: path to the git repository
// Returns true if private, false if public or on any error (fail-open)
function isPrivateRepo(repoDir) {
  if (!repoDir) return false;

  try {
    const remoteUrl = execSync(`git -C "${shellPath(repoDir)}" remote get-url origin`, {
      encoding: "utf8",
      timeout: 5000,
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();

    if (!remoteUrl) return false;

    const host = extractHost(remoteUrl);
    // Non-GitHub hosts (GitLab, Bitbucket, etc.) → treat as private
    if (host && host !== "github.com") return true;

    const repoId = extractRepoId(remoteUrl);
    if (!repoId) return false;

    const result = execSync(`gh api repos/${repoId} --jq .private`, {
      encoding: "utf8",
      timeout: 10000,
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();

    return result === "true";
  } catch (e) {
    // gh not found, network error, not a git repo, etc. → fail-open
    return false;
  }
}

// Resolve the effective repo directory for a Bash git commit command
// Uses HOOK_CWD env var if available, falls back to -C path or cwd
function resolveRepoDir(command) {
  if (process.env.HOOK_CWD) return process.env.HOOK_CWD;
  return extractRepoDirFromCommand(command) || ".";
}

module.exports = { isPrivateRepo, resolveRepoDir, extractRepoDirFromCommand, extractRepoId, extractHost };
