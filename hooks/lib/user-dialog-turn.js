"use strict";
// hooks/lib/user-dialog-turn.js — the one predicate for "this Stop ends a turn of dialog with the
// user" (#2698 / #1919), shared by the C4 exemption row and every supervisor-guard gate. It reads
// turn structure only: tool names, prompt origin, and whether a text block exists, never wording.
// Whether a prompt or a final text asks something is a semantic judgment left to Jev (#2457),
// which hooks into this classification. Undecidable (no transcript, unflushed tail, no assistant
// entry) reads as "not dialog": fail-closed for C4 and the unchanged block decision for
// supervisor-guard; callers use only isUserDialogTurn and never interpret `decidable` themselves.

const { readTurnTail, parseLines, splitTurns, isRealUserPrompt } = require("./transcript-reader");

// Closed set: any other tool (Bash, Agent, Skill, Write, Edit, other MCP or unknown) is not
// read-only. The codegraph name is environment-specific; an exact-name match is inert where absent.
const READ_ONLY_TOOL_NAMES = Object.freeze(new Set(["Read", "Grep", "Glob", "mcp__codegraph__codegraph_explore"]));

const memo = new WeakMap();

function readOnce(input) {
  if (memo.has(input)) return memo.get(input);
  const tail = readTurnTail({ input });
  const entries = parseLines(tail.lines);
  const r = { tail, entries };
  memo.set(input, r);
  return r;
}

// A line without `origin` (older transcripts) follows isRealUserPrompt; any non-human kind is not human.
function isHumanPrompt(entry) {
  if (!isRealUserPrompt(entry)) return false;
  const origin = entry.origin;
  return origin == null || (typeof origin === "object" && origin.kind === "human");
}

const contentOf = (entry) => {
  const c = entry && entry.type === "assistant" && entry.message && entry.message.content;
  return Array.isArray(c) ? c : [];
};
const toolUsesOf = (entry) => contentOf(entry).filter((it) => it && it.type === "tool_use");
const hasTextBlock = (entry) => contentOf(entry).some((it) => it && it.type === "text" && typeof it.text === "string");

function classify(input) {
  if (!input || typeof input !== "object" || typeof input.transcript_path !== "string" || !input.transcript_path) {
    return { kind: null, decidable: false };
  }
  const { tail, entries } = readOnce(input);
  if (tail.undecidable || entries.length === 0 || !tail.lastAssistantEntry) return { kind: null, decidable: false };

  const lastUses = toolUsesOf(tail.lastAssistantEntry);
  if (lastUses.length > 0 && lastUses[lastUses.length - 1].name === "AskUserQuestion") {
    return { kind: "ask-user-question-tool", decidable: true };
  }
  if (lastUses.length > 0 || !hasTextBlock(tail.lastAssistantEntry)) return { kind: null, decidable: true };

  let opener = null;
  for (let i = entries.length - 1; i >= 0; i--) {
    if (isRealUserPrompt(entries[i])) { opener = entries[i]; break; }
  }
  if (!opener || !isHumanPrompt(opener)) return { kind: null, decidable: true };

  const { currentTurnEntries } = splitTurns(entries);
  const allReadOnly = currentTurnEntries.every((e) => toolUsesOf(e).every((u) => READ_ONLY_TOOL_NAMES.has(u.name)));
  if (!allReadOnly) return { kind: null, decidable: true };
  return { kind: "answering-user-prompt", decidable: true };
}

// classifyUserDialogTurn(input) -> {kind, decidable}; exported for tests and diagnostics.
function classifyUserDialogTurn(input) {
  try { return classify(input); } catch (_e) { return { kind: null, decidable: false }; }
}

function isUserDialogTurn(input) {
  const r = classifyUserDialogTurn(input);
  return r.decidable === true && r.kind !== null;
}

// countHumanPromptsSince(input, iso) -> the human prompts stamped after iso, or null when
// undecidable: no transcript, a bad iso, or an unstamped prompt from the one before iso onward.
function countHumanPromptsSince(input, iso) {
  try {
    const t = Date.parse(iso);
    if (typeof iso !== "string" || !Number.isFinite(t)) return null;
    if (!input || typeof input !== "object" || typeof input.transcript_path !== "string" || !input.transcript_path) return null;
    const { entries } = readOnce(input);
    if (entries.length === 0) return null;
    const prompts = entries.filter(isHumanPrompt).map((e) => Date.parse(e.timestamp));
    let k = -1;
    prompts.forEach((ts, i) => { if (Number.isFinite(ts) && ts <= t) k = i; });
    const range = prompts.slice(k + 1);
    if (range.some((ts) => !Number.isFinite(ts))) return null;
    return range.filter((ts) => ts > t).length;
  } catch (_e) {
    return null;
  }
}

module.exports = {
  READ_ONLY_TOOL_NAMES,
  classifyUserDialogTurn,
  isUserDialogTurn,
  countHumanPromptsSince,
};
