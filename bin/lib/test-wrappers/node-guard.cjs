"use strict";
// bin/lib/test-wrappers/node-guard.cjs — preloaded (--require) by node.js into the one run of a file.
// A file can reach node:test by any route (a literal import, a variable, a helper module); the
// runtime knows what was loaded, so on exit this leaves a marker file that tells the wrapper to
// settle the run as a node:test run. The marker path arrives in an env var that is removed before
// the test code starts (#2501 D4-3).

const fs = require("fs");

const marker = process.env.RUN_ALL_NODE_GUARD_MARKER;
delete process.env.RUN_ALL_NODE_GUARD_MARKER;

const loadedTestRunner = () =>
  process.moduleLoadList.some((m) => m === "NativeModule test" || m.includes("internal/test_runner/"));

process.on("exit", () => {
  if (!marker || !loadedTestRunner()) return;
  try {
    fs.writeFileSync(marker, "node:test\n");
  } catch {
    // Without the marker the wrapper still settles by the case records the reporter wrote.
  }
});
