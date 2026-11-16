#!/usr/bin/env node
"use strict";
// PreToolUse gate for the RESET_FROM sentinel (#2852): dispatch only (Pattern A).
// Stage 1 (./gate-reset-from-sentinel/classify.js) abstains on anything without the sentinel and
// asks on a look-alike; stage 2 (./gate-reset-from-sentinel/judge.js) answers allow or ask. Never deny.

const { classify } = require("./gate-reset-from-sentinel/classify");

const c = classify();
if (c.kind === "none") {
  console.log("{}");
} else if (c.kind === "ask") {
  console.log(JSON.stringify(require("./lib/permission-decision-output").ask(c.reason)));
} else {
  console.log(JSON.stringify(require("./gate-reset-from-sentinel/judge").judge(c)));
}
process.exit(0);
