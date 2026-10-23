"use strict";

// Per-context language config. Routes language policy queries to .env keys
// (PLAN_LANG, DOCS_LANG_PUBLIC, DOCS_LANG_PRIVATE) in $AGENTS_MAIN_ROOT/.env.
// Fail-open on parse/IO errors: returns "any".

const { loadDefaultEnv, readDefaultEnvFile } = require("./load-env");

const KEY_MAP = {
  DOCS_LANG_PUBLIC: "public",
  DOCS_LANG_PRIVATE: "private",
};
const DEFAULT_CONFIG = Object.freeze({
  public: "any",
  private: "any",
});

const LEGACY_KEYS = ["DOCS_LANG_HISTORY_PUBLIC", "DOCS_LANG_HISTORY_PRIVATE", "DOCS_LANG_CHANGELOG_PUBLIC", "DOCS_LANG_CHANGELOG_PRIVATE"];
let legacyWarned = false;

function defaultConfig() {
  return { ...DEFAULT_CONFIG };
}

// Legacy keys are read from the .env FILE, never process.env: a stale shell
// export must not raise a warning the user cannot act on by editing .env.
function warnOnLegacyKeys() {
  if (legacyWarned) return;
  try {
    const fileEnv = readDefaultEnvFile() || {};
    const present = LEGACY_KEYS.filter((k) => typeof fileEnv[k] === "string" && fileEnv[k].length > 0);
    if (present.length === 0) return;
    legacyWarned = true;
    process.stderr.write(`lang-config: ignoring legacy key(s) ${present.join(", ")} — replaced by DOCS_LANG_PUBLIC / DOCS_LANG_PRIVATE. Update .env.\n`);
  } catch (e) {
    // fail-open: a warning must never break the caller
  }
}

function loadDocsLangConfig() {
  loadDefaultEnv();
  warnOnLegacyKeys();
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
  // eslint-disable-next-line no-control-regex -- rejecting control characters is the purpose
  if (/[\x00-\x1f]/.test(trimmed)) return "any";
  return trimmed;
}

// Shape guard for any language value spliced into injected prompt context.
// Not an allowlist of languages — free-text names in any script pass
// ("brazilian portuguese", "español", "日本語"); anything carrying injection
// framing (parens, colons, newlines, backticks, $, quotes) or over 40 chars does
// not. \p{M} keeps decomposed accents and Vietnamese tone marks legal.
// Applied to the already trimmed+lowercased value.
// lang-check: ignore -- the non-English examples above are the point of the comment.
const LANGUAGE_NAME_RE = /^[\p{L}][\p{L}\p{M}' -]{0,39}$/u;

function isPlausibleLanguageName(v) {
  return typeof v === "string" && LANGUAGE_NAME_RE.test(v);
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
  if (surface === "code") return normalizeValue(process.env.CODE_LANG);
  if (surface === "history") {
    const cfg = loadDocsLangConfig();
    const isPriv = options && options.isPrivateRepo === true;
    return isPriv ? cfg.private : cfg.public;
  }
  return "any";
}

// Proactive PLAN_LANG directive for planning contexts; the wording lives in the PLAN_LANG line of
// lang-directives.txt. Distinct from conv-lang's "Respond to the user..." — targets plan files,
// not the conversation reply. resolvePlanLang() returns the guarded name, or null when PLAN_LANG
// is noop (unset/""/any/control-char) or not a plausible language name.
// Note the asymmetry with CONV_LANG: "english" is a valid directive here (not null).
function resolvePlanLang() {
  const lang = loadLangConfig("plan");
  if (classifyPolicy(lang) === "noop") return null;
  if (!isPlausibleLanguageName(lang)) return null;
  return lang;
}

function getPlanLangInjection() {
  const lang = resolvePlanLang();
  return lang ? require("./lang-directive").renderDirective("PLAN_LANG", lang) : null;
}

// Raw CODE_LANG_EXCLUDE string (semicolon-separated absolute paths / globs).
// Deliberately NOT passed through normalizeValue(): lowercasing/trimming would
// corrupt path comparisons (POSIX paths are case-sensitive; Windows-side
// lowercasing is applied downstream by path-coverage-match.js). Unset or
// non-string -> "".
function loadCodeLangExclude() {
  loadDefaultEnv();
  const v = process.env.CODE_LANG_EXCLUDE;
  return typeof v === "string" ? v : "";
}

module.exports = { loadDocsLangConfig, loadLangConfig, classifyPolicy, STRICT_POLICIES, isPlausibleLanguageName, resolvePlanLang, getPlanLangInjection, loadCodeLangExclude };
