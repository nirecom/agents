"use strict";
// GitHub CLI detection: locate `gh` in PATH (MSYS2/Windows-aware) and check
// whether the current branch has an open or merged PR.

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

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

// hasOpenPrForBranch: returns true iff the current branch has an OPEN or MERGED PR.
// Called with { cwd: repoDir } so gh resolves the correct branch context.
// Exit-code semantics for `gh pr view`:
//   exit 0  → PR found; parse stdout for state
//   exit 1  → no PR for this branch (legitimate "not found")
//   exit >1 → gh error (auth failure, network, not installed) → fail-open (true)
// See issue #577.
function hasOpenPrForBranch(repoDir) {
  // Resolve gh path via Node fs so Windows-format PATH entries (C:/path) work
  // even when bash cannot translate them at runtime (mixed POSIX/Windows PATH).
  // Invoke through bash so both bash scripts (test mocks) and Windows PE
  // executables run. Pass ghArg as bash $1 (not interpolated into the script
  // string) to prevent shell injection from paths with special characters.
  const ghPath = findGhInPath();
  const ghArg = ghPath ? toMsys2Path(ghPath) : "gh";
  let r;
  try {
    r = spawnSync(
      "bash", ["-c", '"$1" pr view --json state -q .state', "--", ghArg],
      { cwd: repoDir, encoding: "utf8", timeout: 8000 }
    );
  } catch (e) {
    return true; // fail-open: spawn error (bash not found, etc.)
  }
  if (r && r.status === 0) {
    const state = (r.stdout || "").trim();
    return state === "OPEN" || state === "MERGED";
  }
  if (r && r.status === 1) return false; // no PR found for this branch
  return true; // fail-open: gh error (auth failure, network error, not installed)
}

module.exports = { findGhInPath, toMsys2Path, hasOpenPrForBranch };
