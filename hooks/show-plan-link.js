#!/usr/bin/env node
// PostToolUse hook: for any final plan artifact written under the plans dir
// (basename *-(intent|outline|detail).md; drafts/ excluded), record the project's host beside
// it (from the hook input's cwd only), then publish it through plan-sync. A failed record
// write sends nothing. Triggers on the whole write-tool class (hooks/lib/write-tools.js) and
// on command tools running skills/_shared/assemble-mandatory.sh (final-plan assembly).
// A written <sid>-session-progress.md is recorded and synced the same way, silently (#2594).
// Output: PostToolUse additionalContext always carries one plan-link line per plan
// (hooks/lib/plan-link.js); the systemMessage breadcrumb is added only when the user should
// see a problem (no URL for a reason other than the project-host verdict).
// All plans of one invocation share one sync budget. Design: docs/architecture/claude-code/plan-sync.md.
"use strict";

const fs = require("fs");
const path = require("path");
const { normalizeSlashes } = require("./lib/path-match");
const { getSuffix } = require("./lib/plan-confirm-flag");
const { extractAssembleDest } = require("./lib/assemble-cmd-parse");
const { isEditWriteTool, isCommandTool, collectEditWritePaths, commandListOf } = require("./lib/write-tools");

const { readHookInput } = require("./lib/read-stdin");

const RUN_HINT = 'node "$AGENTS_MAIN_ROOT/bin/plan-sync-init"';
// One budget per invocation, kept below the 30 s hook timeout in settings.json.
const SHARED_SYNC_BUDGET_MS = 20000;
// Skip reasons that are the project-host verdict itself: shown to the model, not the user.
const QUIET_SKIP_REASONS = new Set(["host-mismatch", "no-project-host"]);

function noopExit() {
  process.stdout.write("");
  process.exit(0);
}

function isFinalPlanArtifact(filePath) {
  return getSuffix(filePath) !== null;
}

// The explanation of a breadcrumb state, for the model only (additionalContext); the user sees facts.
const EXPLANATIONS = {
  "no-blob-url": "plan-sync pushed the plan, but this remote has no blob URL.",
  off: "plan-sync is not configured: PLAN_SYNC_REMOTE_URL is empty.",
  "not-regular-file": "plan-sync skipped the plan: it is not a regular file (symlink, directory, or missing).",
  "budget-exhausted": "plan-sync skipped the plan: the shared sync budget ran out; retry by re-saving the plan.",
};

function explanationKey(result) {
  const r = result || {};
  if (r.status === "pushed" && !r.url) return "no-blob-url";
  return r.status === "off" ? "off" : (r.status === "skipped" ? r.reason : null);
}

// formatBreadcrumb(result, absPath) — the 1-2 fact lines for one syncPlanFile result.
function formatBreadcrumb(result, absPath) {
  const r = result || {};
  if (r.status === "pushed" && r.url) return `[plan-file] ${r.url}`;
  const lines = [`[plan-file] ${absPath}`];
  if (r.status === "pushed") lines.push("[plan-sync] pushed no-blob-url");
  else if (r.status === "off") lines.push("[plan-sync] off PLAN_SYNC_REMOTE_URL=");
  else if (r.status === "not-provisioned" || r.status === "failed") {
    lines.push(`[plan-sync] ${r.reason || r.status} ${RUN_HINT}`);
  } else if (r.status === "skipped" && (r.reason === "not-regular-file" || r.reason === "budget-exhausted")) {
    lines.push(`[plan-sync] skipped ${r.reason}`);
  } else if (r.status === "skipped" && QUIET_SKIP_REASONS.has(r.reason)) {
    lines.push(`[plan-sync] not-sent ${r.reason}`);
  }
  return lines.join("\n");
}

function defaultSync(absPath, opts) {
  const { getWorkflowPlansDir } = require("./lib/workflow-plans-dir");
  const { syncPlanFile } = require("./lib/plan-sync");
  return syncPlanFile(getWorkflowPlansDir(), absPath, { budgetMs: opts.budgetMs });
}

// The project is the hook input's cwd alone: CLAUDE_PROJECT_DIR, the process cwd and the cwd
// saved in the session state may name another project than the one the plan was written for.
function recordHost(absPath, input) {
  const { recordProjectHost } = require("./lib/plan-sync");
  return recordProjectHost(absPath, typeof input.cwd === "string" ? input.cwd : null);
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

// progressPaths(input) -> deduplicated <sid>-session-progress.md files (direct children of the plans dir)
// the tool call wrote. session-progress.md is not a plan to confirm (#2594): it is recorded and synced
// only — no turn marker, no plan link, nothing shown to the user or the model.
function progressPaths(input) {
  if (!isEditWriteTool(input.tool_name)) return [];
  const { getWorkflowPlansDir } = require("./lib/workflow-plans-dir");
  const { parsePlansEntry } = require("./lib/plans-artifact-registry");
  const { isSyncTarget } = require("./lib/plan-sync/allowlist");
  const plansDir = getWorkflowPlansDir();
  const seen = new Set();
  const out = [];
  for (const p of collectEditWritePaths(input.tool_input)) {
    const parsed = parsePlansEntry(path.basename(p));
    if (!parsed || parsed.kind !== "progress" || !isSyncTarget(plansDir, p)) continue;
    const key = toAbsPath(p);
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(key);
  }
  return out;
}

// syncProgressQuietly(absPaths, input, budgetMs) -> remaining budget. A failed record write
// sends nothing; every failure is swallowed (fail-open).
function syncProgressQuietly(absPaths, input, { sync = defaultSync, now = Date.now, budgetMs = SHARED_SYNC_BUDGET_MS } = {}) {
  const deadline = now() + budgetMs;
  for (const absPath of absPaths) {
    try {
      if (!fs.lstatSync(absPath).isFile() || !recordHost(absPath, input || {}).ok) continue;
      const remaining = deadline - now();
      if (remaining <= 0) break;
      sync(absPath, { budgetMs: remaining });
    } catch (_) { /* fail-open */ }
  }
  return Math.max(0, deadline - now());
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

function pathExists(absPath) {
  try { fs.lstatSync(absPath); return true; } catch (_) { return false; }
}

// runArtifacts(filePaths, input, opts) -> [{filePath, absPath, result}] — per plan: record the
// project host, drop the turn marker, then sync. A failed record write never reaches sync.
// An absent plan gets no record: there is nothing to send, and sync reports it as absent.
// Never calls sync with budgetMs <= 0: commit-push treats a falsy budget as its 20 s default.
function runArtifacts(filePaths, input, { sync = defaultSync, now = Date.now, budgetMs = SHARED_SYNC_BUDGET_MS } = {}) {
  const deadline = now() + budgetMs;
  return filePaths.map((filePath) => {
    const absPath = toAbsPath(filePath);
    let recorded = !pathExists(absPath);
    if (!recorded) {
      try { recorded = Boolean(recordHost(absPath, input || {}).ok); } catch (_) { recorded = false; }
    }
    markTurn(filePath, absPath, input || {});
    const remaining = deadline - now();
    let result;
    if (!recorded) result = { status: "failed", reason: "internal-error" };
    else if (remaining <= 0) result = { status: "skipped", reason: "budget-exhausted" };
    else {
      try { result = sync(absPath, { budgetMs: remaining }); } catch (_) { result = { status: "failed", reason: "internal-error" }; }
    }
    return { filePath, absPath, result };
  });
}

// breadcrumbsForArtifacts(filePaths, input, { sync, now, budgetMs }) -> joined breadcrumb text.
function breadcrumbsForArtifacts(filePaths, input, opts) {
  return runArtifacts(filePaths, input, opts).map((r) => formatBreadcrumb(r.result, r.absPath)).join("\n");
}

// The user sees a breadcrumb unless the plan got its URL or the project-host verdict held it back.
function showsMessage(result) {
  const r = result || {};
  if (r.status === "pushed" && r.url) return false;
  return !(r.status === "skipped" && QUIET_SKIP_REASONS.has(r.reason));
}

// gateOf(stage, timeoutMs) -> the stage's own gate (#2729); never aggregated across stages, so a
// mixed write gets one duty per stage. A spent budget or a throw is ERROR, which renders as ON.
function gateOf(stage, timeoutMs) {
  try {
    const { NEXT_STEP_GATE_PROBE_TIMEOUT_MS } = require("../bin/workflow/lib/next-step/gate-line");
    const { planGateState } = require("./lib/confirm-gate/plan-gate");
    return planGateState(stage, { timeoutMs: Math.min(NEXT_STEP_GATE_PROBE_TIMEOUT_MS, timeoutMs) });
  } catch (_) {
    return "ERROR";
  }
}

// entryFor(run, gateTimeoutMs) -> {stage, gate, url?, path?, reason?} — the plan-link row of one written plan.
function entryFor(run, gateTimeoutMs) {
  return { ...linkEntryFor(run), gate: gateOf(getSuffix(run.filePath), gateTimeoutMs) };
}

function linkEntryFor(run) {
  const PL = require("./lib/plan-link");
  const stage = getSuffix(run.filePath);
  const r = run.result || {};
  // Not a regular file: the path may name what a link points at, so only the stage is shown.
  if (r.status === "skipped" && r.reason === "not-regular-file") return { stage, reason: PL.REASONS.NOT_PUBLISHED };
  const fromSync = PL.linkFromSyncResult(r);
  if (fromSync.url) return { stage, url: fromSync.url, path: run.absPath };
  if (fromSync.reason !== PL.REASONS.NOT_PUBLISHED) return { stage, path: run.absPath, reason: fromSync.reason };
  // Not pushed now: the plan may still be at the destination unchanged from an earlier write.
  let link = {};
  try { link = PL.linkForFile(run.absPath); } catch (_) { link = {}; }
  if (link.url) return { stage, url: link.url, path: run.absPath };
  return { stage, path: run.absPath, reason: fromSync.reason };
}

// opts.afterSync(remainingMs) (optional) runs once the plans are synced, before the exit.
function emitForArtifacts(filePaths, input, opts) {
  const o = opts || {};
  const clock = o.now || Date.now;
  const start = clock();
  const budgetMs = o.budgetMs === undefined ? SHARED_SYNC_BUDGET_MS : o.budgetMs;
  const runs = runArtifacts(filePaths, input, opts);
  if (typeof o.afterSync === "function") {
    try { o.afterSync(Math.max(0, budgetMs - (clock() - start))); } catch (_) { /* fail-open */ }
  }
  const out = {};
  try {
    const { renderModelContext } = require("./lib/plan-link");
    const { withConvLang } = require("./lib/conv-lang");
    const notes = runs.map((r) => explanationKey(r.result))
      .filter((k) => Object.prototype.hasOwnProperty.call(EXPLANATIONS, k)).map((k) => EXPLANATIONS[k]);
    const deadline = start + budgetMs;
    const entries = runs.map((r) => entryFor(r, Math.max(0, deadline - clock())));
    const rows = renderModelContext(entries, { when: "after-write" });
    out.hookSpecificOutput = {
      hookEventName: "PostToolUse",
      additionalContext: withConvLang([rows, ...notes].join("\n")),
    };
  } catch (_) { /* fail-open: the breadcrumb below still reaches the user */ }
  const shown = runs.filter((r) => !out.hookSpecificOutput || showsMessage(r.result));
  if (shown.length > 0) out.systemMessage = shown.map((r) => formatBreadcrumb(r.result, r.absPath)).join("\n");
  process.stdout.write(JSON.stringify(out));
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
  let progress = [];
  try { progress = progressPaths(input); } catch (_) { /* fail-open */ }
  // The plans of this call and its session-progress.md share the one sync budget; the plans
  // go first, so session-progress.md gets only what they leave.
  const syncProgress = (budgetMs) => {
    if (progress.length > 0) syncProgressQuietly(progress, input, { budgetMs });
  };
  if (plans.length === 0) {
    try { syncProgress(SHARED_SYNC_BUDGET_MS); } catch (_) { /* fail-open */ }
    noopExit();
  }
  emitForArtifacts(plans, input, { budgetMs: SHARED_SYNC_BUDGET_MS, afterSync: syncProgress });
}

module.exports = {
  SHARED_SYNC_BUDGET_MS,
  isFinalPlanArtifact,
  emitForArtifact,
  emitForArtifacts,
  breadcrumbsForArtifacts,
  formatBreadcrumb,
  finalPlanPaths,
  progressPaths,
};
