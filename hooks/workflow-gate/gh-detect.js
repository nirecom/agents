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
      // MSYS2 drive path /c/foo → C:\foo
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
// format (/c/foo) so bash on Windows (Git Bash / MSYS2) can locate the file.
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

// hasOpenPrForBranch: returns true iff the current branch has an OPEN or MERGED PR.
// #2307: routes through the forge codehost descriptor for the repo's origin, so a
// GitHub repo runs the gh check while a non-GitHub repo hits the no-op stub. A
// remote that cannot be read fails open (true) so the premature guard stays active.
function hasOpenPrForBranch(repoDir) {
  const remote = spawnSync("git", ["-C", repoDir, "remote", "get-url", "origin"], { encoding: "utf8", timeout: 5000 });
  if (!remote || remote.error || remote.status !== 0) return true;
  const url = (remote.stdout || "").trim();
  if (!url) return true;
  return resolveCodehostDescriptor(url).hasOpenPrForBranch(repoDir);
}

module.exports = { findGhInPath, toMsys2Path, hasOpenPrForBranch, isBranchDirectlyMerged };
