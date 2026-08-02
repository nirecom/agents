"use strict";
// hooks/workflow-gate/prompt-extraction-gate.js
// Gate 3 (issue #1642): prompt-extraction check for staged prompt files.
// bin/check-prompt-extraction --staged owns detection, the allowlist and the
// exit-code contract (CPR-2); this module only spawns it and maps exit 1 -> block.
//
// Fail-closed on every infrastructure error. Timeout is the ONLY fail-open path
// (mirrors Gate 2 / code-size-gate.js — CPR-5).

const { spawnSync } = require("child_process");
const fs = require("fs");
const path = require("path");
const { resolveAgentsConfigDir } = require("../lib/agents-config-dir");
const { normalizeForWindows } = require("./path-normalize");

const BYPASS_LINE =
  'Emergency bypass (session-scoped): echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF: {reason}>>"';

function infraBlock(causeLine, resolveLines) {
  return {
    action: "block",
    reason: [
      "workflow-gate: the prompt-extraction check (bin/check-prompt-extraction --staged) could not run",
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
  "  - Confirm AGENTS_CONFIG_DIR points at a valid agents checkout and bin/check-prompt-extraction is installed.";
const RESOLVE_BASH =
  "  - Confirm bash is on PATH (required on Windows via Git Bash).";
const RESOLVE_RAW =
  "  - Run `bash bin/check-prompt-extraction --staged` directly to see the raw error.";

/**
 * @returns {{action: "ok"}|{action: "block", reason: string}}
 */
function checkPromptExtraction(rawRepoDir) {
  const repoDir = normalizeForWindows(rawRepoDir);

  // Repo-scope opt-in, evaluated BEFORE any infrastructure check: a repository
  // that carries no .prompt-extraction-allowlist has not adopted the gate, so a
  // missing CLI there is not an infrastructure failure. Same condition (b) as the
  // hooks/pre-commit backstop (CPR-5).
  if (!repoDir || !fs.existsSync(path.join(repoDir, ".prompt-extraction-allowlist"))) {
    return { action: "ok" };
  }

  const agentsDir = resolveAgentsConfigDir();
  if (!agentsDir) {
    return infraBlock("as expected: AGENTS_CONFIG_DIR could not be resolved.", [
      "  - Confirm AGENTS_CONFIG_DIR points at a valid agents checkout.",
      RESOLVE_RAW,
    ]);
  }

  const scriptPath = path
    .join(agentsDir, "bin", "check-prompt-extraction")
    .replace(/\\/g, "/");

  if (!fs.existsSync(scriptPath)) {
    return infraBlock(
      `as expected: bin/check-prompt-extraction not found at ${scriptPath}`,
      [RESOLVE_CONFIG, RESOLVE_RAW]
    );
  }

  const result = spawnSync("bash", [scriptPath, "--staged"], {
    cwd: repoDir,
    encoding: "utf8",
    timeout: 5000,
    // Default maxBuffer is 1 MiB; a large staged set overflows it and Node kills
    // the child with SIGTERM + error.code ENOBUFS — indistinguishable from a
    // timeout by (status, signal) alone. Raise the ceiling AND discriminate on
    // error.code below so ENOBUFS can never take the fail-open path.
    maxBuffer: 10 * 1024 * 1024,
  });

  // Timeout only: fail-open. Keyed on error.code, not (status === null && signal),
  // because ENOBUFS presents with the identical (null, "SIGTERM") shape.
  if (result.error && result.error.code === "ETIMEDOUT") {
    process.stderr.write(
      `[prompt-extraction-gate] bin/check-prompt-extraction --staged timed out (${result.signal || "ETIMEDOUT"}) — failing open\n`
    );
    return { action: "ok" };
  }

  // Output overflow: infrastructure failure, fail-closed.
  if (result.error && result.error.code === "ENOBUFS") {
    return infraBlock(
      "as expected: bin/check-prompt-extraction produced more output than the gate can buffer (ENOBUFS).",
      [RESOLVE_RAW]
    );
  }

  if (result.error) {
    return infraBlock(`as expected: ${result.error.message}`, [
      RESOLVE_BASH,
      RESOLVE_RAW,
    ]);
  }

  // Killed by a signal with no error object attached: cause unknown, fail-closed.
  if (result.status === null) {
    return infraBlock(
      `as expected: bin/check-prompt-extraction was killed by ${result.signal || "an unknown signal"}.`,
      [RESOLVE_BASH, RESOLVE_RAW]
    );
  }

  if (result.status === 1) {
    // The CLI emits HARD: at column 0 (no leading spaces) — contrast Gate 2.
    const hardLines = (result.stdout || "")
      .split("\n")
      .filter((l) => l.startsWith("HARD:"))
      .join("\n");
    return {
      action: "block",
      reason: [
        "workflow-gate: staged prompt file(s) carry un-allowlisted extraction violations",
        "(rules/prompt.md §1.3 inline procedures / §1.5 code fences).",
        hardLines,
        "",
        "Resolve by either:",
        "  - Extract the content: code fences -> skills/<name>/scripts/<verb>.sh,",
        "    multi-step procedures -> bin/<tool>. Then re-stage the file.",
        "  - Unstage the file if it is not part of this change: git restore --staged <file>",
        "",
        "The .prompt-extraction-allowlist ratchet freezes pre-existing debt only —",
        "raising a count to admit new bloat is a ratchet violation.",
        "",
        BYPASS_LINE,
      ].join("\n"),
    };
  }

  if (result.status === 0) {
    return { action: "ok" };
  }

  return infraBlock(`as expected: unexpected exit code ${result.status}.`, [
    RESOLVE_CONFIG,
    RESOLVE_BASH,
    RESOLVE_RAW,
  ]);
}

module.exports = { checkPromptExtraction };
