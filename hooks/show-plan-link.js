#!/usr/bin/env node
// PostToolUse hook: emit a systemMessage with the absolute path of any final
// plan artifact written under ~/.workflow-plans/ (basename *-(intent|outline|detail).md;
// drafts/ excluded). Always emits regardless of CONFIRM_<STEP> — breadcrumb is the sole
// path surface for orchestrators (#445: VS Code auto-open removed).
//
// Output protocol: emits { "systemMessage": "..." } only.
// Sibling PostToolUse hooks emit `additionalContext` — different field, no collision.
"use strict";

const fs = require("fs");
const path = require("path");
const { normalizeSlashes } = require("./lib/path-match");
const { getSuffix } = require("./lib/plan-confirm-flag");

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(65536);
  try {
    while (true) {
      const n = fs.readSync(0, buf, 0, buf.length);
      if (n === 0) break;
      chunks.push(buf.slice(0, n));
    }
  } catch (_) {}
  return Buffer.concat(chunks).toString("utf8");
}

function noopExit() {
  process.stdout.write("");
  process.exit(0);
}

function isFinalPlanArtifact(filePath) {
  return getSuffix(filePath) !== null;
}

if (require.main === module) {
  let input = {};
  try { input = JSON.parse(readStdin()); } catch { noopExit(); }

  if (input.tool_name !== "Write") noopExit();

  // Defensive tool_response check (mirrors workflow-run-tests.js pattern).
  const resp = input.tool_response || {};
  const exitCode = resp.exit_code ?? resp.exitCode ?? (resp.success === false ? 1 : 0);
  if (exitCode !== 0) noopExit();

  const filePath = (input.tool_input && input.tool_input.file_path) || "";
  if (!isFinalPlanArtifact(filePath)) noopExit();

  // Windows: native backslash absolute path (Explorer/cmd.exe compatible).
  // POSIX:   forward-slash (normalizeSlashes is a no-op on already-forward-slash strings).
  const resolved = path.resolve(filePath);
  const absPath = process.platform === "win32"
    ? resolved.replace(/\//g, "\\")
    : normalizeSlashes(resolved);

  process.stdout.write(JSON.stringify({ systemMessage: `Plan file written: ${absPath}` }));
  process.exit(0);
}

module.exports = { isFinalPlanArtifact };
