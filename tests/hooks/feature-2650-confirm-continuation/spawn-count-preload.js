"use strict";
// NODE_OPTIONS --require preload: appends one line to CC_SPAWN_LOG for every child process whose
// argv names bin/confirm-off (the CONFIRM gate probe), then runs the real call unchanged.
// Patched before any hook module loads, so hooks/lib/confirm-gate/probe.js picks up the wrappers
// when it destructures child_process at require time.
const fs = require("fs");
const cp = require("child_process");

const LOG = process.env.CC_SPAWN_LOG;
function note(file, args) {
  try {
    const argv = [file].concat(Array.isArray(args) ? args : []).map(String).join(" ");
    if (LOG && /confirm-off/.test(argv)) fs.appendFileSync(LOG, argv + "\n");
  } catch (_) { /* counting never changes the hook's behavior */ }
}
for (const name of ["spawnSync", "execFile", "execFileSync", "spawn"]) {
  const orig = cp[name];
  cp[name] = function (file, args, ...rest) {
    note(file, args);
    return orig.call(this, file, args, ...rest);
  };
}
