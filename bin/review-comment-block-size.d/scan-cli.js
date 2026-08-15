#!/usr/bin/env node
// bin/review-comment-block-size.d/scan-cli.js
// stdin/stdout adapter between the bash CLI and hooks/lib/comment-block-scan.js.
// Usage:  node scan-cli.js --threshold <N>  < <blob-or-file>
// Stdout: one "<start> <end> <len>" line per over-threshold run (shape scan_tally() expects).
// Exit: 0 = scanned, 2 = usage error. 1 is reserved for the CLI-layer blocking
// verdict — never return it here, or a bash caller reads it as "scanner failed".
"use strict";

const fs = require("fs");
const path = require("path");
const { scanText } = require(path.join(__dirname, "..", "..", "hooks", "lib", "comment-block-scan.js"));

function usage(msg) {
  process.stderr.write("scan-cli: " + msg + "\n");
  process.exit(2);
}

function parseArgs(argv) {
  let threshold = null;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--threshold") {
      threshold = i + 1 < argv.length ? argv[i + 1] : "";
      i++;
    } else {
      usage("unrecognized argument: " + argv[i]);
    }
  }
  return threshold;
}

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(65536);
  while (true) {
    let n = 0;
    try {
      n = fs.readSync(0, buf, 0, buf.length);
    } catch (e) {
      if (e && (e.code === "EAGAIN" || e.code === "EINTR")) continue;
      if (e && e.code === "EOF") break;
      throw e;
    }
    if (n === 0) break;
    chunks.push(Buffer.from(buf.slice(0, n)));
  }
  return Buffer.concat(chunks).toString("utf8");
}

function main(argv) {
  const raw = parseArgs(argv);
  if (raw === null) usage("missing --threshold");
  if (!/^[0-9]+$/.test(raw) || Number(raw) <= 0) usage("invalid --threshold: " + raw);
  const threshold = Number(raw);

  let text = "";
  try {
    text = readStdin();
  } catch (e) {
    process.stderr.write("scan-cli: cannot read stdin\n");
    process.exit(3);
  }

  const result = scanText(text, threshold);
  let out = "";
  for (const r of result.runs) out += r.start + " " + r.end + " " + r.len + "\n";
  // No explicit process.exit(0): let Node drain stdout before the natural exit.
  if (out.length > 0) process.stdout.write(out);
}

if (require.main === module) {
  main(process.argv.slice(2));
}

module.exports = { main };
