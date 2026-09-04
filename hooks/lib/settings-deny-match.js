// Evaluates a Bash command string against the `permissions.deny` and
// `permissions.ask` rules of settings.json (plus settings-extension.json).
// Consumer: hooks/preuse-auto-approve/script-body-scan.js — the harness applies
// these rules to the OUTER command only, so a script body has to be measured
// against the same lists before its invocation may be auto-approved.
// An unreadable or unparsable settings file THROWS: that caller answers a thrown
// predicate "suspect", so uncertainty must not become "no match".
//
// agentsRoot resolution mirrors hooks/lib/settings-drift.js: __dirname reaches
// the canonical settings.json whichever worktree triggered the hook.
"use strict";

const fs = require("fs");
const path = require("path");

const agentsRoot = path.resolve(__dirname, "..", "..");
const BASH_RULE_RE = /^Bash\(([\s\S]*)\)$/;
const REGEX_META_RE = /[.*+?^${}()|[\]\\]/g;

// A rule's `*` is the harness's own wildcard: any run of characters. Every
// other character is literal, so each inter-wildcard run is regex-escaped.
function ruleToRegExp(pattern) {
  const literals = pattern.split("*").map((p) => p.replace(REGEX_META_RE, "\\$&"));
  return new RegExp("^" + literals.join("[\\s\\S]*") + "$");
}

// Throws on an unreadable or unparsable file. Two cases are legitimately empty,
// not failures: a present file whose `permissions.<key>` is absent or non-array,
// and an absent `optional` file — settings-extension.json is a private overlay
// that only some checkouts carry.
function readRules(file, key, optional) {
  let text;
  try {
    text = fs.readFileSync(file, "utf8");
  } catch (e) {
    if (optional === true && e && e.code === "ENOENT") return [];
    throw e;
  }
  const parsed = JSON.parse(text);
  const rules = parsed && parsed.permissions && parsed.permissions[key];
  return Array.isArray(rules) ? rules : [];
}

function compileRules(key) {
  const rules = readRules(path.join(agentsRoot, "settings.json"), key, false)
    .concat(readRules(path.join(agentsRoot, "settings-extension.json"), key, true));
  const out = [];
  for (const rule of rules) {
    if (typeof rule !== "string") continue;
    const m = BASH_RULE_RE.exec(rule.trim());
    if (!m) continue;
    try {
      out.push(ruleToRegExp(m[1]));
    } catch (_e) {
      // An uncompilable rule is skipped rather than failing the whole list.
    }
  }
  return out;
}

let _compiledDeny = null;
let _compiledAsk = null;

// Only a successful compile is cached, so a failing read is retried — and keeps
// throwing — instead of being frozen into a permanently empty rule list.
function denyMatchers() {
  if (_compiledDeny === null) _compiledDeny = compileRules("deny");
  return _compiledDeny;
}

function askMatchers() {
  if (_compiledAsk === null) _compiledAsk = compileRules("ask");
  return _compiledAsk;
}

function matchesRule(cmd, matchers) {
  if (typeof cmd !== "string" || cmd === "") return false;
  const trimmed = cmd.trim();
  return matchers().some((re) => re.test(trimmed));
}

// Both propagate a settings-read failure to the caller by design.
function matchesBashDenyRule(cmd) {
  return matchesRule(cmd, denyMatchers);
}

function matchesBashAskRule(cmd) {
  return matchesRule(cmd, askMatchers);
}

module.exports = { matchesBashDenyRule, matchesBashAskRule, ruleToRegExp };
