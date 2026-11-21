"use strict";

/**
 * spawn-env.js
 *
 * Helpers for spawning gh/git (PATH lookup) and bash scripts (absolute path).
 * Opts: utf8, live process.env (bash/MSYS2 resolves the Windows PATH itself),
 * windowsHide. Absolute script paths are converted to MSYS2 POSIX form.
 */

const path = require("path");

// windowsHide: bash is a console app; spawned from a console-less detached
// node parent (pm-state hook) on Windows it opens a black console window.
// Built per call so env is the live process.env.
function spawnOpts() {
  return { encoding: "utf8", env: process.env, windowsHide: true };
}

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
    spawnOpts(),
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
    spawnOpts(),
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
    spawnOpts(),
  ];
}

module.exports = { buildGhSpawn, buildGitSpawn, buildBashScriptSpawn, toMsys2Posix };
