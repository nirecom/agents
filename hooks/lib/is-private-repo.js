// Shared module: dynamically check if a git repo is private via GitHub API
// Returns true if repo is private, false otherwise (fail-open on any error)

const { execSync, spawnSync } = require("child_process");
const { parseGitCArg } = require("./parse-git-args");
const { extractHost, extractRepoId, parseOriginOwnerRepo } = require("./parse-remote-url");

// Extract repo directory from a git command string (supports git -C <path>)
function extractRepoDirFromCommand(command) {
  return parseGitCArg(command);
}

// extractHost / extractRepoId now live in ./parse-remote-url.js (#1899) and are
// re-exported below so existing callers of this module keep working.

// Check if a repo is private using gh CLI
// repoDir: path to the git repository
// Returns true if private, false if public or on any error (fail-open)
function isPrivateRepo(repoDir) {
  if (!repoDir) return false;

  try {
    // SECURITY: repoDir passed as array element — never shell-interpolated.
    // Quoting it inside a shell string would still leave `$(...)`/backticks in
    // the path live on POSIX shells, executing attacker-chosen commands.
    const remote = spawnSync("git", ["-C", repoDir, "remote", "get-url", "origin"], {
      encoding: "utf8",
      timeout: 5000,
    });
    // Same contract as the previous execSync: a failed git → fail-open (false).
    if (remote.error || remote.status !== 0) return false;
    const remoteUrl = (remote.stdout || "").trim();

    if (!remoteUrl) return false;

    // Host and repo id come from ONE parse of the same URL: a separately
    // extracted repo id can name a repository the host check never validated,
    // and `gh api repos/<that>` would then answer about an unrelated repo.
    const parsed = parseOriginOwnerRepo(remoteUrl);
    if (!parsed.ok) {
      // Non-GitHub hosts (GitLab, Bitbucket, etc.) → treat as private, as before.
      // Every other failure code (empty-url, unparsable-host, unparsable-owner-repo)
      // fails open: there is no validated repo identity to ask gh about.
      return parsed.code === "non-github-host";
    }

    const result = execSync(`gh api repos/${parsed.ownerRepo} --jq .private`, {
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

// Convert WSL/MSYS-style drive paths (e.g. bash /X/path) to Windows paths (X:/path) on win32.
// Necessary because the Bash tool uses Unix-style paths even on Windows.
function toNativePath(p) {
  if (process.platform !== "win32") return p;
  const m = p.match(/^\/([a-z])\/(.*)$/i);
  return m ? `${m[1].toUpperCase()}:/${m[2]}` : p;
}

// Resolve the effective repo directory for a Bash git commit command
// Uses HOOK_CWD env var if available, falls back to -C path or cwd
function resolveRepoDir(command) {
  if (process.env.CLAUDE_PROJECT_DIR) return process.env.CLAUDE_PROJECT_DIR;
  const raw = extractRepoDirFromCommand(command) || ".";
  return toNativePath(raw);
}

// Check whether a forge-write target repo should be scanned as PUBLIC.
// Fail-CLOSED: unknown/error/empty → return true (scan as public).
// ownerRepo: "owner/repo" string from --repo flag.
function shouldScanAsPublicTarget(ownerRepo) {
  try {
    if (!ownerRepo || typeof ownerRepo !== "string") return true;
    // SECURITY: ownerRepo passed as array element — never shell-interpolated.
    const result = spawnSync("gh", ["api", "repos/" + ownerRepo, "--jq", ".private"], {
      encoding: "utf8",
      timeout: 10000,
    });
    if (result.error || result.status !== 0) return true; // fail-closed
    const out = (result.stdout || "").trim();
    if (out === "true") return false;  // confirmed private → skip public scan
    if (out === "false") return true;  // confirmed public → scan
    return true; // empty/garbage → fail-closed
  } catch (e) {
    return true;
  }
}

// List owner/repo strings for all private repos visible to the user.
// Fail-OPEN: error → []. Always queries gh fresh.
function listPrivateRepoNames() {
  try {
    const result = spawnSync(
      "gh",
      ["repo", "list", "--limit", "1000", "--visibility", "private", "--json", "nameWithOwner", "--jq", ".[].nameWithOwner"],
      { encoding: "utf8", timeout: 10000 }
    );
    if (result.error || result.status !== 0) return []; // fail-open
    return (result.stdout || "")
      .split(/\r?\n/)
      .map((s) => s.trim())
      .filter(Boolean);
  } catch (e) {
    return [];
  }
}

// Escape regex metacharacters in a string.
function escapeRegex(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

// SSOT for private-repo-name detection, shared by bin/check-private-repo-name.js
// and hooks/scan-outbound.js. split('/').pop() normalizes bare and
// 'owner/repo' forms alike. Matches on alnum tokens joined by a non-alnum
// separator class (not a literal substring) so a slugified candidate
// ('acme-internal') still matches a punctuated name ('acme.internal').
// A name with no tokens (pure punctuation) is skipped — an empty token list
// would match almost any two adjacent non-alnum characters.
function findPrivateName(candidate, privateNames) {
  for (const name of privateNames) {
    const bare = name.split("/").pop();
    if (!bare) continue;
    const tokens = bare.split(/[^a-zA-Z0-9]+/).filter(Boolean).map(escapeRegex);
    if (tokens.length === 0) continue;
    const re = new RegExp(
      "(^|[^a-zA-Z0-9])" + tokens.join("[^a-zA-Z0-9]+") + "([^a-zA-Z0-9]|$)",
      "i"
    );
    if (re.test(candidate)) return bare;
  }
  return null;
}

module.exports = { isPrivateRepo, resolveRepoDir, toNativePath, extractRepoDirFromCommand, extractRepoId, extractHost, shouldScanAsPublicTarget, listPrivateRepoNames, escapeRegex, findPrivateName };
