"use strict";
// hooks/lib/settings-allow-match.js — does a permissions.allow/.deny rule cover this
// command string? Semantics SSOT: docs/architecture/claude-code/settings.md "Permission
// glob matching".
//
// Both fail open toward "let it through" on unreadable settings: isAllowRuleMatch ->
// matched (under-matching would deny a granted command); isDenyRuleMatch -> NOT
// matched, since its sole caller only reads a deny match as "withhold the allow-rule
// exemption" — resolving "matched" here would instead force a denial on every
// unreadable-settings + chained-command shape (e.g. `git status && ls`).

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

// Returns null when the file cannot be read or parsed — each caller decides what null
// means for its own fail direction (see header comment).
function readBashPatterns(settingsPath, permissionKey) {
  try {
    const raw = fs.readFileSync(settingsPath, "utf8");
    const parsed = JSON.parse(raw);
    const list = parsed && parsed.permissions && parsed.permissions[permissionKey];
    if (!Array.isArray(list)) return [];
    const out = [];
    for (const entry of list) {
      if (typeof entry !== "string") continue;
      const m = BASH_RULE_RE.exec(entry.trim());
      if (m) out.push(m[1]);
    }
    return out;
  } catch (_e) {
    return null;
  }
}

function loadPatterns(settingsPath, permissionKey) {
  const key = permissionKey + ":" + settingsPath;
  if (!patternCache.has(key)) patternCache.set(key, readBashPatterns(settingsPath, permissionKey));
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

// Shared core for isAllowRuleMatch / isDenyRuleMatch: both check the same glob family
// against the same command text, differing only in which permissions[] array they read
// and what "unreadable settings" should resolve to (onUnreadable — see header comment).
function isRuleMatch(commandText, opts, permissionKey, onUnreadable) {
  try {
    const settingsPath = (opts && opts.settingsPath) || defaultSettingsPath();
    const patterns = loadPatterns(settingsPath, permissionKey);
    if (patterns === null) return onUnreadable;
    if (typeof commandText !== "string") return false;
    const text = commandText.trim();
    for (const pattern of patterns) {
      if (patternToRegExp(pattern).test(text)) return true;
    }
    return false;
  } catch (_e) {
    return onUnreadable;
  }
}

/**
 * @param {string} commandText the raw Bash command
 * @param {{settingsPath?: string}} [opts] test injection point; production reads ~/.claude
 * @returns {boolean} true when a Bash(...) allow rule covers the whole command
 */
function isAllowRuleMatch(commandText, opts) {
  return isRuleMatch(commandText, opts, "allow", true);
}

/**
 * @param {string} commandText the raw Bash command (typically one segment of a chain)
 * @param {{settingsPath?: string}} [opts] test injection point; production reads ~/.claude
 * @returns {boolean} true when a Bash(...) deny rule covers the whole command
 */
function isDenyRuleMatch(commandText, opts) {
  return isRuleMatch(commandText, opts, "deny", false);
}

module.exports = { isAllowRuleMatch, isDenyRuleMatch };
