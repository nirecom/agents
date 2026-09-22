// Shared module: dynamically check if a git repo is private via GitHub API
// Returns true if repo is private, false otherwise (fail-open on any error)

const { spawnSync } = require("child_process");
const { parseGitCArg } = require("./parse-git-args");
const { extractHost, extractRepoId, parseOriginOwnerRepo } = require("./parse-remote-url");
const { resolveCodehostDescriptor, FORGE_DESCRIPTORS } = require("./forge-router");

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

    // #2308: resolve the forge and branch on it. No silent github fallback.
    const desc = resolveCodehostDescriptor(remoteUrl); // { type, ...codehost methods }
    if (desc.type === "github") {
      // Host and repo id come from ONE parse of the same URL: a separately
      // extracted repo id can name a repository the host check never validated,
      // and `gh api repos/<that>` would then answer about an unrelated repo.
      const parsed = parseOriginOwnerRepo(remoteUrl);
      if (!parsed.ok) return false; // github but unparsable → fail-open
      return desc.isPrivateRepo(remoteUrl);
    }
    if (desc.type === "gitlab") {
      // codehostGitlab runs end-to-end (C5). A self-hosted GitLab must have been
      // declared via FORGE_GITLAB_HOST for this branch to be reached.
      return desc.isPrivateRepo(remoteUrl);
    }
    // type="unknown": resolveForgeTarget could not classify the host (unrecognized
    // host, null host from a local path, or a recognised host with a poisoned/empty
    // project path). Fall back to parseOriginOwnerRepo's fine-grained codes:
    //   non-github-host  → treat as private (unclassified remote host)
    //   unparsable-host  → fail-open (local bare-repo remote — no network leakage)
    //   unparsable-owner-repo → fail-open (github.com URL with bad path)
    const parsed = parseOriginOwnerRepo(remoteUrl);
    if (!parsed.ok) return parsed.code === "non-github-host";
    return true; // parsed ok but forge unknown — shouldn't happen; treat as private
  } catch (e) {
    // gh not found, network error, not a git repo, etc. → fail-open
    return false;
  }
}

// Boolean-only wrapper for hooks that must never throw and must hand the linter
// a real boolean (lintWorktreeNotesLang compares with `=== true`).
function safeIsPrivateRepo(cwd) {
  try {
    return isPrivateRepo(cwd) === true;
  } catch (e) {
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
// command: the original Bash command string (optional; used to detect non-GitHub tools).
function shouldScanAsPublicTarget(ownerRepo, command) {
  // #2308: select the codehost descriptor by the command's forge classification.
  // ownerRepo is a path selector (no host), so resolveForgeTarget(url) cannot be
  // used; the existing "classify the command" pattern is extended symmetrically.
  // Empty command or a GitHub forge write → github codehost (unchanged SSOT/contract).
  if (!command || FORGE_DESCRIPTORS.github.tracker.isForgeScanTarget(command)) {
    return FORGE_DESCRIPTORS.github.codehost.shouldScanAsPublicTarget(ownerRepo);
  }
  // GitLab forge write (glab) → gitlab codehost descriptor for visibility (C5, end-to-end).
  if (FORGE_DESCRIPTORS.gitlab.tracker.isForgeScanTarget(command)) {
    return FORGE_DESCRIPTORS.gitlab.codehost.shouldScanAsPublicTarget(ownerRepo);
  }
  // Unknown tool → fail-closed: scan as public (unchanged conservative behavior).
  return true;
}

// List owner/repo strings for all private repos visible to the user.
// Fail-OPEN: error → []. Always queries the codehost fresh.
function listPrivateRepoNames() {
  // #2308: route through the CWD origin's codehost descriptor (github/gitlab/stub)
  // so private names on either forge are captured for outbound redaction (CPR-ORTH).
  try {
    const r = spawnSync("git", ["remote", "get-url", "origin"], { encoding: "utf8", timeout: 5000 });
    if (r.error || r.status !== 0) return [];
    const url = (r.stdout || "").trim();
    if (!url) return [];
    return resolveCodehostDescriptor(url).listPrivateRepoNames();
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

module.exports = { isPrivateRepo, safeIsPrivateRepo, resolveRepoDir, toNativePath, extractRepoDirFromCommand, extractRepoId, extractHost, shouldScanAsPublicTarget, listPrivateRepoNames, escapeRegex, findPrivateName };
