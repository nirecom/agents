"use strict";
// Test-only preload for the feature-2461-*.js tests (#2461): loaded with NODE_OPTIONS
// `--require <this file>`, it wraps child_process spawn / spawnSync / execFileSync / execFile
// and appends one JSON line per call ({script, file, args}) to $SPY_LOG before delegating.
// NODE_OPTIONS is inherited, so every node child of the process under test is spied on too.
// Holds no cases of its own; a missing SPY_LOG leaves child_process untouched.

const fs = require("fs");
const cp = require("child_process");

const LOG = process.env.SPY_LOG;
if (LOG) {
  const note = (file, args) => {
    try {
      const line = { script: String(process.argv[1] || ""), file: String(file), args: Array.isArray(args) ? args.map(String) : [] };
      fs.appendFileSync(LOG, JSON.stringify(line) + "\n");
    } catch (_e) { /* the spy never changes the outcome of the call */ }
  };
  for (const name of ["spawn", "spawnSync", "execFileSync", "execFile"]) {
    const orig = cp[name];
    if (typeof orig !== "function") continue;
    cp[name] = function spied(file, args, ...rest) {
      note(file, args);
      return orig.call(this, file, args, ...rest);
    };
  }
}
