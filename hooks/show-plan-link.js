#!/usr/bin/env node
// PostToolUse hook: emit a systemMessage with the absolute path of any final
// plan artifact written under ~/.workflow-plans/ (basename *-(intent|outline|detail).md;
// drafts/ excluded). Always emits regardless of CONFIRM_<STEP> — breadcrumb is the sole
// path surface for orchestrators. When CONFIRM_<STEP>=on AND VS Code is detected,
// additionally spawns a single `code --folder-uri <uri> <filePath>` invocation (raises
// window and opens file atomically; avoids two-spawn timing race #546 Gap 3).
//
// Triggers on Write (direct file write) and on Bash invocations of
// skills/_shared/assemble-mandatory.sh — the latter is how SKILL.md authors
// assemble the final plan artifact from a draft + planner output.
//
// Output protocol: emits { "systemMessage": "..." } only.
// Sibling PostToolUse hooks emit `additionalContext` — different field, no collision.
"use strict";

const fs = require("fs");
const path = require("path");
const { normalizeSlashes } = require("./lib/path-match");
const { getSuffix, isConfirmOff } = require("./lib/plan-confirm-flag");
const { extractAssembleDest } = require("./lib/assemble-cmd-parse");
const { shouldOpenInVsCode, workspaceFolderUriFrom, resolveWorkspaceFolderUri, openInVsCode } = require("./lib/vscode-open");

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

// Core emit: write the systemMessage breadcrumb, drop the turn marker
// (always — required by #563 so the Stop guard sees it regardless of
// CONFIRM_<STEP>), and optionally open VS Code (still gated by CONFIRM_<STEP>).
function emitForArtifact(filePath, input) {
  // Windows: native backslash absolute path (Explorer/cmd.exe compatible).
  // POSIX:   forward-slash (normalizeSlashes is a no-op on already-forward-slash strings).
  const resolved = path.resolve(filePath);
  const absPath = process.platform === "win32"
    ? resolved.replace(/\//g, "\\")
    : normalizeSlashes(resolved);

  if (!isConfirmOff(filePath) && shouldOpenInVsCode()) {
    try { openInVsCode(absPath, resolveWorkspaceFolderUri(input)); } catch (_) { /* fail-open */ }
  }
  // Marker write is always-on (#563): the Stop guard's scan is
  // CONFIRM_<STEP>-independent — marker presence alone activates it.
  try {
    const { resolveSessionId } = require("./lib/workflow-state");
    const sid = resolveSessionId({
      sessionIdFromInput: input.session_id,
      transcriptPath: input.transcript_path,
    });
    if (sid) {
      const { writeTurnMarker } = require("./lib/turn-marker");
      writeTurnMarker(sid, {
        absPath,
        suffix: getSuffix(filePath),
        ts: Date.now(),
        created_at: new Date().toISOString(),
      });
    }
  } catch (_) { /* fail-open */ }
  process.stdout.write(JSON.stringify({ systemMessage: `Plan file written: ${absPath}` }));
  process.exit(0);
}

if (require.main === module) {
  let input = {};
  try { input = JSON.parse(readStdin()); } catch { noopExit(); }

  const resp = input.tool_response || {};
  const exitCode = resp.exit_code ?? resp.exitCode ?? (resp.success === false ? 1 : 0);
  if (exitCode !== 0) noopExit();

  let filePath = "";
  if (input.tool_name === "Write") {
    filePath = (input.tool_input && input.tool_input.file_path) || "";
  } else if (input.tool_name === "Bash") {
    const cmd = (input.tool_input && input.tool_input.command) || "";
    filePath = extractAssembleDest(cmd) || "";
  } else {
    noopExit();
  }

  if (!isFinalPlanArtifact(filePath)) noopExit();
  emitForArtifact(filePath, input);
}

module.exports = { isFinalPlanArtifact, workspaceFolderUriFrom, emitForArtifact };
