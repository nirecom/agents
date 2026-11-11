"use strict";
// Test-only preload for gh-scripted-stub.js: on Windows the stub gh is a copy of the node binary
// named gh.exe, and node takes the first gh argument (`api`, `issue`, ...) as its script path,
// resolved to an absolute path. This preload turns that copy into the stub before node loads the
// script. Inert in every other node process.
const path = require("path");

if (path.basename(process.execPath).replace(/\.exe$/i, "").toLowerCase() === "gh") {
  const first = process.argv[1] ? path.basename(process.argv[1]) : null;
  const args = (first === null ? [] : [first]).concat(process.argv.slice(2));
  require("./gh-scripted-stub").runStub(args);
}
