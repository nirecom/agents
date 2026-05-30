"use strict";

// Per-context language config. Routes language policy queries to .env keys
// (PLAN_LANG, DOCS_LANG_*) in $AGENTS_CONFIG_DIR/.env.
// Fail-open on parse/IO errors: returns "any".

const { loadDefaultEnv } = require("./load-env");

const KEY_MAP = {
  DOCS_LANG_HISTORY_PUBLIC: "historyPublic",
  DOCS_LANG_HISTORY_PRIVATE: "historyPrivate",
  DOCS_LANG_CHANGELOG_PUBLIC: "changelogPublic",
  DOCS_LANG_CHANGELOG_PRIVATE: "changelogPrivate",
};
const DEFAULT_CONFIG = Object.freeze({
  historyPublic: "any",
  historyPrivate: "any",
  changelogPublic: "any",
  changelogPrivate: "any",
});

function defaultConfig() {
  return { ...DEFAULT_CONFIG };
}

function loadDocsLangConfig() {
  loadDefaultEnv();
  const config = defaultConfig();
  for (const envKey of Object.keys(KEY_MAP)) {
    const v = process.env[envKey];
    if (typeof v === "string" && v.length > 0) {
      config[KEY_MAP[envKey]] = normalizeValue(v);
    }
  }
  return config;
}

function normalizeValue(v) {
  if (typeof v !== "string") return "any";
  const trimmed = v.trim().toLowerCase();
  if (trimmed.length === 0) return "any";
  if (/[\x00-\x1f]/.test(trimmed)) return "any";
  return trimmed;
}

const STRICT_POLICIES = new Set(["english", "japanese"]);

function classifyPolicy(policy) {
  if (!policy || policy === "any") return "noop";
  if (STRICT_POLICIES.has(policy)) return "strict";
  return "hint";
}

function loadLangConfig(surface, options) {
  loadDefaultEnv();
  if (surface === "plan") return normalizeValue(process.env.PLAN_LANG);
  if (surface === "history") {
    const cfg = loadDocsLangConfig();
    const isPriv = options && options.isPrivateRepo === true;
    return isPriv ? cfg.historyPrivate : cfg.historyPublic;
  }
  return "any";
}

module.exports = { loadDocsLangConfig, loadLangConfig, classifyPolicy, STRICT_POLICIES };
