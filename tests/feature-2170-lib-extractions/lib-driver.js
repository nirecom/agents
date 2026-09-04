"use strict";
// Driver for tests/feature-2170-lib-extractions.sh (#2170 round-2, item C10).
// Modes (print hit | miss, or a scalar); ERROR:<msg> = a predicate threw.
//   --dotenv <cmd>     dotenv-check.js        checkBashCommand
//   --memory <cmd>     memory-path-check.js   bashHitsMemory
//   --history <cmd>    history-path-check.js  bashHitsProtected
//   --deny <cmd>       settings-deny-match.js matchesBashDenyRule
//   --rule <pat> <cmd> settings-deny-match.js ruleToRegExp(pat).test
//   --deny-rule-count  "<bash rules>:<rules whose own self-probe missed>"
//   --memdir           MEMORY_DIR, forward-slashed, for the bash side to reuse

const path = require("path");

const AGENTS_DIR = process.env.AGENTS_DIR || "";
const mode = process.argv[2];
const arg = process.argv[3] === undefined ? "" : process.argv[3];

function emit(v) {
  console.log(v);
  process.exit(0);
}

function load(rel) {
  try {
    return require(path.join(AGENTS_DIR, rel));
  } catch (_e) {
    emit("MODULE_MISSING");
  }
  return null;
}

function verdict(mod, fnName, value) {
  if (typeof mod[fnName] !== "function") emit("EXPORT_MISSING");
  try {
    return mod[fnName](value) ? "hit" : "miss";
  } catch (e) {
    return "ERROR:" + (e && e.message ? e.message : String(e));
  }
}

switch (mode) {
  case "--dotenv":
    emit(verdict(load("hooks/lib/dotenv-check.js"), "checkBashCommand", arg));
    break;
  case "--memory":
    emit(verdict(load("hooks/lib/memory-path-check.js"), "bashHitsMemory", arg));
    break;
  case "--history":
    emit(verdict(load("hooks/lib/history-path-check.js"), "bashHitsProtected", arg));
    break;
  case "--deny":
    emit(verdict(load("hooks/lib/settings-deny-match.js"), "matchesBashDenyRule", arg));
    break;
  case "--rule": {
    const mod = load("hooks/lib/settings-deny-match.js");
    if (typeof mod.ruleToRegExp !== "function") emit("EXPORT_MISSING");
    try {
      emit(mod.ruleToRegExp(arg).test(process.argv[4] === undefined ? "" : process.argv[4]) ? "hit" : "miss");
    } catch (e) {
      emit("ERROR:" + (e && e.message ? e.message : String(e)));
    }
    break;
  }
  case "--deny-rule-count": {
    // settings.json is resolved from __dirname, not cwd, and a wrong resolution
    // fails SOFT (empty rule list) — so this count is the only signal that every
    // Bash deny rule really reaches a script body.
    const settings = require(path.join(AGENTS_DIR, "settings.json"));
    const deny = (settings.permissions && settings.permissions.deny) || [];
    const bashRules = deny.filter((r) => typeof r === "string" && /^Bash\(/.test(r.trim()));
    const mod = load("hooks/lib/settings-deny-match.js");
    const unmatched = bashRules.filter((r) => {
      const inner = /^Bash\(([\s\S]*)\)$/.exec(r.trim());
      if (!inner) return true;
      return !mod.matchesBashDenyRule(inner[1].split("*").join("X"));
    });
    emit(bashRules.length + ":" + unmatched.length);
    break;
  }
  case "--memdir": {
    const mod = load("hooks/lib/memory-path-check.js");
    if (typeof mod.MEMORY_DIR !== "string") emit("EXPORT_MISSING");
    emit(mod.MEMORY_DIR.split("\\").join("/"));
    break;
  }
  default:
    emit("BAD_MODE:" + String(mode));
}
