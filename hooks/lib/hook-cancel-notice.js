"use strict";
// Tells the user and the session that Claude Code cancelled a PreToolUse hook at its timeout (#2676).
// A cancel is visible only in the transcript (a "hook_cancelled" attachment), and the cancelled
// hook's permission decision is lost; this reads the new records at the next UserPromptSubmit.
// Background: docs/architecture/claude-code/settings/hook-timeout.md "Cancellation notice".

const fs = require("fs");
const path = require("path");

const CURSOR_SUFFIX = ".hook-cancel-cursor";
const HOOK_SCRIPT_RE = /hooks[\\/]([A-Za-z0-9_.-]+)\.js\b/;
const MATCHER_GROUP_RE = /--matcher-group[ =]+["']?([A-Za-z0-9_-]+)/;
const TOOL_PREFIX = "PreToolUse:";

// hookNameOf(command) -> the hooks/<name>.js basename (plus the merged hook's matcher group),
// so a launch prefix such as `sleep 1; node .../hooks/x.js` is never taken for the hook name.
function hookNameOf(command) {
  const script = HOOK_SCRIPT_RE.exec(command);
  if (!script) return command.trim().slice(0, 120) || "(unknown hook)";
  const group = MATCHER_GROUP_RE.exec(command.slice(script.index + script[0].length));
  return group ? `${script[1]} --matcher-group ${group[1]}` : script[1];
}

function cancelOf(line) {
  let record = null;
  try { record = JSON.parse(line); } catch (_e) { return null; }
  const attachment = record && record.type === "attachment" ? record.attachment : null;
  if (!attachment || attachment.type !== "hook_cancelled" || attachment.hookEvent !== "PreToolUse") return null;
  if (typeof attachment.command !== "string" || attachment.command === "") return null;
  // A cancel the record marks as not a timeout (the user's interrupt) lost no decision to the limit.
  if (attachment.timedOut === false) return null;
  const label = typeof attachment.hookName === "string" ? attachment.hookName : "";
  const tool = label.startsWith(TOOL_PREFIX) && label.length > TOOL_PREFIX.length ? label.slice(TOOL_PREFIX.length) : "(unknown tool)";
  return { hook: hookNameOf(attachment.command), tool };
}

// detectCancels(lines, cursor) -> [{hook, tool}] for the PreToolUse cancels at line index >= cursor.
function detectCancels(lines, cursor = 0) {
  const found = [];
  if (!Array.isArray(lines)) return found;
  for (let index = Math.max(0, cursor | 0); index < lines.length; index++) {
    const line = lines[index];
    if (typeof line !== "string" || line.indexOf("hook_cancelled") === -1) continue;
    const cancel = cancelOf(line);
    if (cancel) found.push(cancel);
  }
  return found;
}

// buildCancelNotice(cancels) -> {systemMessage, additionalContext}, or null when there is none.
function buildCancelNotice(cancels) {
  const seen = new Set();
  const items = [];
  for (const cancel of cancels || []) {
    const item = `${cancel.hook} (tool ${cancel.tool})`;
    if (!seen.has(item)) { seen.add(item); items.push(item); }
  }
  if (items.length === 0) return null;
  const list = items.join(", ");
  return {
    systemMessage: `hook-cancel: Claude Code cancelled the PreToolUse hook ${list} at its timeout, so that hook's permission decision was lost (a deny did not take effect; an allow became a prompt or a refusal).`,
    additionalContext: `hook-cancel: the PreToolUse hook ${list} was cancelled at its timeout in an earlier tool call; its permission decision was lost. If that tool call needed the hook's check, re-check it now. See docs/architecture/claude-code/settings/hook-timeout.md.`,
  };
}

function cursorPathFor(sid) {
  const { getSessionStateDir } = require("../workflow-state/state-io");
  return path.join(getSessionStateDir(sid), sid + CURSOR_SUFFIX);
}

function readCursor(sid, transcriptPath) {
  try {
    const saved = JSON.parse(fs.readFileSync(cursorPathFor(sid), "utf8"));
    if (saved && saved.transcript === transcriptPath && Number.isInteger(saved.offset) && saved.offset >= 0) return saved.offset;
  } catch (_e) {}
  return 0;
}

function writeCursor(sid, transcriptPath, offset) {
  try {
    const target = cursorPathFor(sid);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, JSON.stringify({ transcript: transcriptPath, offset }) + "\n", { encoding: "utf8", mode: 0o600 });
  } catch (_e) {}
}

// A first read (no cursor yet) of a long transcript scans only its tail, so the
// UserPromptSubmit hook never spends its time on the whole session history.
const MAX_SCAN_BYTES = 4 * 1024 * 1024;

// readNewLines(transcriptPath, offset) -> {lines, offset} of the complete lines after `offset`
// (a byte position), or null when the transcript is not a readable file.
function readNewLines(transcriptPath, offset) {
  let fd = null;
  try {
    fd = fs.openSync(transcriptPath, "r");
    const stat = fs.fstatSync(fd);
    if (!stat.isFile()) return null;
    const cursor = offset <= stat.size ? offset : 0;
    // A saved cursor is read in full: skipping past it would lose the records in between.
    const start = cursor === 0 ? Math.max(0, stat.size - MAX_SCAN_BYTES) : cursor;
    const buffer = Buffer.alloc(stat.size - start);
    const read = buffer.length > 0 ? fs.readSync(fd, buffer, 0, buffer.length, start) : 0;
    const lastNewline = buffer.lastIndexOf(0x0a, read - 1);
    if (lastNewline === -1) return { lines: [], offset: start };
    // A start moved into the middle of a line drops that partial first line.
    const firstLine = start > cursor ? buffer.indexOf(0x0a) + 1 : 0;
    return { lines: buffer.toString("utf8", firstLine, lastNewline).split("\n"), offset: start + lastNewline + 1 };
  } catch (_e) {
    return null;
  } finally {
    if (fd !== null) { try { fs.closeSync(fd); } catch (_e) {} }
  }
}

// newCancelNotice(sid, transcriptPath) -> the notice for cancels written since the last call in
// this session, or null. Each cancel is told once: the read position is kept per session.
function newCancelNotice(sid, transcriptPath) {
  if (typeof transcriptPath !== "string" || transcriptPath === "") return null;
  const chunk = readNewLines(transcriptPath, readCursor(sid, transcriptPath));
  if (!chunk) return null;
  writeCursor(sid, transcriptPath, chunk.offset);
  return buildCancelNotice(detectCancels(chunk.lines, 0));
}

module.exports = { detectCancels, buildCancelNotice, newCancelNotice, hookNameOf };
