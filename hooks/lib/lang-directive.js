"use strict";
// Reader for hooks/lib/lang-directives.txt, the SSOT of the language directives (#2731).
// renderDirective(key, lang) fills {lang} and {terms}; a missing or broken line falls back per key
// to the fixed sentence below, and a broken TERMS line only drops the terms sentence.
// Callers pass an already guarded language name (conv-lang.js / lang-config.js).
// CLI: `node lang-directive.js --codex conv|plan` prints the CODEX_FREE_TEXT line, or nothing
// when the language is a noop; it always exits 0.
// Design: docs/architecture/claude-code/lang-directives.md.

const fs = require("fs");
const path = require("path");

let templateFile = path.join(__dirname, "lang-directives.txt");
let cache = null;

// The pre-template sentences; no TERMS fallback, so the terms sentence lives only in the template.
const FALLBACK = Object.freeze({
  CONV_LANG: "Respond to the user in {lang}. This applies to all text you write, including narration between tool calls.",
  PLAN_LANG: "Write planning artifacts (files under the plans directory) in {lang}.",
  CODEX_FREE_TEXT: "Write every free-text field (detail, summary, concern text) in {lang}.",
});
const CONV_PREFIX = "Respond to the user in {lang}.";
const MAX_DIRECTIVE = 600;
const MAX_TERMS = 300;

// Returns {} for a missing or unreadable file; read once and cached.
function readTemplates() {
  if (cache) return cache;
  const out = {};
  try {
    for (const line of fs.readFileSync(templateFile, "utf8").split(/\r?\n/)) {
      if (line.startsWith("#")) continue;
      const m = /^([A-Z][A-Z0-9_]*)=(.*)$/.exec(line);
      if (m) out[m[1]] = m[2];
    }
  } catch (_) {
    /* fail-open: every key falls back */
  }
  cache = out;
  return out;
}

function _setTemplateFileForTest(p) {
  templateFile = p;
  cache = null;
}

const hasPlaceholder = (v) => v.includes("{lang}") || v.includes("{terms}");

function renderTerms() {
  const v = readTemplates().TERMS;
  if (typeof v !== "string" || v.length === 0 || v.length > MAX_TERMS || /[\r\n]/.test(v) || hasPlaceholder(v)) return "";
  return v;
}

// The length cap excludes the {terms} placeholder: TERMS carries its own cap.
function usable(key, v) {
  if (typeof v !== "string" || !v.includes("{lang}") || /[\r\n]/.test(v)) return false;
  if (v.split("{terms}").join("").length > MAX_DIRECTIVE) return false;
  return key !== "CONV_LANG" || v.startsWith(CONV_PREFIX);
}

function renderDirective(key, lang) {
  if (!Object.prototype.hasOwnProperty.call(FALLBACK, key)) return null;
  const v = readTemplates()[key];
  const tpl = usable(key, v) ? v : FALLBACK[key];
  const terms = renderTerms();
  return tpl.split("{terms}").join(terms).split("{lang}").join(lang).trimEnd();
}

function codexLine(kind) {
  let lang = null;
  if (kind === "conv") lang = require("./conv-lang").resolveConvLang();
  else if (kind === "plan") lang = require("./lang-config").resolvePlanLang();
  return lang ? renderDirective("CODEX_FREE_TEXT", lang) : null;
}

if (require.main === module) {
  try {
    const i = process.argv.indexOf("--codex");
    const line = i >= 0 ? codexLine(process.argv[i + 1]) : null;
    if (line) process.stdout.write(`${line}\n`);
  } catch (_) {
    /* fail-open: print nothing */
  }
  process.exitCode = 0;
}

module.exports = { FALLBACK, readTemplates, renderTerms, renderDirective, _setTemplateFileForTest };
