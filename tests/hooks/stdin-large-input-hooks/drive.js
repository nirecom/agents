"use strict";
// spawnSync pipe route: feeds <inFile> to `node <script> [args...]` through a
// Node-created stdin pipe and records stdout / stderr / exit status as files
// (<outPrefix>.out, .err, .rc) for the bash side to assert on.
// Usage: node drive.js <inFile> <outPrefix> <script> [args...]
const fs = require("fs");
const { spawnSync } = require("child_process");

const [inFile, outPrefix, script, ...args] = process.argv.slice(2);
const r = spawnSync(process.execPath, [script, ...args], {
  input: fs.readFileSync(inFile),
  env: process.env,
  maxBuffer: 64 * 1024 * 1024,
  timeout: 60000,
});
fs.writeFileSync(outPrefix + ".out", r.stdout || "");
fs.writeFileSync(outPrefix + ".err", (r.stderr || "") + (r.error ? `drive.js: ${r.error.message}\n` : ""));
fs.writeFileSync(outPrefix + ".rc", String(r.status === null ? 124 : r.status));
