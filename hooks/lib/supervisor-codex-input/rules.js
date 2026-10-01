"use strict";

// #2475 transcript rules table: one JSONL entry -> {rule, keep, text} records.
// Evaluated top-down, first match wins. U-* = user utterance (whole transcript),
// A-* = action record (cursor range only), D-* = dropped. This file owns the
// table; the rationale lives in docs/architecture/claude-code/supervisor-codex-input.md.

const SENTINEL_RE = /<<[A-Z][A-Za-z0-9_]*(?::[^>\n]*)?>>/g;
const HOOK_DENY_RE = /^[A-Za-z]+:\S+ hook error:/;
const LEADING_TAG_RE = /^\s*<(ide_opened_file|ide_selection|system-reminder)>[\s\S]*?<\/\1>/;
const EDIT_TOOLS = new Set(["Edit", "Write", "NotebookEdit"]);

function drop(rule) {
  return { rule, keep: false, text: "" };
}

function stripLeadingTags(text) {
  let s = String(text);
  for (let m = s.match(LEADING_TAG_RE); m; m = s.match(LEADING_TAG_RE)) s = s.slice(m[0].length);
  return s.trim();
}

// Text of a string content or of its text blocks, each block tag-stripped; empty blocks vanish.
function strippedBody(content) {
  if (typeof content === "string") return stripLeadingTags(content);
  if (!Array.isArray(content)) return "";
  return content
    .filter((b) => b && b.type === "text" && typeof b.text === "string")
    .map((b) => stripLeadingTags(b.text))
    .filter((t) => t !== "")
    .join("\n");
}

function rawText(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.filter((b) => b && b.type === "text" && typeof b.text === "string").map((b) => b.text).join("\n");
}

function toolResultText(block) {
  const c = block.content;
  if (typeof c === "string") return c;
  if (Array.isArray(c)) return c.filter((b) => b && typeof b.text === "string").map((b) => b.text).join("\n");
  return "";
}

function sentinels(text) {
  return (String(text).match(SENTINEL_RE) || []).map((s) => ({ rule: "A-sentinel", keep: true, text: `sentinel: ${s}` }));
}

function classifyToolResult(block, toolUses) {
  const text = toolResultText(block);
  const useName = toolUses ? toolUses.get(block.tool_use_id) : undefined;
  if (block.is_error && HOOK_DENY_RE.test(text)) return { rule: "A-hook-deny", keep: true, text: `hook-block: ${text}` };
  if (useName === "AskUserQuestion") return { rule: "U-ask-answer", keep: true, text };
  if (block.is_error && useName === "Bash") return { rule: "A-cmd-error", keep: true, text: `error: ${text.split("\n")[0]}` };
  return drop("D-tool-result");
}

function classifyUser(entry, content, ctx) {
  const toolResults = Array.isArray(content) ? content.filter((b) => b && b.type === "tool_result") : [];
  if (toolResults.length > 0) return toolResults.map((b) => classifyToolResult(b, ctx && ctx.toolUses));
  const origin = entry.origin && entry.origin.kind;
  if (origin === "human") {
    const body = strippedBody(content);
    if (body === "" || body.startsWith("[Request interrupted") || body.startsWith("<local-command-")) return drop("U-human");
    return { rule: "U-human", keep: true, text: body };
  }
  const raw = rawText(content);
  if (!origin && raw.startsWith('Answering your earlier question "')) return { rule: "U-deferred-answer", keep: true, text: raw };
  return drop("D-other");
}

function classifyAssistant(content, ctx) {
  const recs = [];
  for (const b of Array.isArray(content) ? content : []) {
    if (!b) continue;
    if (b.type === "text" && typeof b.text === "string") recs.push(...sentinels(b.text));
    if (b.type !== "tool_use") continue;
    if (ctx && ctx.toolUses && b.id) ctx.toolUses.set(b.id, b.name);
    const inp = b.input || {};
    if (b.name === "Bash") {
      recs.push({ rule: "A-bash", keep: true, text: `cmd: ${inp.command}` });
      recs.push(...sentinels(inp.command || ""));
    } else if (EDIT_TOOLS.has(b.name)) {
      recs.push({ rule: "A-edit", keep: true, text: `edit: ${b.name} ${inp.file_path || inp.notebook_path || ""}` });
    } else if (b.name === "Skill") {
      recs.push({ rule: "A-invoke", keep: true, text: `skill: ${inp.skill || ""} ${inp.args || ""}`.trimEnd() });
    } else if (b.name === "Agent") {
      recs.push({ rule: "A-invoke", keep: true, text: `agent: ${inp.subagent_type || ""} ${inp.description || ""}`.trimEnd() });
    }
  }
  return recs.length > 0 ? recs : drop("D-other");
}

function classifyAttachment(att) {
  if (att.type === "queued_command" && att.origin && att.origin.kind === "human") {
    const body = strippedBody(att.prompt);
    return body === "" ? drop("U-queued") : { rule: "U-queued", keep: true, text: body };
  }
  if (att.type === "hook_blocking_error") {
    const be = att.blockingError && typeof att.blockingError === "object" ? att.blockingError.blockingError : att.blockingError;
    return { rule: "A-stop-block", keep: true, text: `hook-block: ${att.hookEvent} ${att.hookName}: ${be}` };
  }
  return drop("D-other");
}

// ctx (optional): { toolUses: Map<tool_use_id, name> } — filled from assistant
// entries, consulted by tool_result entries to pair them.
function classify(entry, ctx) {
  if (!entry || typeof entry !== "object") return drop("D-other");
  if (entry.isSidechain === true) return drop("D-sidechain");
  const content = entry.message ? entry.message.content : undefined;
  if (entry.type === "user") {
    if (entry.isMeta) return drop("D-meta");
    if (entry.isCompactSummary || rawText(content).startsWith("This session is being continued")) return drop("D-compact");
    if (entry.origin && entry.origin.kind === "task-notification") return drop("D-task-notif");
    return classifyUser(entry, content, ctx);
  }
  if (entry.type === "assistant") return classifyAssistant(content, ctx);
  if (entry.type === "attachment" && entry.attachment) return classifyAttachment(entry.attachment);
  return drop("D-other");
}

module.exports = { classify, stripLeadingTags };
