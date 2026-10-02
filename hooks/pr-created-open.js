#!/usr/bin/env node
// PostToolUse hook: when `gh pr create` succeeds, open the PR URL in the
// default browser and emit a one-line systemMessage with PR #N + URL.
//
// Fast-fail chain: tool_name !== Bash → command lacks "gh pr create" → exit
// code non-zero → no PR URL in stdout. Any of these is a silent no-op.
//
// Fail-open everywhere: hook errors must never block the workflow.
"use strict";

const fs = require("fs");
const { openInBrowser } = require("./lib/open-external");

const { readHookInput, readFailOpenDiagnostic } = require("./lib/read-stdin");

function noopExit() { process.stdout.write(""); process.exit(0); }

if (require.main === module) {
  const r = readHookInput();
  if (r.kind !== "ok") {
    try {
      fs.writeSync(2, readFailOpenDiagnostic("pr-created-open", r, "pr-created not recorded") + "\n");
    } catch (_) {}
    noopExit();
  }
  const input = r.input;

  if (input.tool_name !== "Bash") noopExit();

  const command = (input.tool_input && input.tool_input.command) || "";
  if (!command.includes("gh pr create")) noopExit();

  const resp = input.tool_response || {};
  const exitCode = resp.exit_code ?? resp.exitCode ?? (resp.success === false ? 1 : 0);
  if (exitCode !== 0) noopExit();

  const stdout = (resp.stdout || "");
  const match = stdout.match(/(https?:\/\/github\.com\/[^/\s]+\/[^/\s]+\/pull\/\d+)/);
  if (!match) noopExit();

  const prUrl = match[1];
  try { openInBrowser(prUrl); } catch (_) { /* fail-open */ }

  const n = prUrl.match(/\/pull\/(\d+)/);
  const msg = n
    ? `PR #${n[1]} created: ${prUrl}\nClick Allow to proceed, Deny to abort.`
    : `PR created: ${prUrl}\nClick Allow to proceed, Deny to abort.`;

  process.stdout.write(JSON.stringify({ systemMessage: msg }));
  process.exit(0);
}
