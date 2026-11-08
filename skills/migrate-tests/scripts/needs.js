#!/usr/bin/env node
"use strict";
// /migrate-tests is needed while the .agents.json tests section is missing or malformed, or until
// .agents.json records migrate.tests done (set by apply-section.sh). Reads the repo settings file only.
// CLI: node needs.js [--root <dir>] → exit 0 done, 10 needed.

const path = require("path");
const RS = require(path.join(__dirname, "..", "..", "..", "hooks", "lib", "repo-settings"));

const key = "tests";
const needs = (root) => RS.load(root).tests.state !== "ok" || !RS.migrateDone(root, key);

module.exports = { key, needs };

if (require.main === module) {
  const i = process.argv.indexOf("--root");
  process.exit(needs(i > 0 && process.argv[i + 1] ? process.argv[i + 1] : process.cwd()) ? 10 : 0);
}
