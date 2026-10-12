#!/usr/bin/env node
"use strict";
// bin/shell-snapshot-path-classify.js — classify shell snapshot files by their PATH line (#2221).
// Usage: shell-snapshot-path-classify.js -- <file>...
// Prints one `<verdict>\t<file>` line per argument, in order; a file that cannot be read
// (missing, a directory, no permission) is `unreadable`. Read-only: never rewrites a file.
// Exit: 0 after classifying, 2 on an argument error (no output). Used once per sweep run.

const fs = require("fs");
const path = require("path");
const { classifySnapshotText } = require(path.join(__dirname, "..", "hooks", "lib", "shell-snapshot-path"));

function main(argv) {
  if (argv[0] !== "--") {
    process.stderr.write("usage: shell-snapshot-path-classify.js -- <file>...\n");
    return 2;
  }
  const out = [];
  for (const f of argv.slice(1)) {
    let verdict;
    try { verdict = classifySnapshotText(fs.readFileSync(f, "utf8")); } catch (_) { verdict = "unreadable"; }
    out.push(`${verdict}\t${f}\n`);
  }
  process.stdout.write(out.join(""));
  return 0;
}

process.exitCode = main(process.argv.slice(2));
