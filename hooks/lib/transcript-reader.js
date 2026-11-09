"use strict";
// hooks/lib/transcript-reader.js — the one transcript reader of the Stop and PreToolUse hooks (#2610).
// At Stop the final assistant line may not be flushed yet, so readTurnTail waits until the
// transcript's last text block agrees with the hook input's last_assistant_message; that field
// only confirms the flush and is never judged as the body, since it may join several text blocks.
// readTurnTail reads a bounded tail (#2936, transcript-reader/tail-window.js), not the whole file.
// Never throws: an unreadable transcript reads as no lines; callers fail open on `undecidable`.

const fs = require("fs");
const TW = require("./transcript-reader/tail-window");

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

const EMPTY_WINDOW = Object.freeze({ lines: [], entries: [], span: { start: 0, end: null, pending: false }, complete: true });

// boundaryOf(turns, reachedBy) -> the window's boundary factory: `turns` real prompts and, when
// given, one entry satisfying reachedBy.
function boundaryOf(turns, reachedBy) {
  const want = Number.isInteger(turns) && turns > 0 ? turns : 1;
  return () => {
    let prompts = 0;
    let hit = typeof reachedBy !== "function";
    return (batch) => {
      for (const e of batch) {
        if (isRealUserPrompt(e)) prompts += 1;
        if (!hit) {
          try { hit = !!reachedBy(e); } catch (_) { /* a throwing predicate reads as not reached */ }
        }
      }
      return prompts >= want && hit;
    };
  };
}

const spent = (deadlineAt) => Number.isFinite(deadlineAt) && Date.now() >= deadlineAt;
const messageOf = (i) => (typeof i.last_assistant_message === "string" ? i.last_assistant_message : null);

// A window that misses a boundary (complete false) or whose last text is not yet the final message
// is undecidable.
function tailFrom(win, message) {
  const tail = tailOf(win.entries);
  const undecidable = !win.complete || (message !== null && !flushed(tail.lastTextBlock, message));
  return { lines: win.lines, entries: win.entries, ...tail, undecidable, complete: win.complete, span: win.span };
}

// readTurnTail({input, turns, reachedBy, deadlineAt}) -> {lines, entries, lastAssistantEntry,
// lastTextBlock, lastTextEntry, undecidable, complete, span}. lines / entries are the transcript's
// end holding `turns` real prompts (default 1: the current turn) and an entry satisfying reachedBy,
// or all of it. A new caller that needs more than the current turn passes that boundary. Without
// last_assistant_message (older Claude Code) there is no wait; deadlineAt (epoch ms) stops growth
// and the wait, which reads as undecidable.
function readTurnTail({ input, turns = 1, reachedBy, deadlineAt } = {}) {
  const i = input && typeof input === "object" ? input : {};
  const message = messageOf(i);
  const want = { deadlineAt, boundary: boundaryOf(turns, reachedBy) };
  let win = TW.readWindow(i.transcript_path, want) || EMPTY_WINDOW;
  for (let attempt = 0; ; attempt++) {
    const tail = tailFrom(win, message);
    if (!tail.undecidable || !win.complete || attempt >= FLUSH_STEPS || spent(deadlineAt)) return tail;
    sleep(FLUSH_STEP_MS);
    win = TW.appendWindow(i.transcript_path, win, want) || win;
  }
}

// refreshTurnTail(tail, {input, deadlineAt}) -> tail extended by what was appended after it (a
// rewritten transcript is read again), with no wait. Never throws: a spent deadline or an
// unreadable transcript returns tail marked undecidable.
function refreshTurnTail(tail, { input, deadlineAt } = {}) {
  const t = tail && typeof tail === "object" ? tail : {};
  try {
    const i = input && typeof input === "object" ? input : {};
    if (spent(deadlineAt) || !Array.isArray(t.lines) || !Array.isArray(t.entries)) return Object.assign({}, t, { undecidable: true });
    const win = TW.appendWindow(i.transcript_path, t, { deadlineAt, boundary: boundaryOf(1) });
    if (!win) return Object.assign({}, t, { undecidable: true });
    return tailFrom(win, messageOf(i));
  } catch (_) {
    return Object.assign({}, t, { undecidable: true });
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

module.exports = { readTranscriptLines, readTurnTail, refreshTurnTail, parseLines, isRealUserPrompt, textItemsOf, splitTurns, tailOf, flushed };
