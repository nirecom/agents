"use strict";
// hooks/lib/transcript-reader.js — the one transcript reader of the Stop and PreToolUse hooks (#2610).
// At Stop the final assistant line may not be flushed yet, so readTurnTail waits until the
// transcript's last text block agrees with the hook input's last_assistant_message; that field
// only confirms the flush and is never judged as the body, since it may join several text blocks.
// Never throws: an unreadable transcript reads as no lines; callers fail open on `undecidable`.

const fs = require("fs");

const FLUSH_STEP_MS = 50;
const FLUSH_STEPS = 10;
const waitCell = new Int32Array(new SharedArrayBuffer(4));

function sleep(ms) {
  Atomics.wait(waitCell, 0, 0, ms);
}

// readTranscriptLines(path) -> the non-empty JSONL lines, read once; [] when unreadable.
function readTranscriptLines(transcriptPath) {
  try {
    if (typeof transcriptPath !== "string" || !transcriptPath) return [];
    return fs.readFileSync(transcriptPath, "utf8").split("\n").filter((l) => l.trim() !== "");
  } catch (_) {
    return [];
  }
}

function parseLines(lines) {
  const entries = [];
  for (const line of Array.isArray(lines) ? lines : []) {
    try {
      const e = JSON.parse(line);
      if (e && typeof e === "object") entries.push(e);
    } catch (_) { /* a malformed or half-written line is skipped */ }
  }
  return entries;
}

// A real user prompt opens a turn. Not one: a user entry holding only tool_result items, a meta
// injection (isMeta) or a compaction summary (isCompactSummary).
function isRealUserPrompt(entry) {
  if (!entry || entry.type !== "user" || entry.isMeta === true || entry.isCompactSummary === true) return false;
  const content = entry.message && entry.message.content;
  if (typeof content === "string") return true;
  if (!Array.isArray(content)) return false;
  return content.some((it) => !it || it.type !== "tool_result");
}

function textItemsOf(entry) {
  if (!entry || entry.type !== "assistant") return [];
  const c = entry.message && entry.message.content;
  if (!Array.isArray(c)) return [];
  return c.filter((it) => it && it.type === "text" && typeof it.text === "string").map((it) => it.text);
}

// tailOf(entries) -> {lastAssistantEntry, lastTextBlock, lastTextEntry}: the last assistant entry,
// the last text item of the current turn and the entry holding it (null when the turn has none).
function tailOf(entries) {
  let lastAssistantEntry = null;
  let lastTextBlock = null;
  let lastTextEntry = null;
  for (let i = entries.length - 1; i >= 0; i--) {
    const e = entries[i];
    if (isRealUserPrompt(e)) break;
    if (e.type !== "assistant") continue;
    if (!lastAssistantEntry) lastAssistantEntry = e;
    const texts = textItemsOf(e);
    if (texts.length > 0) { lastTextBlock = texts[texts.length - 1]; lastTextEntry = e; break; }
  }
  return { lastAssistantEntry, lastTextBlock, lastTextEntry };
}

function flushed(lastTextBlock, message) {
  const want = message.trim();
  if (want === "") return true;
  const got = typeof lastTextBlock === "string" ? lastTextBlock.trim() : "";
  if (got === "") return false;
  return want.endsWith(got) || got.endsWith(want);
}

// readTurnTail({input}) -> {lines, lastAssistantEntry, lastTextBlock, undecidable}.
// Without last_assistant_message (older Claude Code) the transcript is read once, no wait.
function readTurnTail({ input } = {}) {
  const i = input && typeof input === "object" ? input : {};
  const message = typeof i.last_assistant_message === "string" ? i.last_assistant_message : null;
  for (let attempt = 0; ; attempt++) {
    const lines = readTranscriptLines(i.transcript_path);
    const tail = tailOf(parseLines(lines));
    if (message === null || flushed(tail.lastTextBlock, message)) return { lines, ...tail, undecidable: false };
    if (attempt >= FLUSH_STEPS) return { lines, ...tail, undecidable: true };
    sleep(FLUSH_STEP_MS);
  }
}

// splitTurns(entries) -> {prevTurnEntries, currentTurnEntries, hasPriorPrompt}: the previous turn
// runs from the prompt before the last real prompt up to it; the current turn follows it.
function splitTurns(entries) {
  const prompts = [];
  entries.forEach((e, idx) => { if (isRealUserPrompt(e)) prompts.push(idx); });
  const last = prompts.length > 0 ? prompts[prompts.length - 1] : -1;
  const currentTurnEntries = entries.slice(last + 1);
  if (prompts.length < 2) return { prevTurnEntries: [], currentTurnEntries, hasPriorPrompt: false };
  return { prevTurnEntries: entries.slice(prompts[prompts.length - 2] + 1, last), currentTurnEntries, hasPriorPrompt: true };
}

module.exports = { readTranscriptLines, readTurnTail, parseLines, isRealUserPrompt, splitTurns, tailOf, flushed };
