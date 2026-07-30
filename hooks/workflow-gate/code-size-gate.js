"use strict";
// hooks/workflow-gate/code-size-gate.js
// Gate 2 (issue #1701): HARD file-size limit check for staged code files.
// bin/review-code-size --staged owns the thresholds and line counting (CPR-2);
// this module only spawns it and maps the exit code to a gate verdict.

const { spawnSync } = require("child_process");
const fs = require("fs");
const path = require("path");
const { resolveAgentsConfigDir } = require("../lib/agents-config-dir");
const { readDefaultEnvFile } = require("../lib/load-env");
const { normalizeForWindows } = require("./path-normalize");

const BYPASS_LINE =
  'Emergency bypass (session-scoped): echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: {reason}>>"';

// Fail-closed message shared by every infrastructure-error path (CPR-5).
function infraBlock(causeLine, resolveLines) {
  return {
    action: "block",
    reason: [
      "workflow-gate: the code-size HARD-limit check (bin/review-code-size --staged) could not run",
      causeLine,
      "",
      "This gate fails closed on infrastructure errors so a broken check cannot silently",
      "let every commit through.",
      "",
      "Resolve by:",
      ...resolveLines,
      "",
      BYPASS_LINE,
    ].join("\n"),
  };
}

const RESOLVE_CONFIG =
  "  - Confirm AGENTS_CONFIG_DIR points at a valid agents checkout and bin/review-code-size exists.";
const RESOLVE_BASH =
  "  - Confirm bash is on PATH (required on Windows via Git Bash).";
const RESOLVE_RAW =
  "  - Run `bash bin/review-code-size --staged` directly to see the raw error.";

/**
 * Run bin/review-code-size --staged against the staged index of `repoDir`.
 * @returns {{action: "ok"}|{action: "block", reason: string}}
 */
function checkCodeSizeHardLimit(rawRepoDir) {
  // L2: normalize POSIX drive-letter paths (/c/...) to Windows form before
  // passing to spawnSync cwd — Node.js fs/process APIs fail with ENOENT on /c/.
  const repoDir = normalizeForWindows(rawRepoDir);
  const agentsDir = resolveAgentsConfigDir();
  if (!agentsDir) {
    return infraBlock("as expected: AGENTS_CONFIG_DIR could not be resolved.", [
      "  - Confirm AGENTS_CONFIG_DIR points at a valid agents checkout.",
      RESOLVE_RAW,
    ]);
  }

  // Normalize path for Windows/Git Bash compatibility (same as scan-outbound.js).
  const scriptPath = path
    .join(agentsDir, "bin", "review-code-size")
    .replace(/\\/g, "/");

  if (!fs.existsSync(scriptPath)) {
    return infraBlock(`as expected: script not found at ${scriptPath}`, [
      RESOLVE_CONFIG,
      RESOLVE_RAW,
    ]);
  }

  // H2: read CODE_FILE_EXTENSIONS from .env only — process.env is forgeable via
  // inline VAR=val prefix and must not override gate config (hooks/lib/load-env.js contract).
  // readDefaultEnvFile() returns an already-parsed plain object.
  const envMap = readDefaultEnvFile();
  const codeExt = envMap.CODE_FILE_EXTENSIONS;

  const spawnOpts = {
    cwd: repoDir,
    encoding: "utf8",
    timeout: 3000,
  };
  // Only inject env when CODE_FILE_EXTENSIONS is truthy; otherwise inherit process.env as-is.
  if (codeExt) {
    spawnOpts.env = { ...process.env, CODE_FILE_EXTENSIONS: codeExt };
  }

  const result = spawnSync("bash", [scriptPath, "--staged"], spawnOpts);

  // Timeout only: fail-open (status === null and a kill signal was delivered).
  if (result.status === null && result.signal) {
    process.stderr.write(
      `[code-size-gate] bin/review-code-size --staged timed out (${result.signal}) — failing open\n`
    );
    return { action: "ok" };
  }

  // Infrastructure error (e.g. bash not on PATH -> ENOENT).
  if (result.error) {
    return infraBlock(`as expected: ${result.error.message}`, [
      RESOLVE_BASH,
      RESOLVE_RAW,
    ]);
  }

  // HARD limit detected.
  if (result.status === 1) {
    const hardLines = (result.stdout || "")
      .split("\n")
      .filter((l) => l.startsWith("  HARD:"))
      .join("\n");
    return {
      action: "block",
      reason: [
        "workflow-gate: staged code file(s) exceed the 500-line HARD limit (rules/coding/file-split.md).",
        hardLines,
        "",
        "Resolve by either:",
        "  - Split the file: keep <name>.<ext> as dispatch/re-export only and move logic into a",
        "    sibling <name>/ folder (shared helpers -> adjacent lib/). See rules/coding/file-split.md.",
        "  - Unstage the file if it is not part of this change: git restore --staged <file>",
        "",
        "Note: a commit that performs the split passes this gate — the check reads the",
        "post-split line count of the staged blob (git index), not the working tree.",
        "",
        BYPASS_LINE,
      ].join("\n"),
    };
  }

  // Clean exit (0) — also covers SKIPPED (no staged code files).
  if (result.status === 0) {
    return { action: "ok" };
  }

  // Unexpected exit code — fail closed.
  return infraBlock(`as expected: unexpected exit code ${result.status}.`, [
    RESOLVE_CONFIG,
    RESOLVE_BASH,
    RESOLVE_RAW,
  ]);
}

module.exports = { checkCodeSizeHardLimit };
