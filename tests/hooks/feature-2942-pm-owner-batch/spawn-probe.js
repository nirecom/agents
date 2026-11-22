"use strict";
// Preload of tests/hooks/feature-2942-pm-owner-batch.js (#2942 S21), loaded into every node child through
// NODE_OPTIONS --require. It appends one JSON line (the argv after the script) to $PM_SPAWN_PROBE_LOG each
// time a process runs `bin/pm-state owner`, so the test counts owner spawns without touching the source.
const fs = require("node:fs");
const path = require("node:path");

const log = process.env.PM_SPAWN_PROBE_LOG;
const script = process.argv[1] ? path.basename(process.argv[1]) : "";
if (log && script === "pm-state" && process.argv[2] === "owner") {
  try { fs.appendFileSync(log, `${JSON.stringify(process.argv.slice(2))}\n`); } catch (_) { /* the count then reads 0 */ }
}
