"use strict";
// GitHub CLI detection: locate `gh` in PATH (MSYS2/Windows-aware) and check
// whether the current branch has an open or merged PR.

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const { resolveCodehostDescriptor } = require("../lib/forge-router");

// findGhInPath: locate the gh executable by searching PATH via Node's filesystem API.
// This is needed on Windows (MSYS2/Git Bash) where PATH may contain Windows-format
// entries (C:/path) that bash cannot resolve at runtime when PATH is otherwise
// POSIX-format. Node's fs.existsSync handles Windows paths natively.
// Also handles the split artifact: "C:/path" split on ":" yields "C" + "/path",
// so paths starting with "/" on Windows are resolved relative to the current drive.
function findGhInPath() {
  const dirs = (process.env.PATH || "").split(/[:;]/).filter(Boolean);
  for (const dir of dirs) {
    const candidates = [dir];
    if (/^\/[a-zA-Z]\//.test(dir)) {
      // MSYS2 drive path /<drive>/foo → <DRIVE>:\foo
      candidates.push(dir[1].toUpperCase() + ":\\" + dir.slice(3).replace(/\//g, "\\"));
    } else if (/^[a-zA-Z]:\//.test(dir)) {
      // Windows forward-slash C:/foo → C:\foo
      candidates.push(dir.replace(/\//g, "\\"));
    } else if (process.platform === "win32" && /^\//.test(dir)) {
      // Root-relative on Windows (artifact of splitting "C:/foo" on ":"):
      // path.resolve adds the current drive letter so /Users/... → C:\Users\...
      try { candidates.push(path.resolve(dir)); } catch (e) {}
    }
    for (const d of candidates) {
      for (const name of ["gh", "gh.exe", "gh.cmd", "gh.bat"]) {
        try {
          // path.resolve ensures a fully-qualified absolute path (adds drive letter
          // on Windows when path.join produces root-relative \path\... form).
          const candidate = path.resolve(path.join(d, name));
          if (fs.existsSync(candidate)) return candidate;
        } catch (e) {}
      }
    }
  }
  return null;
}

// toMsys2Path: convert a Windows absolute path (C:\foo or C:/foo) to MSYS2
// format (/<drive>/foo) so bash on Windows (Git Bash / MSYS2) can locate the file.
function toMsys2Path(p) {
  if (/^[a-zA-Z]:[/\\]/.test(p)) {
    return "/" + p[0].toLowerCase() + "/" + p.slice(3).replace(/\\/g, "/");
  }
  return p.replace(/\\/g, "/");
}

// isBranchDirectlyMerged: returns true if HEAD is fully contained in origin/main,
// meaning the branch was pushed directly (no PR) — the bootstrap scenario.
// Fail-closed: returns false on any git error so the premature guard stays active.
function isBranchDirectlyMerged(repoDir) {
  let r;
  try {
    r = spawnSync(
      "git", ["-C", repoDir, "rev-list", "origin/main..HEAD", "--count"],
      { encoding: "utf8", timeout: 5000 }
    );
  } catch (e) {
    return false;
  }
  if (r && r.status === 0) return parseInt((r.stdout || "0").trim(), 10) === 0;
  return false;
}

function originUrl(repoDir) {
  const remote = spawnSync("git", ["-C", repoDir, "remote", "get-url", "origin"], { encoding: "utf8", timeout: 5000 });
  if (!remote || remote.error || remote.status !== 0) return null;
  return (remote.stdout || "").trim() || null;
}

// prStateForBranch: OPEN | MERGED | CLOSED | NONE | UNKNOWN for the current branch
// (vocabulary: lib/forge/pr-state.js). #2307: routes through the forge codehost
// descriptor for the repo's origin; an unreadable origin answers UNKNOWN.
function prStateForBranch(repoDir) {
  const url = originUrl(repoDir);
  if (!url) return "UNKNOWN";
  return resolveCodehostDescriptor(url).prStateForBranch(repoDir);
}

// prForBranch: { state, number } for the current branch (bin/workflow/pr-state).
function prForBranch(repoDir) {
  const url = originUrl(repoDir);
  if (!url) return { state: "UNKNOWN", number: "" };
  return resolveCodehostDescriptor(url).prForBranch(repoDir);
}

// hasOpenPrForBranch: true iff the current branch has an OPEN or MERGED PR; an
// unknown answer fails open (true) so the premature guard stays active.
function hasOpenPrForBranch(repoDir) {
  const url = originUrl(repoDir);
  if (!url) return true;
  return resolveCodehostDescriptor(url).hasOpenPrForBranch(repoDir);
}

// isRemoteDefaultBranchAbsent: true only when origin is reachable and has no
// branch at all (the bootstrap repo, where no PR can exist). A local
// origin/<default> ref, any git error, or an unreachable remote answers false so
// the premature guard stays active (fail-closed).
function isRemoteDefaultBranchAbsent(repoDir) {
  try {
    const { getProtectedBranches } = require("../lib/merge-detect");
    for (const b of getProtectedBranches()) {
      const ref = spawnSync("git", ["-C", repoDir, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/" + b],
        { encoding: "utf8", timeout: 5000 });
      if (!ref || ref.error) return false;
      if (ref.status === 0) return false;
    }
    // BatchMode: an SSH passphrase / host-key prompt must fail fast, not hang to the timeout.
    const inheritedSsh = process.env.GIT_SSH_COMMAND;
    const sshCommand = !inheritedSsh ? "ssh -o BatchMode=yes"
      : /batchmode/i.test(inheritedSsh) ? inheritedSsh : inheritedSsh + " -o BatchMode=yes";
    const env = Object.assign({}, process.env, { GIT_TERMINAL_PROMPT: "0", GIT_SSH_COMMAND: sshCommand });
    const ls = spawnSync("git", ["-C", repoDir, "ls-remote", "--heads", "origin"], { encoding: "utf8", timeout: 8000, env });
    if (!ls || ls.error || ls.status !== 0) return false;
    return (ls.stdout || "").trim() === "";
  } catch (e) {
    return false;
  }
}

module.exports = {
  findGhInPath, toMsys2Path, prStateForBranch, prForBranch, hasOpenPrForBranch, isBranchDirectlyMerged, isRemoteDefaultBranchAbsent,
};
