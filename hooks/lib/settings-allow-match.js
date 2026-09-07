"use strict";
// hooks/lib/settings-allow-match.js — does a permissions.allow rule already cover this
// command string?
//
// Semantics come from docs/architecture/claude-code/settings.md "Permission glob
// matching": a Bash(<pattern>) rule is matched against the WHOLE command string and is
// never split on `&&`, so `*` is a positional-agnostic wildcard and `git status*` does
// NOT cover `cd /x && git status`. This is an approximation of the host's matcher, not a
// reimplementation: over-matching only silences a presentation guard (harmless), while
// under-matching would deny a command the user explicitly granted (harmful). Every
// ambiguity therefore resolves to the wider side, including unreadable settings.

const fs = require("fs");
const os = require("os");
const path = require("path");

const BASH_RULE_RE = /^Bash\((.*)\)$/;

let cachedDefaultPath = null;
const patternCache = new Map();

function defaultSettingsPath() {
  if (cachedDefaultPath === null) {
    cachedDefaultPath = path.join(os.homedir(), ".claude", "settings.json");
  }
  return cachedDefaultPath;
}

// Returns null when the file cannot be read or parsed — the caller treats null as
// "assume a rule matched", so a broken settings file never turns into a denial.
function readAllowPatterns(settingsPath) {
  try {
    const raw = fs.readFileSync(settingsPath, "utf8");
    const parsed = JSON.parse(raw);
    const allow = parsed && parsed.permissions && parsed.permissions.allow;
    if (!Array.isArray(allow)) return [];
    const out = [];
    for (const entry of allow) {
      if (typeof entry !== "string") continue;
      const m = BASH_RULE_RE.exec(entry.trim());
      if (m) out.push(m[1]);
    }
    return out;
  } catch (_e) {
    return null;
  }
}

function loadPatterns(settingsPath) {
  const key = settingsPath;
  if (!patternCache.has(key)) patternCache.set(key, readAllowPatterns(settingsPath));
  return patternCache.get(key);
}

// A pattern is a glob over the whole string: escape everything, then let runs of `*`
// become `.*`. Anchored at both ends because the host matches the whole command.
//
// A `*` may not begin INSIDE a word: `git status*` grants `git status --short > out.txt`
// but not `git statusfoo && ls`, which merely shares a prefix. The assertion is emitted
// only where the pattern character before the wildcard is itself a word character, so
// `head -*` still covers `head -5 ...` — `-` already ends a word.
const WORD = "A-Za-z0-9_";

function wildcardFor(precedingChar) {
  const guard = new RegExp("[" + WORD + "]").test(precedingChar || "") ? "(?![" + WORD + "])" : "";
  return guard + ".*";
}

function patternToRegExp(pattern) {
  let source = "";
  let i = 0;
  while (i < pattern.length) {
    if (pattern[i] === "*") {
      const preceding = i > 0 ? pattern[i - 1] : "";
      while (pattern[i] === "*") i++;
      source += wildcardFor(preceding);
      continue;
    }
    source += pattern[i].replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    i++;
  }
  return new RegExp("^" + source + "$", "s");
}

/**
 * @param {string} commandText the raw Bash command
 * @param {{settingsPath?: string}} [opts] test injection point; production reads ~/.claude
 * @returns {boolean} true when a Bash(...) allow rule covers the whole command
 */
function isAllowRuleMatch(commandText, opts) {
  try {
    const settingsPath = (opts && opts.settingsPath) || defaultSettingsPath();
    const patterns = loadPatterns(settingsPath);
    if (patterns === null) return true; // fail-open: unreadable rules must not deny
    if (typeof commandText !== "string") return false;
    const text = commandText.trim();
    for (const pattern of patterns) {
      if (patternToRegExp(pattern).test(text)) return true;
    }
    return false;
  } catch (_e) {
    return true;
  }
}

module.exports = { isAllowRuleMatch };
