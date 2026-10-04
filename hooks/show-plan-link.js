#!/usr/bin/env node
// PostToolUse hook: for any final plan artifact written under the plans dir
// (basename *-(intent|outline|detail).md; drafts/ excluded), publish it through
// plan-sync and emit a breadcrumb systemMessage — the blob URL when the push landed
// on a GitHub remote, otherwise the absolute local path plus a [plan-sync] status line.
// Always emits regardless of CONFIRM_<STEP>: the breadcrumb is the sole plan surface.
// Triggers on Write and on Bash invocations of skills/_shared/assemble-mandatory.sh
// (how SKILL.md authors assemble the final plan artifact from a draft + planner output).
// Emits { "systemMessage": "..." } only; sibling hooks use `additionalContext`.
// Design: docs/architecture/claude-code/plan-sync.md.
"use strict";

const path = require("path");
const { normalizeSlashes } = require("./lib/path-match");
const { getSuffix } = require("./lib/plan-confirm-flag");
const { extractAssembleDest } = require("./lib/assemble-cmd-parse");

const { readHookInput } = require("./lib/read-stdin");

const RUN_HINT = '— run node "$AGENTS_CONFIG_DIR/bin/plan-sync-init"';

function noopExit() {
  process.stdout.write("");
  process.exit(0);
}

function isFinalPlanArtifact(filePath) {
  return getSuffix(filePath) !== null;
}

// formatBreadcrumb(result, absPath) — the 1-2 line message for one syncPlanFile result.
function formatBreadcrumb(result, absPath) {
  const r = result || {};
  if (r.status === "pushed" && r.url) return `Plan file: ${r.url}`;
  const lines = [`Plan file: ${absPath}`];
  if (r.status === "pushed") lines.push("[plan-sync] pushed (non-GitHub remote; no URL)");
  else if (r.status === "off") lines.push("[plan-sync] not configured (PLAN_SYNC_REMOTE_URL empty)");
  else if (r.status === "not-provisioned" || r.status === "failed") {
    lines.push(`[plan-sync] ${r.reason || r.status} ${RUN_HINT}`);
  } else if (r.status === "skipped" && r.reason === "not-regular-file") {
    lines.push("[plan-sync] skipped: not a regular file (symlink, directory, or missing)");
  }
  return lines.join("\n");
}

function syncResult(absPath) {
  try {
    const { getWorkflowPlansDir } = require("./lib/workflow-plans-dir");
    const { syncPlanFile } = require("./lib/plan-sync");
    return syncPlanFile(getWorkflowPlansDir(), absPath);
  } catch (_) {
    return { status: "failed", reason: "internal-error" };
  }
}

// Core emit: drop the turn marker (always — required by #563 so the Stop guard
// sees it regardless of CONFIRM_<STEP>), sync the file, then write the breadcrumb.
function emitForArtifact(filePath, input) {
  // Windows: native backslash absolute path (Explorer/cmd.exe compatible).
  // POSIX:   forward-slash (normalizeSlashes is a no-op on already-forward-slash strings).
  const resolved = path.resolve(filePath);
  const absPath = process.platform === "win32"
    ? resolved.replace(/\//g, "\\")
    : normalizeSlashes(resolved);

  // Marker write is always-on (#563): the Stop guard's scan is
  // CONFIRM_<STEP>-independent — marker presence alone activates it.
  try {
    const { resolveSessionId } = require("./workflow-state");
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
  const msg = formatBreadcrumb(syncResult(absPath), absPath);
  process.stdout.write(JSON.stringify({ systemMessage: msg }));
  process.exit(0);
}

if (require.main === module) {
  const hookInput = readHookInput();
  if (hookInput.kind !== "ok") noopExit();
  const input = hookInput.input;

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

module.exports = { isFinalPlanArtifact, emitForArtifact, formatBreadcrumb };
