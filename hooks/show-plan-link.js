#!/usr/bin/env node
// PostToolUse hook: for any final plan artifact written under the plans dir
// (basename *-(intent|outline|detail).md; drafts/ excluded), publish it through
// plan-sync and emit a breadcrumb systemMessage — the blob URL when the push landed
// on a GitHub remote, otherwise the absolute local path plus a [plan-sync] status line.
// Always emits regardless of CONFIRM_<STEP>: the breadcrumb is the sole plan surface.
// Triggers on the whole write-tool class (hooks/lib/write-tools.js): every edit-write tool,
// because a plan revised by Edit/MultiEdit/editFiles must reach the remote like a Write, and
// every command tool running skills/_shared/assemble-mandatory.sh (final-plan assembly).
// All plans of one invocation share one sync budget, so the message lands before the hook timeout.
// Emits { "systemMessage": "..." } only (siblings use `additionalContext`). Design: docs/architecture/claude-code/plan-sync.md.
"use strict";

const path = require("path");
const { normalizeSlashes } = require("./lib/path-match");
const { getSuffix } = require("./lib/plan-confirm-flag");
const { extractAssembleDest } = require("./lib/assemble-cmd-parse");
const { isEditWriteTool, isCommandTool, collectEditWritePaths, commandListOf } = require("./lib/write-tools");

const { readHookInput } = require("./lib/read-stdin");

const RUN_HINT = '— run node "$AGENTS_MAIN_ROOT/bin/plan-sync-init"';
// One budget per invocation, kept below the 30 s hook timeout in settings.json.
const SHARED_SYNC_BUDGET_MS = 20000;

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
  } else if (r.status === "skipped" && r.reason === "budget-exhausted") {
    lines.push("[plan-sync] skipped: shared sync budget exhausted (retry by re-saving the plan)");
  }
  return lines.join("\n");
}

function defaultSync(absPath, opts) {
  const { getWorkflowPlansDir } = require("./lib/workflow-plans-dir");
  const { syncPlanFile } = require("./lib/plan-sync");
  return syncPlanFile(getWorkflowPlansDir(), absPath, { budgetMs: opts.budgetMs });
}

// Windows: native backslash absolute path (Explorer/cmd.exe compatible).
// POSIX:   forward-slash (normalizeSlashes is a no-op on already-forward-slash strings).
function toAbsPath(filePath) {
  const resolved = path.resolve(filePath);
  return process.platform === "win32" ? resolved.replace(/\//g, "\\") : normalizeSlashes(resolved);
}

// candidatePaths(input) -> string[] — every path the tool call wrote, before the plan filter.
function candidatePaths(input) {
  const tool = input.tool_name;
  if (isEditWriteTool(tool)) return collectEditWritePaths(input.tool_input);
  if (isCommandTool(tool)) {
    // Per element, not joined: the parser does not treat "\n" as a command separator.
    return commandListOf(tool, input.tool_input).map(extractAssembleDest).filter(Boolean);
  }
  return [];
}

// finalPlanPaths(input) -> deduplicated final plan artifacts the tool call wrote.
function finalPlanPaths(input) {
  const seen = new Set();
  const out = [];
  for (const p of candidatePaths(input)) {
    if (!isFinalPlanArtifact(p)) continue;
    const key = toAbsPath(p);
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(p);
  }
  return out;
}

// Drop the turn marker (always — required by #563 so the Stop guard sees it regardless
// of CONFIRM_<STEP>).
function markTurn(filePath, absPath, input) {
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
}

// breadcrumbsForArtifacts(filePaths, input, { sync, now, budgetMs }) -> joined systemMessage.
// Never calls sync with budgetMs <= 0: commit-push treats a falsy budget as its 20 s default.
function breadcrumbsForArtifacts(filePaths, input, { sync = defaultSync, now = Date.now, budgetMs = SHARED_SYNC_BUDGET_MS } = {}) {
  const deadline = now() + budgetMs;
  return filePaths.map((filePath) => {
    const absPath = toAbsPath(filePath);
    markTurn(filePath, absPath, input);
    const remaining = deadline - now();
    let result;
    if (remaining <= 0) result = { status: "skipped", reason: "budget-exhausted" };
    else {
      try { result = sync(absPath, { budgetMs: remaining }); } catch (_) { result = { status: "failed", reason: "internal-error" }; }
    }
    return formatBreadcrumb(result, absPath);
  }).join("\n");
}

function emitForArtifacts(filePaths, input) {
  const msg = breadcrumbsForArtifacts(filePaths, input);
  process.stdout.write(JSON.stringify({ systemMessage: msg }));
  process.exit(0);
}

function emitForArtifact(filePath, input) {
  emitForArtifacts([filePath], input);
}

if (require.main === module) {
  const hookInput = readHookInput();
  if (hookInput.kind !== "ok") noopExit();
  const input = hookInput.input;

  const resp = input.tool_response || {};
  const exitCode = resp.exit_code ?? resp.exitCode ?? (resp.success === false ? 1 : 0);
  if (exitCode !== 0) noopExit();

  let plans = [];
  try { plans = finalPlanPaths(input); } catch (_) { /* fail-open */ }
  if (plans.length === 0) noopExit();
  emitForArtifacts(plans, input);
}

module.exports = {
  SHARED_SYNC_BUDGET_MS,
  isFinalPlanArtifact,
  emitForArtifact,
  emitForArtifacts,
  breadcrumbsForArtifacts,
  formatBreadcrumb,
  finalPlanPaths,
};
