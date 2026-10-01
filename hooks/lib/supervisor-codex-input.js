#!/usr/bin/env node
"use strict";

// #2475 supervisor codex input assembler (entry: dispatch + re-export only).
// Usage: node supervisor-codex-input.js --mode alert|audit --sid <sid> --wsid <wsid|UNAVAILABLE>
//   --transcript <path> [--artifact <path>] [--state-snapshot <path>] [--plan-scope intent|all] --out <file>

const { main } = require("./supervisor-codex-input/cli");
const { assemble, defang } = require("./supervisor-codex-input/assemble");
const { classify } = require("./supervisor-codex-input/rules");
const cursor = require("./supervisor-codex-input/cursor");

if (require.main === module) process.exitCode = main(process.argv.slice(2));

module.exports = { assemble, defang, classify, cursor };
