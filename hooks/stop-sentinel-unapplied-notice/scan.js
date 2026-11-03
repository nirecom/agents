"use strict";
// Classifies this turn's sentinel Bash calls that workflow-mark.js never finished (#2877).
// Order: is_error result (a PreToolUse or permission deny, told elsewhere) -> skip; a PostToolUse
// hook_cancelled for the same tool_use -> timeout; no receipt -> unreached; receipt, no outcome ->
// midway. A receipt with an outcome was told by workflow-mark.js itself.

const { parseLines, splitTurns } = require("../lib/transcript-reader");
const { analyzeSentinelCommand } = require("../lib/sentinel-command");
const { hasLineSentinel } = require("../workflow-mark/line-sentinel");
const { cancelOf } = require("../lib/hook-cancel-notice");

const KIND = Object.freeze({ TIMEOUT: "timeout", UNREACHED: "unreached", MIDWAY: "midway" });

function contentOf(entry) {
  const c = entry && entry.message && entry.message.content;
  return Array.isArray(c) ? c.filter((it) => it && typeof it === "object") : [];
}

// sentinelCallsOf(entries) -> [{id, command}] for the Bash tool_use blocks that carry a sentinel.
function sentinelCallsOf(entries) {
  const calls = [];
  for (const e of entries) {
    if (e.type !== "assistant") continue;
    for (const it of contentOf(e)) {
      if (it.type !== "tool_use" || typeof it.id !== "string" || !it.input) continue;
      const command = String(it.input.command || "").trim();
      // #1981: a sentinel statement of a multi-statement script counts too (CPR-ORTH with workflow-mark).
      if (!analyzeSentinelCommand(it.name, it.input).sentinelPresent && !hasLineSentinel(command)) continue;
      calls.push({ id: it.id, command });
    }
  }
  return calls;
}

function erroredIdsOf(entries) {
  const ids = new Set();
  for (const e of entries) {
    if (e.type !== "user") continue;
    for (const it of contentOf(e)) {
      if (it.type === "tool_result" && it.is_error === true && typeof it.tool_use_id === "string") ids.add(it.tool_use_id);
    }
  }
  return ids;
}

function cancelledIdsOf(entries) {
  const ids = new Set();
  for (const e of entries) {
    if (e.type !== "attachment") continue;
    const cancel = cancelOf(JSON.stringify(e), "PostToolUse");
    if (cancel && cancel.toolUseId) ids.add(cancel.toolUseId);
  }
  return ids;
}

// scanTurn(lines, {receipts, outcomes}) -> [{id, command, kind}] of the current turn.
function scanTurn(lines, { receipts, outcomes }) {
  const { currentTurnEntries } = splitTurns(parseLines(lines));
  const errored = erroredIdsOf(currentTurnEntries);
  const cancelled = cancelledIdsOf(currentTurnEntries);
  const found = [];
  for (const call of sentinelCallsOf(currentTurnEntries)) {
    if (errored.has(call.id)) continue;
    if (cancelled.has(call.id)) found.push({ ...call, kind: KIND.TIMEOUT });
    else if (!receipts.has(call.id)) found.push({ ...call, kind: KIND.UNREACHED });
    else if (!outcomes.has(call.id)) found.push({ ...call, kind: KIND.MIDWAY });
  }
  return found;
}

const shorten = (s) => (s.length > 160 ? `${s.slice(0, 157)}...` : s);

function lineFor(item) {
  const cmd = shorten(item.command);
  if (item.kind === KIND.TIMEOUT) {
    return `workflow-mark timed out on \`${cmd}\` (PostToolUse hook cancelled) — NOT applied. ` +
      "Re-run it as one standalone Bash call, then check next-step.";
  }
  if (item.kind === KIND.UNREACHED) {
    return `\`${cmd}\` never reached workflow-mark, or its session could not be resolved — NOT applied. ` +
      "Re-run it as one standalone Bash call, then check next-step.";
  }
  return `workflow-mark stopped mid-way on \`${cmd}\` and did not finish — it may be partly applied. ` +
    "Check next-step --list before re-running it.";
}

// buildNotice(items) -> the systemMessage text, or null when there is nothing to tell.
function buildNotice(items) {
  if (!items || items.length === 0) return null;
  return ["sentinel backstop: a workflow sentinel of this turn was not applied.", ...items.map(lineFor)].join("\n");
}

module.exports = { KIND, scanTurn, buildNotice, sentinelCallsOf };
