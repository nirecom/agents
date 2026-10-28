"use strict";
const { loadDefaultEnv } = require("./load-env");
const { isPlausibleLanguageName } = require("./lang-config");
const { renderDirective } = require("./lang-directive");

// The guarded CONV_LANG name, or null when no directive applies (unset, english, any, invalid).
function resolveConvLang() {
  loadDefaultEnv();
  const raw = process.env.CONV_LANG;
  if (typeof raw !== "string") return null;
  const normalized = raw.trim().toLowerCase();
  if (normalized.length === 0 || normalized === "english" || normalized === "any") return null;
  // eslint-disable-next-line no-control-regex -- rejecting control characters is the purpose
  if (/[\x00-\x1f]/.test(normalized)) return null;
  if (!isPlausibleLanguageName(normalized)) return null;
  return normalized;
}

function getConvLangInjection() {
  const lang = resolveConvLang();
  return lang ? renderDirective("CONV_LANG", lang) : null;
}

// withConvLang(text) — the single CONV_LANG wrapper for a block reason: prepends the injection
// once, or returns text unchanged when none applies (#2699). Callers wrap a reason exactly once.
function withConvLang(text) {
  const inj = getConvLangInjection();
  return inj ? `${inj}\n${text}` : text;
}

module.exports = { resolveConvLang, getConvLangInjection, withConvLang };
