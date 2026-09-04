"use strict";
// Driver for tests/feature-2170-round3-predicates.sh (#2170 round-3 security fix).
// Modes (print hit | miss, or a scalar):
//   --exec <cmd>   unrecognized-exec-check.js  commandInvokesUnrecognizedExec
//   --egress <cmd> egress-command-check.js     commandIsEgressTool
//   --deny <cmd> / --ask <cmd>  settings-deny-match.js  matchesBash{Deny,Ask}Rule
//   --ask-rule-count            "<bash ask rules>:<rules whose self-probe missed>"
//   --sandbox <dir> <fn> <cmd>  same module COPIED under <dir>, reading
//                               <dir>/settings.json -> hit | miss | THREW
// MODULE_MISSING / EXPORT_MISSING = pre-implementation; THREW = fail-CLOSED.

const path = require("path");

const AGENTS_DIR = process.env.AGENTS_DIR || "";
const mode = process.argv[2];
const arg = process.argv[3] === undefined ? "" : process.argv[3];

function emit(v) {
  console.log(v);
  process.exit(0);
}

function load(abs) {
  try {
    return require(abs);
  } catch (_e) {
    emit("MODULE_MISSING");
  }
  return null;
}

function verdict(mod, fnName, value) {
  if (typeof mod[fnName] !== "function") emit("EXPORT_MISSING");
  try {
    return mod[fnName](value) ? "hit" : "miss";
  } catch (_e) {
    return "THREW";
  }
}

function lib(rel) {
  return load(path.join(AGENTS_DIR, rel));
}

switch (mode) {
  case "--exec":
    emit(verdict(lib("hooks/lib/unrecognized-exec-check.js"), "commandInvokesUnrecognizedExec", arg));
    break;
  case "--egress":
    emit(verdict(lib("hooks/lib/egress-command-check.js"), "commandIsEgressTool", arg));
    break;
  case "--deny":
    emit(verdict(lib("hooks/lib/settings-deny-match.js"), "matchesBashDenyRule", arg));
    break;
  case "--ask":
    emit(verdict(lib("hooks/lib/settings-deny-match.js"), "matchesBashAskRule", arg));
    break;
  case "--ask-rule-count": {
    // A fail-soft settings read yields an EMPTY ask list, silently un-guarding
    // every ask rule inside a body. Each rule is probed against its own literal
    // self (`*` -> `X`).
    const settings = require(path.join(AGENTS_DIR, "settings.json"));
    const ask = (settings.permissions && settings.permissions.ask) || [];
    const bashRules = ask.filter((r) => typeof r === "string" && /^Bash\(/.test(r.trim()));
    const mod = lib("hooks/lib/settings-deny-match.js");
    const unmatched = bashRules.filter((r) => {
      const inner = /^Bash\(([\s\S]*)\)$/.exec(r.trim());
      if (!inner) return true;
      return !mod.matchesBashAskRule(inner[1].split("*").join("X"));
    });
    emit(bashRules.length + ":" + unmatched.length);
    break;
  }
  case "--sandbox": {
    // The module resolves settings.json from its OWN __dirname, so a copy at
    // <dir>/hooks/lib/ reads <dir>/settings.json — the only way to hand it a
    // broken or absent settings file without touching the real one.
    const mod = load(path.join(process.argv[3], "hooks", "lib", "settings-deny-match.js"));
    emit(verdict(mod, process.argv[4], process.argv[5] === undefined ? "" : process.argv[5]));
    break;
  }
  default:
    emit("BAD_MODE:" + String(mode));
}
