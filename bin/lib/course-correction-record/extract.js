"use strict";
// extract --transcript <path> --uuid <uuid> --out <file>: copies the target real user prompt and
// the 3 real prompts before it (fewer when the session has fewer) verbatim into a Markdown record.
// Kept per entry: user string content and text items, assistant text items. Dropped: sidechain,
// isMeta, compact summaries, task-notifications, tool_use, tool_result and thinking. Each entry
// body sits in a backtick fence. Written through a tmp file.

const fs = require("fs");
const { toWindowsPath } = require("../../../hooks/lib/branch-diff");
const { readTranscriptLines, parseLines, isRealUserPrompt, textItemsOf } = require("../../../hooks/lib/transcript-reader");

const PRIOR_PROMPTS = 3;

function userTexts(entry) {
  const c = entry.message && entry.message.content;
  if (typeof c === "string") return [c];
  if (!Array.isArray(c)) return [];
  return c.filter((it) => it && it.type === "text" && typeof it.text === "string").map((it) => it.text);
}

// A task-notification is a type:"user" entry the user never typed (cf. supervisor-codex-input/rules.js).
function isTaskNotification(entry) {
  if (entry.origin && entry.origin.kind === "task-notification") return true;
  const first = userTexts(entry)[0];
  return typeof first === "string" && first.trimStart().startsWith("<task-notification>");
}

function isTargetPrompt(entry) {
  return isRealUserPrompt(entry) && !isTaskNotification(entry);
}

function textsOf(entry) {
  if (entry.isMeta === true || entry.isCompactSummary === true) return [];
  if (entry.type === "user") return isTaskNotification(entry) ? [] : userTexts(entry);
  return textItemsOf(entry);
}

// The fence outruns every backtick run in the body, so no body line can close it or become a heading.
function fence(body) {
  const longest = (body.match(/`+/g) || []).reduce((n, run) => Math.max(n, run.length), 0);
  return "`".repeat(Math.max(3, longest + 1));
}

function render(transcript, uuid, entries) {
  let md = `# Course correction record\n- transcript: ${transcript}\n- uuid: ${uuid}\n`;
  for (const e of entries) {
    const texts = textsOf(e);
    if (texts.length === 0) continue;
    const body = texts.join("\n\n");
    const f = fence(body);
    md += `\n## ${e.type} ${e.timestamp || "-"}\n${f}\n${body}\n${f}\n`;
  }
  return md;
}

// run({transcript, uuid, out}) -> {code, message?}
function run({ transcript, uuid, out }) {
  if (!transcript || !uuid || !out) return { code: 2, message: "--transcript, --uuid and --out need a non-empty value" };
  const src = toWindowsPath(transcript);
  const dest = toWindowsPath(out);
  try {
    fs.accessSync(src, fs.constants.R_OK);
  } catch {
    return { code: 1, message: `the transcript is unreadable: ${src}` };
  }
  const entries = parseLines(readTranscriptLines(src)).filter((e) => e.isSidechain !== true);
  const prompts = [];
  entries.forEach((e, i) => { if (isTargetPrompt(e)) prompts.push(i); });
  const k = prompts.findIndex((i) => entries[i].uuid === uuid);
  if (k < 0) return { code: 3, message: `no real user prompt with uuid ${uuid}` };
  const range = entries.slice(prompts[Math.max(0, k - PRIOR_PROMPTS)], prompts[k] + 1);
  const tmp = `${dest}.tmp.${process.pid}`;
  try {
    fs.writeFileSync(tmp, render(src, uuid, range));
    fs.renameSync(tmp, dest);
  } catch (e) {
    try { fs.unlinkSync(tmp); } catch { /* the tmp file was never created */ }
    return { code: 1, message: `the record could not be written: ${e.message}` };
  }
  return { code: 0 };
}

module.exports = { run };
