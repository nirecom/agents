#!/usr/bin/env node
"use strict";
// /migrate-issues is needed until .agents.json records migrate.issues done (set by orchestrate.sh
// Step 6). Reads the repo settings file only; never calls a forge API.
// CLI: node needs.js [--root <dir>] → exit 0 done, 10 needed.

const path = require("path");
const RS = require(path.join(__dirname, "..", "..", "..", "hooks", "lib", "repo-settings"));

const key = "issues";
const needs = (root) => !RS.migrateDone(root, key);

module.exports = { key, needs };

if (require.main === module) {
  const i = process.argv.indexOf("--root");
  process.exit(needs(i > 0 && process.argv[i + 1] ? process.argv[i + 1] : process.cwd()) ? 10 : 0);
}
