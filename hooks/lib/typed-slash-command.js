"use strict";
// classifyTypedSlashCommand(prompt, names) -> {status: "hit"|"none"|"undecidable", name, args, reason} (#2942);
// typedSlashCommand(prompt, names) -> {name, args} | null, the hit-only view (#2941).
// A typed slash command reaches UserPromptSubmit either wrapped (<command-message>/<command-name>/
// <command-args>) or bare on the first line; both forms are anchored at the prompt start once the leading
// IDE / paste wrappers are read off, so a mention inside prose or a <cross-session-message> body is never an
// invocation. A leading wrapper that cannot be read makes the verdict undecidable.
// DEPENDENCY-FREE ON PURPOSE: hooks/lib/step-in-flight-policy.js delegates here; leading-wrapper.js is a leaf.

const { stripLeadingWrappers } = require("./leading-wrapper");

const WRAPPED_RE = /^(?:<command-message>[\s\S]*?<\/command-message>\s*)?<command-name>\/(?:[\w-]+:)?([\w-]+)<\/command-name>/;
const ARGS_RE = /<command-args>([\s\S]*?)<\/command-args>/;
const BARE_RE = /^\/(?:[\w-]+:)?([\w-]+)(?![\w-])(.*)$/;

function pick(names, name) {
  const lowered = name.toLowerCase();
  return (names || []).find((n) => String(n).toLowerCase() === lowered) || null;
}

function match(text, names) {
  if (text.startsWith("<cross-session-message")) return null;
  const w = text.match(WRAPPED_RE);
  if (w) {
    const name = pick(names, w[1]);
    if (!name) return null;
    const a = text.slice(w[0].length).match(ARGS_RE);
    return { name, args: a ? a[1].trim() : "" };
  }
  const b = text.split(/\r?\n/)[0].match(BARE_RE);
  if (!b) return null;
  const name = pick(names, b[1]);
  return name ? { name, args: b[2].trim() } : null;
}

function classifyTypedSlashCommand(prompt, names) {
  const none = { status: "none", name: null, args: null, reason: null };
  if (typeof prompt !== "string") return none;
  const w = stripLeadingWrappers(prompt);
  if (!w.ok) return { status: "undecidable", name: null, args: null, reason: w.reason };
  const hit = match(w.text, names);
  return hit ? { status: "hit", name: hit.name, args: hit.args, reason: null } : none;
}

function typedSlashCommand(prompt, names) {
  const c = classifyTypedSlashCommand(prompt, names);
  return c.status === "hit" ? { name: c.name, args: c.args } : null;
}

module.exports = { classifyTypedSlashCommand, typedSlashCommand };
