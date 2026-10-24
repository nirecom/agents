"use strict";
// hooks/bash-guard/git-deviant/clean.js — `git clean` argv -> form id, or null.
// Any force denies, dry-run or not: `-nf` still carries the force flag.

const { scanOptions, hasLong } = require("./options");

const CLEAN_SPEC = Object.freeze({
  shortWithValue: new Set(["e"]),
  longWithValue: new Set(["exclude"]),
  longNames: ["force", "dry-run", "quiet", "exclude", "interactive"],
});

/** @param {string[]} args the argv after `clean` @returns {string|null} */
function judgeClean(args) {
  const scan = scanOptions(args, CLEAN_SPEC);
  return scan.shortFlags.has("f") || hasLong(scan, "force") ? "clean-force" : null;
}

module.exports = { judgeClean };
