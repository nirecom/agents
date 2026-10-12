#!/usr/bin/env node
// PreToolUse hook: when Bash emits a <<WORKFLOW_CONFIRM_{INTENT|OUTLINE|DETAIL}>>
// sentinel, surface the relevant plan/PR context above the permission dialog so the
// user can Allow or Deny inline. Sentinel patterns: hooks/lib/confirm-sentinel.js.
// Output: { "systemMessage": "..." } for the user plus PreToolUse additionalContext carrying the
// plan-link line for the model (hooks/lib/plan-link.js); always exit 0, never "allow".
// #2513: the echo is denied (at most twice in a row per stage) when the previous turn did not
// end on the stage's plan-link line, no user prompt came in between, or this turn rewrote the
// plan. Anything unreadable fails open to the plain dialog.
"use strict";

const fs = require("fs");
const path = require("path");

// #2256 S5-a2: Bash/runInTerminal/runCommands normalization (SSOT: hooks/lib/tool-command-text.js).
// The CONFIRM patterns are unanchored, so the joined command text finds the sentinel in any element.
const { isCommandTool, commandTextOf } = require("./lib/tool-command-text");
const { parseSentinel } = require("./lib/confirm-sentinel");
const { peekTurnMarkers } = require("./lib/turn-marker");
const { resolveSessionId } = require("./workflow-state");
const { getWorkflowPlansDir } = require("./lib/workflow-plans-dir");
const { loadDefaultEnv } = require("./lib/load-env");

const { readHookInput } = require("./lib/read-stdin");

const DENY_CAP = 2;

function noopExit() { process.stdout.write(""); process.exit(0); }

// Resolve absolute path to <stage>.md artifact for the current session.
// Multi-turn scenario: Stop hook deletes markers at turn end. When user emits
// sentinel after a follow-up message, marker peek returns nothing → PLANS_DIR
// fallback is the primary resolution path, not a degraded path.
function resolveArtifact(stage, sid, plansDir) {
  // 1. Turn-marker peek (only valid within the same turn that wrote the marker).
  if (sid) {
    try {
      const markers = peekTurnMarkers(sid);
      for (const m of markers) {
        if (m && m.suffix === stage && typeof m.absPath === "string" && m.absPath.length > 0) {
          return m.absPath;
        }
      }
    } catch (_) { /* fail-open */ }
  }
  // 2. PLANS_DIR fallback: <PLANS_DIR>/<sid>-<stage>.md
  if (sid && plansDir) {
    const candidate = path.join(plansDir, `${sid}-${stage}.md`);
    try {
      if (fs.existsSync(candidate)) return candidate;
    } catch (_) { /* fail-open */ }
  }
  return null;
}

// url: the published blob URL (hooks/lib/plan-link.js), shown together with the local path.
function renderMessage(stage, absPath, url) {
  if (absPath) {
    const shownAs = url ? `${url} (${absPath})` : absPath;
    return `[${stage}] Plan file: ${shownAs}\nClick Allow to proceed, Deny to abort.`;
  }
  return `[${stage}] Plan ready (file path unavailable)\nClick Allow to proceed, Deny to abort.`;
}

// planLinkOutput(stage, absPath, plansDir) -> {link, url, additionalContext} — the model-facing
// line of the plan being confirmed. Throws when plan-link is unusable; the caller fails open.
function planLinkOutput(stage, absPath, plansDir) {
  const PL = require("./lib/plan-link");
  const link = absPath ? PL.linkForFile(absPath, plansDir ? { plansDir } : {}) : { reason: PL.REASONS.NO_ARTIFACT };
  const entry = { stage, url: link.url, path: link.path, reason: link.reason };
  return { link, url: link.url || null, additionalContext: PL.renderModelContext([entry], { when: "confirm" }) };
}

// isDenyCandidate(absPath, link, transcriptPath) -> true / false, or null to fail open.
function isDenyCandidate(absPath, link, transcriptPath) {
  const TC = require("./lib/plan-link-turn-check");
  if (TC.shown(link, "") === null) return null;
  const turns = require("./lib/transcript-reader").readPreviousTurn({ transcriptPath });
  if (!turns.readable) return null;
  if (!turns.hasPriorPrompt) return true;
  if (TC.shown(link, TC.lastTextBlockOf(turns.prevTurnEntries) || "") === false) return true;
  return TC.currentTurnWritesStage(turns.currentTurnEntries, absPath);
}

// The reason names only the stage and the plan-link command — never a URL, a path or the sid.
function denyReason(stage) {
  const cmd = require("./lib/plan-link").PLAN_LINK_COMMAND.replace("<stage>", stage);
  return `[confirm-checkpoint] CONFIRM_${stage.toUpperCase()} denied: the ${stage} plan was not presented ` +
    `with its plan-link line in the previous turn. Run ${cmd}, end the last text block of a turn with its ` +
    "output as-is and close the turn, then echo the CONFIRM in the turn after the user's reply " +
    "(without rewriting the plan in that turn).";
}

function emitDeny(stage) {
  const reason = denyReason(stage);
  process.stdout.write(JSON.stringify({
    decision: "block",
    reason,
    hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: reason },
  }));
  process.exit(0);
}

function recordCapFinding(sid, stage) {
  try {
    require("./lib/supervisor-state-writer").appendFinding(sid, {
      categories: ["workflow"],
      severity: "warning",
      detail: `confirm-checkpoint: CONFIRM_${stage.toUpperCase()} passed at the deny cap (${DENY_CAP}) without the plan-link presentation`,
      reporter: "confirm-checkpoint",
    });
  } catch (_) { /* fail-open */ }
}

// judge(...) -> "deny" | "cap" | "pass". Counter state decides between deny and the capped pass.
function judge(sid, stage, absPath, link, transcriptPath) {
  const counter = require("./lib/confirm-deny-counter");
  let candidate = null;
  try { candidate = isDenyCandidate(absPath, link, transcriptPath); } catch (_) { candidate = null; }
  if (candidate === null) return "pass";
  if (!candidate) {
    counter.reset(sid, stage);
    return "pass";
  }
  const count = counter.bump(sid, stage);
  if (count === null) return "pass";
  if (count <= DENY_CAP) return "deny";
  recordCapFinding(sid, stage);
  counter.reset(sid, stage);
  return "cap";
}

function confirmOffFor(stage) {
  const flagName = `CONFIRM_${stage.toUpperCase()}`;
  const rawFlag = process.env[flagName];
  return { flagName, off: rawFlag != null && rawFlag.toLowerCase().trim() === "off" };
}

// offWaivable from the stage table: intent has no off waiver (#2277).
function offWaivable(stage) {
  try {
    const { rowFor, stepForSuffix } = require("./workflow-state/plan-stage-table");
    const row = rowFor(stepForSuffix(stage));
    return !row || row.offWaivable;
  } catch (_) {
    // An unloadable table must not open an off waiver for intent (#2277); fail closed there.
    return stage !== "intent";
  }
}

function main() {
  try { loadDefaultEnv(); } catch (_) {}
  const hookInput = readHookInput();
  if (hookInput.kind !== "ok") noopExit();
  const input = hookInput.input;

  if (!isCommandTool(input.tool_name)) noopExit();

  const parsed = parseSentinel(commandTextOf(input.tool_name, input.tool_input));
  if (!parsed) noopExit();
  const stage = parsed.stage;

  let sid = null;
  try {
    sid = resolveSessionId({ sessionIdFromInput: input.session_id, transcriptPath: input.transcript_path });
  } catch (_) { /* fail-open */ }

  let plansDir = null;
  try { plansDir = getWorkflowPlansDir(); } catch (_) { /* fail-open */ }

  const absPath = resolveArtifact(stage, sid, plansDir);

  // CONFIRM_<STAGE>=off read directly from env — works even when absPath is null.
  const { flagName, off } = confirmOffFor(stage);
  if (off && offWaivable(stage)) {
    process.stdout.write(JSON.stringify({ systemMessage: `[confirm-skipped: ${flagName}=off]` }));
    process.exit(0);
  }

  let link = null;
  try { link = planLinkOutput(stage, absPath, plansDir); } catch (_) { /* fail-open: the local path is shown */ }

  const verdict = sid && link ? judge(sid, stage, absPath, link.link, input.transcript_path) : "pass";
  if (verdict === "deny") emitDeny(stage);

  const capNote = verdict === "cap"
    ? `[${stage}] plan-link deny cap reached (${DENY_CAP} denies in a row) — passed to the dialog.\n`
    : "";
  const out = { systemMessage: capNote + renderMessage(stage, absPath, link && link.url) };
  if (link || capNote) {
    out.hookSpecificOutput = { hookEventName: "PreToolUse", additionalContext: capNote + (link ? link.additionalContext : "") };
  }
  process.stdout.write(JSON.stringify(out));
  process.exit(0);
}

if (require.main === module) main();

module.exports = { parseSentinel, renderMessage, resolveArtifact };
