#!/usr/bin/env node
// Core copy logic for .worktreeinclude file-transfer on worktree-start.
// Enumerates gitignored files in mainRoot, filters via .worktreeinclude,
// checks denylist in .worktreecopyexclude, and copies matched files.

"use strict";

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const { buildMatcher } = require("./worktree-include-match");

function readPatternFile(filePath) {
  try {
    const content = fs.readFileSync(filePath, "utf8");
    return content
      .split("\n")
      .map((l) => l.trim())
      .filter((l) => l && !l.startsWith("#"));
  } catch (e) {
    if (e.code === "ENOENT") return null; // file not found
    throw e;
  }
}

function copyInclude({ mainRoot, worktreePath, includeFile }) {
  const result = { copied: [], skipped: [], denied: [], errors: [] };

  const mainDir = mainRoot.replace(/\\/g, "/");
  const wtDir = worktreePath.replace(/\\/g, "/");

  // Validate mainDir exists
  if (!fs.existsSync(mainDir) || !fs.statSync(mainDir).isDirectory()) {
    result.errors.push(`mainRoot does not exist or is not a directory: ${mainDir}`);
    return result;
  }

  // Read .worktreeinclude
  const includeFilePath = includeFile
    ? includeFile.replace(/\\/g, "/")
    : path.join(mainDir, ".worktreeinclude");

  const includePatterns = readPatternFile(includeFilePath);
  if (includePatterns === null || includePatterns.length === 0) {
    // No include file or empty → nothing to copy
    return result;
  }

  // Read .worktreecopyexclude (denylist) — absence is fine.
  // Negation patterns (!foo) are stripped: the denylist must never allow opt-out.
  const denyFilePath = path.join(mainDir, ".worktreecopyexclude");
  const rawDenyPatterns = readPatternFile(denyFilePath) || [];
  const denyPatterns = rawDenyPatterns.filter((p) => {
    if (p.startsWith("!")) {
      process.stderr.write(`WARN: negation pattern '${p}' in .worktreecopyexclude ignored — denylist entries are absolute\n`);
      return false;
    }
    return true;
  });

  // Enumerate gitignored files in main worktree (NUL-delimited for safety)
  const lsResult = spawnSync(
    "git",
    ["-C", mainDir, "ls-files", "--others", "--ignored", "--exclude-standard", "-z"],
    { encoding: "buffer" }
  );

  if (lsResult.error || lsResult.status !== 0) {
    const msg = lsResult.error
      ? lsResult.error.message
      : (lsResult.stderr || Buffer.alloc(0)).toString().trim();
    result.errors.push(`git ls-files failed: ${msg}`);
    return result;
  }

  const gitignored = lsResult.stdout.toString("utf8").split("\0").filter(Boolean);

  // Build matchers
  const includeMatcher = buildMatcher(includePatterns);
  const denyMatcher = denyPatterns.length ? buildMatcher(denyPatterns) : null;

  // Consistency check: warn for include patterns that match no gitignored files
  for (const pattern of includePatterns) {
    if (pattern.startsWith("!")) continue; // negation patterns are not direct matches
    const testMatcher = buildMatcher([pattern]);
    const hasMatch = gitignored.some((f) => testMatcher.ignores(f));
    if (!hasMatch) {
      process.stderr.write(
        `WARN: .worktreeinclude pattern '${pattern}' matches no gitignored files — ` +
          `omit or add to .gitignore\n`
      );
    }
  }

  // Process each gitignored file
  for (const relPath of gitignored) {
    // Hardcoded recursion guard (issue #637): never copy anything whose
    // relPath starts with .worktree-backup/. Defense-in-depth on top of the
    // .worktreecopyexclude denylist — the denylist catches nested forms
    // (outer/.worktree-backup/...) via gitignore semantics; this guard
    // unconditionally catches the root-anchored form even if the denylist
    // entry is removed or typo'd.
    const normalizedRel = relPath.replace(/\\/g, "/");
    if (normalizedRel === ".worktree-backup" ||
        normalizedRel.startsWith(".worktree-backup/")) {
      result.denied.push(relPath);
      continue;
    }

    if (!includeMatcher.ignores(relPath)) {
      result.skipped.push(relPath);
      continue;
    }

    if (denyMatcher && denyMatcher.ignores(relPath)) {
      result.denied.push(relPath);
      continue;
    }

    // Path traversal guard: resolved source must stay within mainDir
    const resolvedSrc = path.resolve(mainDir, relPath);
    const resolvedMain = path.resolve(mainDir);
    if (!resolvedSrc.startsWith(resolvedMain + path.sep) && resolvedSrc !== resolvedMain) {
      result.errors.push(`Path traversal rejected: ${relPath}`);
      continue;
    }

    // Symlink guard: never follow symlinks into or out of mainDir
    try {
      if (fs.lstatSync(resolvedSrc).isSymbolicLink()) {
        result.errors.push(`Symlink source rejected: ${relPath}`);
        continue;
      }
    } catch (e) {
      result.errors.push(`Failed to stat ${relPath}: ${e.message}`);
      continue;
    }

    const resolvedDst = path.resolve(wtDir, relPath);
    // Destination bound check: must stay inside wtDir
    const resolvedWt = path.resolve(wtDir);
    if (!resolvedDst.startsWith(resolvedWt + path.sep) && resolvedDst !== resolvedWt) {
      result.errors.push(`Destination path traversal rejected: ${relPath}`);
      continue;
    }

    try {
      fs.mkdirSync(path.dirname(resolvedDst), { recursive: true });
      fs.copyFileSync(resolvedSrc, resolvedDst);
      result.copied.push(relPath);
    } catch (e) {
      result.errors.push(`Failed to copy ${relPath}: ${e.message}`);
    }
  }

  return result;
}

module.exports = { copyInclude };
