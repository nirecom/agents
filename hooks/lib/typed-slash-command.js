"use strict";
// typedSlashCommand(prompt, names) -> {name, args} | null (#2941).
// A typed slash command reaches UserPromptSubmit either wrapped (<command-message>/<command-name>/
// <command-args>) or bare on the first line; both forms are anchored at the prompt start, so a
// mention inside prose or a <cross-session-message> body is never an invocation.
// DEPENDENCY-FREE ON PURPOSE: hooks/lib/step-in-flight-policy.js delegates here.

const WRAPPED_RE = /^(?:<command-message>[\s\S]*?<\/command-message>\s*)?<command-name>\/(?:[\w-]+:)?([\w-]+)<\/command-name>/;
const ARGS_RE = /<command-args>([\s\S]*?)<\/command-args>/;
const BARE_RE = /^\/(?:[\w-]+:)?([\w-]+)(?![\w-])(.*)$/;

function pick(names, name) {
  const lowered = name.toLowerCase();
  return (names || []).find((n) => String(n).toLowerCase() === lowered) || null;
}

function typedSlashCommand(prompt, names) {
  if (typeof prompt !== "string") return null;
  const text = prompt.replace(/^\s+/, "");
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

module.exports = { typedSlashCommand };
