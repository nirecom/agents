// Plan-link turn checks shared by the confirm-plan Stop guard (hooks/stop-confirm-plan-guard.js)
// and the CONFIRM dialog (hooks/confirm-checkpoint.js): a plan stage's plan-link output — the
// blob URL when one exists, otherwise the plan's local path — must end the presentation turn.
// Pure helpers; the caller supplies the transcript entries and the link resolver. Fail-open.
"use strict";

const os = require("os");
const path = require("path");
const { isCommandTool, commandTextOf } = require("./tool-command-text");
const { parseSentinel } = require("./confirm-sentinel");
const { isRealUserPrompt, parseLines, splitTurns } = require("./transcript-reader");
const { STAGES, PLAN_LINK_COMMAND } = require("./plan-link");

// A link ends where path characters stop; one trailing "." or ")" is prose, not the link.
const CONTINUES_RE = /^\.?[A-Za-z0-9_~%/\\-]/;
const PLAN_WRITE_TOOLS = new Set(["Write", "Edit", "MultiEdit"]);
const READ_ONLY_TOOLS = new Set(["Read", "Glob", "Grep"]);
const FENCE_OPEN_RE = /^ {0,3}(`{3,}|~{3,})/;

// turnEntriesOf(entries) -> the entries after the last real user prompt (the current turn).
function turnEntriesOf(entries) {
  if (!Array.isArray(entries)) return [];
  for (let i = entries.length - 1; i >= 0; i--) {
    if (isRealUserPrompt(entries[i])) return entries.slice(i + 1);
  }
  return entries.slice();
}

// turnEntriesFromLines(lines) -> the current turn's parsed entries, walking back from the end
// and stopping at the last real user prompt, so a long transcript is never parsed whole.
function turnEntriesFromLines(lines) {
  const out = [];
  for (let i = (Array.isArray(lines) ? lines.length : 0) - 1; i >= 0; i--) {
    if (!lines[i]) continue;
    let entry;
    try { entry = JSON.parse(lines[i]); } catch (_) { continue; }
    if (isRealUserPrompt(entry)) break;
    out.push(entry);
  }
  return out.reverse();
}

// previousTurnEntriesFromLines(lines) -> the entries between the last two real prompts; [] when
// no real prompt precedes the last one.
function previousTurnEntriesFromLines(lines) {
  return splitTurns(parseLines(lines)).prevTurnEntries;
}

function assistantContent(entry) {
  if (!entry || entry.type !== "assistant") return [];
  const c = entry.message && entry.message.content;
  return Array.isArray(c) ? c : [];
}

function textItems(entries) {
  const texts = [];
  for (const entry of entries) {
    for (const item of assistantContent(entry)) {
      if (item && item.type === "text" && typeof item.text === "string") texts.push(item.text);
    }
  }
  return texts;
}

// collectTurnAssistantText(entries) -> the current turn's assistant text items, in order.
// Tool inputs and tool results are excluded: the user never reads them as the reply.
function collectTurnAssistantText(entries) {
  return textItems(turnEntriesOf(entries)).join("\n");
}

// lastTextBlockOf(entries) -> the current turn's last assistant text item, or null.
function lastTextBlockOf(entries) {
  const texts = textItems(turnEntriesOf(entries));
  return texts.length > 0 ? texts[texts.length - 1] : null;
}

function samePath(a, b) {
  const norm = (p) => {
    const r = path.resolve(String(p)).replace(/\\/g, "/");
    return process.platform === "win32" ? r.toLowerCase() : r;
  };
  try { return norm(a) === norm(b); } catch (_) { return false; }
}

function isConfirmEcho(item) {
  return isCommandTool(item.name) && parseSentinel(commandTextOf(item.name, item.input)) !== null;
}

// Any non-read tool naming the plan's basename may write it (a Bash redirect, a script, ...).
function mentionsBasename(item, base) {
  if (READ_ONLY_TOOLS.has(item.name) || isConfirmEcho(item)) return false;
  let s = "";
  try { s = JSON.stringify(item.input === undefined ? null : item.input) || ""; } catch (_) { return false; }
  return s.toLowerCase().includes(base);
}

// currentTurnWritesStage(entries, absPath) -> whether this turn wrote (or may have written) the plan.
function currentTurnWritesStage(entries, absPath) {
  if (typeof absPath !== "string" || !absPath) return false;
  const base = absPath.replace(/\\/g, "/").split("/").pop().toLowerCase();
  for (const entry of turnEntriesOf(entries)) {
    for (const item of assistantContent(entry)) {
      if (!item || item.type !== "tool_use") continue;
      const fp = item.input && item.input.file_path;
      if (PLAN_WRITE_TOOLS.has(item.name) && typeof fp === "string" && fp && samePath(fp, absPath)) return true;
      if (base && mentionsBasename(item, base)) return true;
    }
  }
  return false;
}

// stagesToCheck({ markers, turnEntries, includeConfirm }) -> deduplicated plan stages written
// (turn marker) or, unless includeConfirm is false, CONFIRMed this turn.
function stagesToCheck({ markers, turnEntries, includeConfirm } = {}) {
  const found = new Set();
  for (const m of Array.isArray(markers) ? markers : []) {
    if (m && STAGES.includes(m.suffix)) found.add(m.suffix);
  }
  const entries = includeConfirm === false ? [] : Array.isArray(turnEntries) ? turnEntries : [];
  for (const entry of entries) {
    for (const item of assistantContent(entry)) {
      // Every command tool confirm-checkpoint recognizes, not only Bash.
      if (!item || item.type !== "tool_use" || !isCommandTool(item.name)) continue;
      const hit = parseSentinel(commandTextOf(item.name, item.input));
      if (hit) found.add(hit.stage);
    }
  }
  return STAGES.filter((s) => found.has(s));
}

// inlineCodeRanges(text) -> [start, end) ranges of CommonMark inline code spans: a backtick run
// of length N closes at the next run of exactly N; an unmatched opener is literal text.
function inlineCodeRanges(text) {
  const runs = [];
  const re = /`+/g;
  let m;
  while ((m = re.exec(text)) !== null) runs.push({ at: m.index, len: m[0].length });
  const ranges = [];
  for (let k = 0; k < runs.length; k++) {
    const close = runs.findIndex((r, j) => j > k && r.len === runs[k].len);
    if (close === -1) continue;
    ranges.push([runs[k].at, runs[close].at + runs[close].len]);
    k = close;
  }
  return ranges;
}

function containsLink(text, link, { bareOnly = false } = {}) {
  if (!link) return false;
  const spans = bareOnly ? inlineCodeRanges(text) : [];
  let from = 0;
  for (;;) {
    const i = text.indexOf(link, from);
    if (i === -1) return false;
    // A URL inside inline code cannot be tapped, so it is not shown.
    const inCode = spans.some(([s, e]) => i >= s && i < e);
    if (!inCode && !CONTINUES_RE.test(text.slice(i + link.length))) return true;
    from = i + 1;
  }
}

function fileUriOf(fwd) {
  const enc = (s) => s.split("/").map(encodeURIComponent).join("/");
  const m = fwd.match(/^([A-Za-z]:)\/(.*)/);
  return m ? "file:///" + m[1] + "/" + enc(m[2]) : "file:///" + enc(fwd.replace(/^\//, ""));
}

// localPathForms(absPath) -> the spellings of one local path a reply may use: native,
// forward-slash, "~" (under the home directory) and the percent-encoded file URI.
function localPathForms(absPath) {
  const fwd = absPath.replace(/\\/g, "/");
  const forms = [absPath, fwd, fileUriOf(fwd)];
  if (process.platform === "win32") forms.push(fwd.replace(/\//g, "\\"));
  try {
    const home = os.homedir().replace(/\\/g, "/").replace(/\/+$/, "");
    const fold = (s) => (process.platform === "win32" ? s.toLowerCase() : s);
    if (home && fold(fwd).startsWith(fold(home) + "/")) forms.push("~" + fwd.slice(home.length));
  } catch (_) { /* no home directory: the other forms remain */ }
  return [...new Set(forms)];
}

// stripFencedCode(text) -> text without CommonMark fenced code blocks; an unclosed fence runs to the end.
function stripFencedCode(text) {
  const out = [];
  let fence = null;
  for (const line of String(text).split("\n")) {
    if (fence) {
      const close = line.match(/^ {0,3}(`{3,}|~{3,})\s*$/);
      if (close && close[1][0] === fence[0] && close[1].length >= fence.length) fence = null;
      continue;
    }
    const open = line.match(FENCE_OPEN_RE);
    if (open && !(open[1][0] === "`" && line.slice(open[0].length).includes("`"))) {
      fence = open[1];
      out.push("");
      continue;
    }
    out.push(line);
  }
  return out.join("\n");
}

// shown(link, text) -> null when the stage needs nothing, else whether the reply shows it outside a code fence.
function shown(link, text) {
  if (!link || typeof link !== "object") return null;
  const prose = stripFencedCode(text);
  if (typeof link.url === "string" && link.url) return containsLink(prose, link.url, { bareOnly: true });
  if (typeof link.path !== "string" || !link.path) return null;
  return localPathForms(link.path).some((form) => containsLink(prose, form));
}

function stopReason(missing) {
  return "[confirm-plan] plan-link: this turn wrote the " + missing.join(", ") +
    " plan but its last text block does not carry the plan-link line (the URL when one exists, otherwise the" +
    " local path) — run " + PLAN_LINK_COMMAND + ", end the final body text of the turn with its output as-is" +
    " and close the turn on that line; the next step is prompted after it. (Hook: stop-confirm-plan-guard.js)";
}

// checkPlanUrlInTurn({ stages, turnText, resolve, reasonFor }) -> { block, reason? }.
// resolve(stage) returns plan-link's { url?, path?, reason? }; a throw or no path never blocks.
// reasonFor(missingStages) words the block; omitted, it is the Stop guard's reason.
function checkPlanUrlInTurn({ stages, turnText, resolve, reasonFor } = {}) {
  const text = typeof turnText === "string" ? turnText : "";
  const missing = [];
  for (const stage of Array.isArray(stages) ? stages : []) {
    let link = null;
    try { link = resolve(stage); } catch (_) { link = null; }
    if (shown(link, text) === false) missing.push(stage);
  }
  if (missing.length === 0) return { block: false };
  return { block: true, reason: typeof reasonFor === "function" ? reasonFor(missing) : stopReason(missing) };
}

module.exports = {
  collectTurnAssistantText,
  stagesToCheck,
  checkPlanUrlInTurn,
  turnEntriesOf,
  turnEntriesFromLines,
  lastTextBlockOf,
  previousTurnEntriesFromLines,
  currentTurnWritesStage,
  shown,
};
