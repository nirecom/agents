"use strict";
// H-1 contract (#1756): the absolute path of the `bin/workflow/next-step`
// entrypoint, resolved from this module's own location.
//
// This is the ONLY module under bin/workflow/lib/next-step/ that may use
// `__filename`. Using `__filename` anywhere else makes the recovery commands we
// print to the user resolve to an internal module path that is not executable as
// a CLI. Resolution is deliberately placement-based rather than
// `require.main.filename` / `process.argv[1]`, both of which depend on who
// launched the process (CPR-8: no implicit environment-dependent branching).

const fs = require("fs");
const path = require("path");

const ENTRYPOINT_PATH = path.resolve(__dirname, "..", "..", "next-step");

// Fail loud at load time, mirroring the startup assertions in ./steps.js:
// a developer error here would otherwise surface only as a broken hint string.
if (!fs.existsSync(ENTRYPOINT_PATH)) {
  process.stderr.write(
    "next-step: entrypoint not found at " + ENTRYPOINT_PATH +
      " (lib/next-step/ was moved?)\n"
  );
  process.exit(1);
}

module.exports = { ENTRYPOINT_PATH };
