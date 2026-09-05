"use strict";
// Driver for tests/feature-2170-lib-extractions.sh (#2170 round-2, item C10).
// Modes (print hit | miss, or a scalar); ERROR:<msg> = a predicate threw.
//   --dotenv <cmd>     dotenv-check.js        checkBashCommand
//   --memory <cmd>     memory-path-check.js   bashHitsMemory
//   --history <cmd>    history-path-check.js  bashHitsProtected
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
  case "--memdir": {
    const mod = load("hooks/lib/memory-path-check.js");
    if (typeof mod.MEMORY_DIR !== "string") emit("EXPORT_MISSING");
    emit(mod.MEMORY_DIR.split("\\").join("/"));
    break;
  }
  default:
    emit("BAD_MODE:" + String(mode));
}
