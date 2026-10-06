// Layer 3 of the confirm-plan Stop guard (hooks/stop-confirm-plan-guard.js): a turn that wrote
// a plan artifact or CONFIRMed a plan stage must show that stage's blob URL in its assistant text.
// Pure helpers; the caller supplies the transcript entries and the URL resolver. Fail-open.
"use strict";

const { isCommandTool, commandTextOf } = require("./tool-command-text");
// The detector that opens the CONFIRM dialog decides what counts as a CONFIRM here too, so a
// command the dialog fires on (e.g. an echo inside a compound command) never escapes Layer 3.
const { parseSentinel } = require("../confirm-checkpoint");

const PLAN_STAGES = ["intent", "outline", "detail"];
// A URL ends where a URL path character stops; a trailing "." or ")" is prose, not URL.
const URL_CONT_RE = /[A-Za-z0-9_~%/-]/;

// A real user prompt opens a turn; a user entry carrying only tool_result items does not.
function isRealUserPrompt(entry) {
  if (!entry || entry.type !== "user") return false;
  const content = entry.message && entry.message.content;
  if (typeof content === "string") return true;
  if (!Array.isArray(content)) return false;
  return content.some((it) => !it || it.type !== "tool_result");
}

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

// collectTurnAssistantText(entries) -> the current turn's assistant text items, in order.
// Tool inputs and tool results are excluded: the user never reads them as the reply.
function collectTurnAssistantText(entries) {
  const texts = [];
  for (const entry of turnEntriesOf(entries)) {
    for (const item of assistantContent(entry)) {
      if (item && item.type === "text" && typeof item.text === "string") texts.push(item.text);
    }
  }
  return texts.join("\n");
}

// stagesToCheck({ markers, turnEntries }) -> deduplicated plan stages written or CONFIRMed this turn.
function stagesToCheck({ markers, turnEntries } = {}) {
  const found = new Set();
  for (const m of Array.isArray(markers) ? markers : []) {
    if (m && PLAN_STAGES.includes(m.suffix)) found.add(m.suffix);
  }
  for (const entry of Array.isArray(turnEntries) ? turnEntries : []) {
    for (const item of assistantContent(entry)) {
      // Every command tool confirm-checkpoint recognizes, not only Bash.
      if (!item || item.type !== "tool_use" || !isCommandTool(item.name)) continue;
      const hit = parseSentinel(commandTextOf(item.name, item.input));
      if (hit) found.add(hit.stage);
    }
  }
  return PLAN_STAGES.filter((s) => found.has(s));
}

function containsUrl(text, url) {
  let from = 0;
  for (;;) {
    const i = text.indexOf(url, from);
    if (i === -1) return false;
    const next = text.charAt(i + url.length);
    if (!next || !URL_CONT_RE.test(next)) return true;
    from = i + 1;
  }
}

// checkPlanUrlInTurn({ stages, turnText, resolve }) -> { block, reason? }.
// resolve(stage) returns plan-link's { url } or { reason }; a throw or no URL never blocks.
function checkPlanUrlInTurn({ stages, turnText, resolve } = {}) {
  const text = typeof turnText === "string" ? turnText : "";
  const missing = [];
  for (const stage of Array.isArray(stages) ? stages : []) {
    let link = null;
    try { link = resolve(stage); } catch (_) { link = null; }
    const url = link && typeof link.url === "string" ? link.url : "";
    if (url && !containsUrl(text, url)) missing.push(stage);
  }
  if (missing.length === 0) return { block: false };
  return {
    block: true,
    reason: "[confirm-plan] Layer 3/plan-url: this turn wrote or confirmed the " + missing.join(", ") +
      " plan but its GitHub blob URL is not in the response text — run node \"$AGENTS_CONFIG_DIR/bin/plan-link\"" +
      " and write the printed URL in the response text (never a local path). (Hook: stop-confirm-plan-guard.js)",
  };
}

module.exports = { collectTurnAssistantText, stagesToCheck, checkPlanUrlInTurn, turnEntriesOf, turnEntriesFromLines };
