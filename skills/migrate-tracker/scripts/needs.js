#!/usr/bin/env node
"use strict";
// /migrate-tracker is needed until .agents.json records migrate.tracker done (set by record-done
// only after the board exists). Reads the repo settings file only; never calls a forge API.
// CLI: node needs.js [--root <dir>] → exit 0 done, 10 needed.

const path = require("path");
const RS = require(path.join(__dirname, "..", "..", "..", "hooks", "lib", "repo-settings"));

const key = "tracker";
const needs = (root) => !RS.migrateDone(root, key);

module.exports = { key, needs };

if (require.main === module) {
  const i = process.argv.indexOf("--root");
  process.exit(needs(i > 0 && process.argv[i + 1] ? process.argv[i + 1] : process.cwd()) ? 10 : 0);
}
