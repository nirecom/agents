#!/usr/bin/env node
// Control probe for Section G: reports what hooks/lib/session-markers.js sees for a
// given sid under the CURRENT env, so a "still blocked under the marker" assertion
// cannot pass merely because the fixture marker was never visible in the first place.
"use strict";

const path = require("path");
const agentsDir = process.env.AGENTS_DIR || path.join(__dirname, "..", "..");
const sid = process.argv[2] || "";

let markers;
try {
  markers = require(path.join(agentsDir, "hooks", "lib", "session-markers.js"));
} catch (e) {
  process.stdout.write("MODULE_MISSING\n");
  process.exit(0);
}

const wf = markers.isWorkflowOff(sid) ? "on" : "off";
const wt = markers.isWorktreeOff(sid) ? "on" : "off";
process.stdout.write("workflow-off=" + wf + " worktree-off=" + wt + "\n");
