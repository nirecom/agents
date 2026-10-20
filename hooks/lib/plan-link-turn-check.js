// Plan-link turn checks of the confirm-plan Stop guard (hooks/stop-confirm-plan-guard.js) and
// its presented-stage judgment (hooks/lib/confirm-continuation.js): where a plan stage's
// plan-link output — the blob URL when one exists, otherwise the local path — appears in the turn.
// Pure helpers; the caller supplies the transcript entries and the link resolver.
"use strict";

const os = require("os");
const { isCommandTool, commandTextOf } = require("./tool-command-text");
const { parseSentinel } = require("./confirm-sentinel");
const { isRealUserPrompt } = require("./transcript-reader");
const { STAGES, REASONS, REASON_TEXT, PLAN_LINK_COMMAND, entryLine } = require("./plan-link");

// A link ends where path characters stop; one trailing "." or ")" is prose, not the link.
const CONTINUES_RE = /^\.?[A-Za-z0-9_~%/\\-]/;
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

// The entryLine shapes: a URL line (optionally with its inline-code path), and a no-URL line that
// renderModelContext may follow with " — " plus the text of the reason that same line names.
const STAGE_ALT = STAGES.join("|");
const URL_LINE_RE = new RegExp(`^(?:${STAGE_ALT}): https?://\\S+(?: \\(\`[^\`]+\`\\))?$`);
const NO_URL_LINE_RE = new RegExp(`^((?:${STAGE_ALT}): (?:\`[^\`]+\` \\(no URL|\\(unavailable): ` +
  `(${Object.values(REASONS).join("|")})\\))(?: — (.*))?$`);

// planLinkLineBare(line) -> the entryLine part of a plan-link output line, or null for anything else.
function planLinkLineBare(line) {
  if (URL_LINE_RE.test(line)) return line;
  const m = line.match(NO_URL_LINE_RE);
  if (!m || (m[3] !== undefined && m[3] !== REASON_TEXT[m[2]])) return null;
  return m[1];
}

// inTrailingLinkRun(lastText, link) -> whether the text's prose, outside code fences, closes on a
// run of plan-link lines (blank lines between them allowed) that holds the line of link.stage
// (any spelling of its local path). Several stages presented together close on one run.
function inTrailingLinkRun(lastText, link) {
  if (!link || typeof link !== "object" || !STAGES.includes(link.stage)) return false;
  const raw = trimmedLines(typeof lastText === "string" ? lastText : "");
  const block = new Set();
  let last = raw.length - 1;
  for (; last >= 0; last--) {
    if (raw[last] === "") continue;
    const bare = planLinkLineBare(raw[last]);
    if (bare === null) break;
    block.add(bare);
  }
  const tail = raw.slice(last + 1).join("\n").replace(/^\n+/, "");
  // A tail inside a code fence is not prose, so it does not close the turn.
  const prose = trimmedLines(stripFencedCode(raw.join("\n"))).join("\n");
  if (!tail || !(prose === tail || prose.endsWith("\n" + tail))) return false;
  const { stage, url, reason } = link;
  if (typeof url === "string" && url && block.has(entryLine({ stage, url }))) return true;
  if (typeof link.path !== "string" || !link.path) return false;
  return localPathForms(link.path).some((form) => block.has(entryLine({ stage, url, path: form, reason })));
}

// shownInTurn(link, entries) -> shown() over every assistant text item of the current turn.
function shownInTurn(link, entries) {
  return shown(link, textItems(turnEntriesOf(entries)).join("\n"));
}

function trimmedLines(text) {
  return text.trimEnd().split("\n").map((l) => l.trimEnd());
}

function stopReason(missing) {
  return "[confirm-plan] plan-link: this turn wrote the " + missing.join(", ") +
    " plan but its last text block does not carry the plan-link line (the URL when one exists, otherwise the" +
    " local path) — run " + PLAN_LINK_COMMAND + ", end the final body text of the turn with its output as-is" +
    " and close the turn on that line; the next step is prompted after it. (Hook: stop-confirm-plan-guard.js)";
}

// checkPlanUrlInTurn({ stages, turnText, entries, scope, resolve, reasonFor }) -> { block, reason? }.
// resolve(stage) returns plan-link's { url?, path?, reason? }; a throw or no path never blocks.
// scope ("last" | "turn", or stage -> either; default "last"): "last" looks at turnText (the last
// text block), "turn" at every assistant text item of entries' current turn (shownInTurn).
// reasonFor(missingStages) words the block; omitted, it is the Stop guard's reason.
function checkPlanUrlInTurn({ stages, turnText, entries, scope, resolve, reasonFor } = {}) {
  const text = typeof turnText === "string" ? turnText : "";
  const missing = [];
  for (const stage of Array.isArray(stages) ? stages : []) {
    let link = null;
    try { link = resolve(stage); } catch (_) { link = null; }
    let s = "last";
    try { s = typeof scope === "function" ? scope(stage) : scope; } catch (_) { s = "last"; }
    const seen = s === "turn" ? shownInTurn(link, entries) : shown(link, text);
    if (seen === false) missing.push(stage);
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
  shown,
  shownInTurn,
  inTrailingLinkRun,
};
