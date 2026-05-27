"use strict";

// Per-context language config. Routes language policy queries to either
// .env keys (PLAN_LANG, ASK_LANG, DOCS_LANG_*) or the legacy docs-lang fenced
// block in rules/language.md. Fail-open on parse/IO errors: returns "any".

const fs = require("fs");
const { loadDefaultEnv } = require("./load-env");

const VALID_VALUES = new Set(["english", "japanese", "any"]);
const KEY_MAP = {
  DOCS_LANG_HISTORY: "history",
  DOCS_LANG_CHANGELOG_PUBLIC: "changelogPublic",
  DOCS_LANG_CHANGELOG_PRIVATE: "changelogPrivate",
};
const DEFAULT_CONFIG = Object.freeze({
  history: "any",
  changelogPublic: "any",
  changelogPrivate: "any",
});

function defaultConfig() {
  return { ...DEFAULT_CONFIG };
}

// Extract body of the first ```docs-lang ... ``` fenced block.
// Tolerates 3+ backticks for the outer fence.
function extractDocsLangBlock(text) {
  const lines = text.split(/\r?\n/);
  let inBlock = false;
  let fenceLen = 0;
  const collected = [];
  for (const line of lines) {
    const trimmed = line.trimStart();
    if (!inBlock) {
      const m = trimmed.match(/^(`{3,})docs-lang\s*$/);
      if (m) {
        inBlock = true;
        fenceLen = m[1].length;
      }
      continue;
    }
    // In block — look for matching-or-longer closing fence.
    const close = trimmed.match(/^(`{3,})\s*$/);
    if (close && close[1].length >= fenceLen) {
      return collected.join("\n");
    }
    collected.push(line);
  }
  // Unterminated block: return what we have if any, else null.
  return inBlock ? collected.join("\n") : null;
}

function parseDocsLangBody(body) {
  const config = defaultConfig();
  if (!body) return config;
  const lines = body.split(/\r?\n/);
  for (const raw of lines) {
    const line = raw.trim();
    if (!line) continue;
    if (line.startsWith("#")) continue;
    const eqIdx = line.indexOf("=");
    if (eqIdx <= 0) continue;
    const key = line.slice(0, eqIdx).trim();
    const value = line.slice(eqIdx + 1).trim();
    const configKey = KEY_MAP[key];
    if (!configKey) continue;
    if (VALID_VALUES.has(value)) {
      config[configKey] = value;
    } else {
      config[configKey] = "any";
    }
  }
  return config;
}

function loadDocsLangConfig(langFilePath) {
  // Load .env first so DOCS_LANG_* keys can override the fenced block.
  loadDefaultEnv();
  let config;
  if (!langFilePath) {
    config = defaultConfig();
  } else {
    let text;
    try {
      text = fs.readFileSync(langFilePath, "utf8");
    } catch {
      config = defaultConfig();
      text = null;
    }
    if (text !== null && text !== undefined) {
      const body = extractDocsLangBlock(text);
      config = body === null ? defaultConfig() : parseDocsLangBody(body);
    }
  }
  // .env DOCS_LANG_* keys override fenced-block values.
  for (const envKey of Object.keys(KEY_MAP)) {
    const v = process.env[envKey];
    if (typeof v === "string" && v.length > 0) {
      config[KEY_MAP[envKey]] = VALID_VALUES.has(v) ? v : "any";
    }
  }
  return config;
}

function normalizeValue(v) {
  if (typeof v !== "string") return "any";
  return VALID_VALUES.has(v) ? v : "any";
}

function loadLangConfig(surface, langFilePath) {
  loadDefaultEnv();
  if (surface === "plan") return normalizeValue(process.env.PLAN_LANG);
  if (surface === "ask") return normalizeValue(process.env.ASK_LANG);
  if (surface === "history") {
    return loadDocsLangConfig(langFilePath).history;
  }
  return "any";
}

module.exports = { loadDocsLangConfig, loadLangConfig };
