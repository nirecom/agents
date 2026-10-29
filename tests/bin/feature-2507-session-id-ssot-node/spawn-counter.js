"use strict";
// Tests: bin/check-session-id-ssot/main.js
// Tags: TL1, bin, session-id, fixture, test-lang-exception:symmetry, scope:issue-specific
// Spawn counter of tests/bin/feature-2507-session-id-ssot-node.js (#2507 D7). Holds no case markers.
// install() patches every process-starting function on the child_process module object; it must run
// before bin/check-session-id-ssot/main.js is required, so a destructured import gets the patched one.
// Calls are recorded only while armed (around one run()), so the test's own spawns never count.
const cp = require("node:child_process");

const NAMES = ["spawn", "spawnSync", "exec", "execSync", "execFile", "execFileSync", "fork"];
let armed = false;
let calls = [];
let installed = false;

function install() {
  if (installed) return;
  installed = true;
  for (const name of NAMES) {
    const orig = cp[name];
    cp[name] = function counted(command, ...rest) {
      if (armed) calls.push({ fn: name, command: String(command) });
      return orig.call(this, command, ...rest);
    };
  }
}

// during(fn) — runs fn (sync or async) armed; resolves to the calls it made.
async function during(fn) {
  calls = [];
  armed = true;
  try {
    await fn();
  } finally {
    armed = false;
  }
  return calls.slice();
}

module.exports = { install, during };
