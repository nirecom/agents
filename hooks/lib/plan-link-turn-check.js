// Turn-end plan-link check of the confirm-plan Stop guard (hooks/stop-confirm-plan-guard.js):
// a turn that wrote a plan artifact or CONFIRMed a plan stage must show that stage's plan-link
// output in its assistant text — the blob URL when one exists, otherwise the plan's local path.
// Pure helpers; the caller supplies the transcript entries and the link resolver. Fail-open.
"use strict";

const os = require("os");
const { isCommandTool, commandTextOf } = require("./tool-command-text");
// The detector that opens the CONFIRM dialog decides what counts as a CONFIRM here too, so a
// command the dialog fires on (e.g. an echo inside a compound command) is never missed.
const { parseSentinel } = require("../confirm-checkpoint");
const { STAGES, PLAN_LINK_COMMAND } = require("./plan-link");

// A link ends where path characters stop; one trailing "." or ")" is prose, not the link.
const CONTINUES_RE = /^\.?[A-Za-z0-9_~%/\\-]/;

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
    if (m && STAGES.includes(m.suffix)) found.add(m.suffix);
  }
  for (const entry of Array.isArray(turnEntries) ? turnEntries : []) {
    for (const item of assistantContent(entry)) {
      // Every command tool confirm-checkpoint recognizes, not only Bash.
      if (!item || item.type !== "tool_use" || !isCommandTool(item.name)) continue;
      const hit = parseSentinel(commandTextOf(item.name, item.input));
      if (hit) found.add(hit.stage);
    }
  }
  return STAGES.filter((s) => found.has(s));
}

function containsLink(text, link) {
  if (!link) return false;
  let from = 0;
  for (;;) {
    const i = text.indexOf(link, from);
    if (i === -1) return false;
    if (!CONTINUES_RE.test(text.slice(i + link.length))) return true;
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

// shown(link, text) -> null when the stage needs nothing, else whether the reply shows it.
function shown(link, text) {
  if (!link || typeof link !== "object") return null;
  if (typeof link.url === "string" && link.url) return containsLink(text, link.url);
  if (typeof link.path !== "string" || !link.path) return null;
  return localPathForms(link.path).some((form) => containsLink(text, form));
}

// checkPlanUrlInTurn({ stages, turnText, resolve }) -> { block, reason? }.
// resolve(stage) returns plan-link's { url?, path?, reason? }; a throw or no path never blocks.
function checkPlanUrlInTurn({ stages, turnText, resolve } = {}) {
  const text = typeof turnText === "string" ? turnText : "";
  const missing = [];
  for (const stage of Array.isArray(stages) ? stages : []) {
    let link = null;
    try { link = resolve(stage); } catch (_) { link = null; }
    if (shown(link, text) === false) missing.push(stage);
  }
  if (missing.length === 0) return { block: false };
  return {
    block: true,
    reason: "[confirm-plan] plan-link: this turn wrote or confirmed the " + missing.join(", ") +
      " plan but its plan-link line is not in the response text (the URL when one exists, otherwise the" +
      " local path) — run " + PLAN_LINK_COMMAND + " and write its output as-is in the response text." +
      " (Hook: stop-confirm-plan-guard.js)",
  };
}

module.exports = { collectTurnAssistantText, stagesToCheck, checkPlanUrlInTurn, turnEntriesOf, turnEntriesFromLines };
