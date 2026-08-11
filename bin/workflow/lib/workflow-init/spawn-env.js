"use strict";

/**
 * spawn-env.js
 *
 * Helpers for spawning `gh` (PATH-based) and bash scripts (absolute-path).
 *
 * On Windows/MSYS2 with Git Bash: Node on Windows receives PATH as a
 * semicolon-separated Windows-format string. When Node spawns bash with
 * {env: process.env}, bash (MSYS2) correctly resolves Windows-format PATH
 * entries to POSIX paths, so `exec "$0" "$@"` gh lookup finds the mock gh
 * in tests. No special env manipulation is needed.
 *
 * For absolute-path bash scripts (wip-state.sh etc.): convert the Windows
 * drive-letter prefix to its POSIX MSYS2 form so bash can exec the script
 * directly.
 */

const path = require("path");

/**
 * Convert a Windows drive-letter path to its MSYS2 POSIX form (the drive
 * letter lowercased and moved between leading slashes).
 * Returns the path unchanged if it doesn't start with a Windows drive letter.
 */
function toMsys2Posix(p) {
  const converted = p.replace(/^([A-Za-z]):[/\\]/, function(_, drive) {
    return "/" + drive.toLowerCase() + "/";
  });
  return converted.replace(/\\/g, "/");
}

/**
 * Build spawn args for running `gh` with given args.
 * Uses bash PATH lookup (exec "$0" "$@" pattern, security-safe argv passing).
 * Inherits process.env so bash receives the current PATH (including mock-bin in tests).
 *
 * @param {string[]} ghArgs - arguments to pass to gh (after "gh")
 * @returns {[string, string[], object]} [cmd, args, opts] for spawnSync
 */
function buildGhSpawn(ghArgs) {
  return [
    "bash",
    ["-c", 'exec "$0" "$@"', "gh", ...ghArgs],
    { encoding: "utf8", env: process.env },
  ];
}

/**
 * Build spawn args for running `git` with given args.
 * Same PATH-lookup shape as buildGhSpawn (#1899).
 *
 * @param {string[]} gitArgs - arguments to pass to git (after "git")
 * @returns {[string, string[], object]} [cmd, args, opts] for spawnSync
 */
function buildGitSpawn(gitArgs) {
  return [
    "bash",
    ["-c", 'exec "$0" "$@"', "git", ...gitArgs],
    { encoding: "utf8", env: process.env },
  ];
}

/**
 * Build spawn args for running a bash script at an absolute path.
 * Converts a native Windows drive-letter path to its POSIX MSYS2 form for bash.
 *
 * @param {string} scriptPath - absolute path (may be C:/... or /posix/path)
 * @param {string[]} scriptArgs
 * @returns {[string, string[], object]} [cmd, args, opts] for spawnSync
 */
function buildBashScriptSpawn(scriptPath, scriptArgs) {
  const posixPath = toMsys2Posix(scriptPath);
  return [
    "bash",
    [posixPath, ...scriptArgs],
    { encoding: "utf8", env: process.env },
  ];
}

module.exports = { buildGhSpawn, buildGitSpawn, buildBashScriptSpawn, toMsys2Posix };
