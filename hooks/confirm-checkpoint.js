#!/usr/bin/env node
// PreToolUse hook: when Bash emits a <<WORKFLOW_CONFIRM_{INTENT|OUTLINE|DETAIL}>>
// sentinel, surface the relevant plan/PR context above the permission dialog so the
// user can Allow or Deny inline. Sentinel patterns: hooks/lib/confirm-sentinel.js.
// Output: { "systemMessage": "..." } for the user plus PreToolUse additionalContext carrying the
// plan-link line for the model (hooks/lib/plan-link.js); always exit 0, never "allow".
// #2513: the echo is denied (at most twice in a row per stage) when the previous turn did not
// end on the stage's plan-link line, no user prompt came in between, or this turn rewrote the
// plan. #2650: the Stop hook's continuation mark also admits the echo of the same turn.
// Anything unreadable fails open to the plain dialog.
"use strict";

const fs = require("fs");
const path = require("path");

// #2256 S5-a2: Bash/runInTerminal/runCommands normalization (SSOT: hooks/lib/tool-command-text.js).
// The CONFIRM patterns are unanchored, so the joined command text finds the sentinel in any element.
const { isCommandTool, commandTextOf } = require("./lib/tool-command-text");
const { parseSentinel } = require("./lib/confirm-sentinel");
const { peekTurnMarkers, takeContinuationMark } = require("./lib/turn-marker");
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

// #2650 same-turn path: the Stop hook's mark is anchored in this turn, only this echo followed
// it, and the mark still binds the approval target (path, link shown, sha) the dialog shows.
function sameTurnAccepted(turns, absPath, link, ctx) {
  const { sid, stage, toolUseId, taken } = ctx;
  if (!taken || !taken.ok) return false;
  const CC = require("./lib/confirm-continuation");
  if (!CC.sameTurnContinuation(turns.currentTurnEntries, taken.mark, toolUseId)) return false;
  if (!CC.samePath(absPath, CC.approvalArtifactPath(sid, stage))) return false;
  const { computeArtifactSha } = require("./workflow-state/completion-approval");
  const { stepForSuffix } = require("./workflow-state/plan-stage-table");
  return CC.markBindsArtifact(taken.mark, { absPath, link, sha: computeArtifactSha(sid, stepForSuffix(stage)) });
}

// isDenyCandidate(absPath, link, transcriptPath, ctx) -> true / false, or null to fail open.
function isDenyCandidate(absPath, link, transcriptPath, ctx) {
  const TC = require("./lib/plan-link-turn-check");
  if (TC.shown(link, "") === null) return null;
  const turns = require("./lib/transcript-reader").readPreviousTurn({ transcriptPath });
  if (!turns.readable) return null;
  if (sameTurnAccepted(turns, absPath, link, ctx)) return false;
  if (!turns.hasPriorPrompt) return true;
  if (TC.shown(link, TC.lastTextBlockOf(turns.prevTurnEntries) || "") === false) return true;
  return TC.currentTurnWritesStage(turns.currentTurnEntries, absPath);
}

function emitDeny(stage) {
  const reason = require("./lib/confirm-continuation").sameTurnDenyReason(stage);
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
function judge(sid, stage, absPath, link, transcriptPath, ctx) {
  const counter = require("./lib/confirm-deny-counter");
  let candidate = null;
  try {
    candidate = isDenyCandidate(absPath, link, transcriptPath, Object.assign({ sid, stage }, ctx));
  } catch (_) { candidate = null; }
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

  // The continuation mark is one-shot: consumed here, before any early exit, whatever follows.
  let taken = { ok: false, reason: "absent" };
  try { if (sid) taken = takeContinuationMark(sid, stage); } catch (_) { /* fail-open */ }

  // The shared plan gate (#2650): ERROR shows the dialog, like ON; intent has no off waiver.
  let gate = "ERROR";
  try { gate = require("./lib/confirm-gate/plan-gate").planGateState(stage); } catch (_) { /* dialog */ }
  if (gate === "OFF") {
    process.stdout.write(JSON.stringify({ systemMessage: `[confirm-skipped: CONFIRM_${stage.toUpperCase()}=off]` }));
    process.exit(0);
  }

  let link = null;
  try { link = planLinkOutput(stage, absPath, plansDir); } catch (_) { /* fail-open: the local path is shown */ }

  const ctx = { toolUseId: input.tool_use_id, taken };
  const verdict = sid && link ? judge(sid, stage, absPath, link.link, input.transcript_path, ctx) : "pass";
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
