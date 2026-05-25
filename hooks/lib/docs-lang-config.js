"use strict";

// Parses the `docs-lang` fenced block from language.md.
// Returns {history, changelogPublic, changelogPrivate} where each value is
// "english" | "japanese" | "any". Missing file, missing block, unknown values,
// and unrecognized keys all fall back to "any" (fail-open).

const fs = require("fs");

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
  if (!langFilePath) return defaultConfig();
  let text;
  try {
    text = fs.readFileSync(langFilePath, "utf8");
  } catch (e) {
    return defaultConfig();
  }
  const body = extractDocsLangBlock(text);
  if (body === null) return defaultConfig();
  return parseDocsLangBody(body);
}

module.exports = { loadDocsLangConfig };
