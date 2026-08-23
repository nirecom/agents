"use strict";

// Pure git-remote-URL parsing. No process, no filesystem — every caller that
// needs repository identity derives it from the ORIGIN url alone (#1899).

const GITHUB_HOST = "github.com";

// Scheme regex mirrors the bash counterpart in bin/is-github-dotcom-remote, so
// git://, svn+ssh:// and friends are recognized identically on both sides.
const SCHEME_RE = /^[A-Za-z][A-Za-z0-9+.-]*:\/\//;

// owner/repo are interpolated straight into `gh api repos/<owner>/<repo>`, an
// AUTHENTICATED call whose URL path is normalized before it is sent — so a
// segment of "." or ".." traverses into a repository the caller never named.
// A single permissive [A-Za-z0-9._-]+ per segment admits exactly that, so the
// two segments are validated separately against their real-world charsets:
//   owner — the GitHub login charset: leading alnum, then alnum/hyphen, 1..39
//           characters. No dots, no underscores, so no dot-segment can form.
//   repo  — [A-Za-z0-9._-] 1..100, "." and ".." rejected outright (a repo name
//           may legitimately begin with a dot, e.g. ".config").
// bin/github-issues/lib/origin-repo.sh mirrors this contract verbatim (CPR-ORTH).
const OWNER_RE = /^[A-Za-z0-9][A-Za-z0-9-]{0,38}$/;
const REPO_RE = /^[A-Za-z0-9._-]{1,100}$/;

// #2053: both predicates now also take values lifted from a command line
// (`--repo <v>`), not only segments of an already-parsed origin URL. So a
// non-string must be rejected rather than coerced by RegExp.test, and a login
// with a trailing or doubled hyphen — which GitHub cannot issue — must not
// reach `gh api repos/...`. Every shape the charset tests pin is unchanged.
const OWNER_SHAPE_RE = /^[A-Za-z0-9](?:-?[A-Za-z0-9])*$/;

function isValidOwner(owner) {
  if (typeof owner !== "string") return false;
  if (!OWNER_RE.test(owner)) return false;
  return OWNER_SHAPE_RE.test(owner);
}

function isValidRepo(repo) {
  if (typeof repo !== "string") return false;
  if (repo === "." || repo === "..") return false;
  return REPO_RE.test(repo);
}

// Extract hostname from a git remote URL
// Supports: git@host:path, https://host/path, ssh://user@host:port/path
function extractHost(remoteUrl) {
  if (!remoteUrl) return null;
  // <scheme>://user@host:port/path
  const urlMatch = remoteUrl.match(/^[A-Za-z][A-Za-z0-9+.-]*:\/\/(?:[^@/]+@)?([^/:]+)/);
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

// Replace the userinfo (`user` or `user:pass`) of a remote URL with `***`.
// `git remote get-url origin` can hand back an HTTPS URL carrying an access
// token (https://x-access-token:<token>@github.com/owner/repo.git). Anything
// that echoes that URL back — an error `.message`, a workflow NEXT_HINT line, an
// on-disk worker log — would leak the token, so every echo goes through here first.
// The scheme form is redacted wherever it occurs, because such a URL can sit
// mid-sentence inside a longer message. The SCP form (`git@host:path`) is
// redacted only at the start of the string, where a remote URL begins — an
// unanchored match would rewrite ordinary email addresses mid-sentence.
function redactUserinfo(url) {
  if (typeof url !== "string" || url === "") return url;
  return url
    .replace(/([A-Za-z][A-Za-z0-9+.-]*:\/\/)[^@/\s]+@/g, "$1***@")
    .replace(/^[^@/\s]+@/, "***@");
}

function failure(code, message) {
  return { ok: false, code, message };
}

// Resolve a github.com origin URL to its owner/repo identity.
// Returns { ok: true, ownerRepo, owner, repo, host } or { ok: false, code, message }.
// Host matching is exact — "github.com.evil.com", "notgithub.com" and
// "sub.github.com" are all non-github hosts.
function parseOriginOwnerRepo(remoteUrl) {
  if (typeof remoteUrl !== "string" || remoteUrl.trim() === "") {
    return failure("empty-url", "no origin remote URL was given");
  }

  const url = remoteUrl.trim().replace(/\/+$/, "");
  // Every message below echoes the input back to a log or a NEXT_HINT line, so
  // it echoes the credential-free form of it.
  // Redact the TRIMMED value, not the raw input: redactUserinfo's SCP branch is
  // anchored at ^, so leading whitespace on `remoteUrl` would skip it entirely
  // and echo the credential verbatim.
  const safeUrl = redactUserinfo(url);

  const rawHost = extractHost(url);
  if (!rawHost) {
    return failure("unparsable-host", `could not read a host out of the remote URL: ${safeUrl}`);
  }
  const host = rawHost.toLowerCase();
  if (host !== GITHUB_HOST) {
    return failure("non-github-host", `origin remote host is '${host}', not ${GITHUB_HOST}`);
  }

  let repoPath;
  const schemeMatch = url.match(SCHEME_RE);
  if (schemeMatch) {
    const rest = url.slice(schemeMatch[0].length).replace(/^[^@/]+@/, "");
    const slash = rest.indexOf("/");
    if (slash < 0) {
      return failure("unparsable-owner-repo", `no owner/repo path in the remote URL: ${safeUrl}`);
    }
    repoPath = rest.slice(slash + 1);
  } else {
    const colon = url.indexOf(":");
    if (colon < 0) {
      return failure("unparsable-owner-repo", `no owner/repo path in the remote URL: ${safeUrl}`);
    }
    repoPath = url.slice(colon + 1);
  }

  repoPath = repoPath.replace(/\.git$/, "").replace(/\/+$/, "");
  // Split on the single "/" separator: a deeper path (a/b/c) leaves "b/c" as the
  // repo candidate, which the repo charset then rejects.
  const sep = repoPath.indexOf("/");
  const owner = sep < 0 ? "" : repoPath.slice(0, sep);
  const repo = sep < 0 ? "" : repoPath.slice(sep + 1);
  if (!isValidOwner(owner) || !isValidRepo(repo)) {
    return failure("unparsable-owner-repo", `could not read owner/repo out of the remote URL: ${safeUrl}`);
  }

  return { ok: true, ownerRepo: `${owner}/${repo}`, owner, repo, host: GITHUB_HOST };
}

module.exports = { extractHost, extractRepoId, parseOriginOwnerRepo, redactUserinfo, isValidOwner, isValidRepo, GITHUB_HOST };
