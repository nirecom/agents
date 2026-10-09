"use strict";
// tests/feature-1673-issue-close-stage-lib/checkfield-probe.js
//
// Drives bin/worker-dispatch/capability.js `checkField` for one (type, value)
// pair and prints a single verdict token:
//
//   ok            accepted
//   reject        rejected by the type's own rule
//   unknown-type  the capability type is not implemented (kept distinct from
//                 `reject` on purpose: an unimplemented type would otherwise
//                 make every negative row of the table pass for the wrong
//                 reason — a false green)
//
// Usage: node checkfield-probe.js <capability.js> <type> [value]
//
// Value placeholders resolved here so the shell table stays path-free:
//   @SCR@         the resolved agents root (capability.js's own repo root)
//   @SCR_PARENT@  its parent directory
//   @NUMBER@      the number 42 (non-string probe)

const path = require("path");

const capPath = path.resolve(process.argv[2]);
const type = process.argv[3];
const raw = process.argv.length > 4 ? process.argv[4] : "";

const cap = require(capPath);
const scriptCheckoutRoot = path.resolve(path.dirname(capPath), "..", "..");

let value = raw;
if (raw === "@SCR@") value = scriptCheckoutRoot;
else if (raw === "@SCR_PARENT@") value = path.dirname(scriptCheckoutRoot);
else if (raw === "@NUMBER@") value = 42;
else if (raw.startsWith("@SCR@")) value = scriptCheckoutRoot + raw.slice("@SCR@".length);

const anchors = {
  scriptCheckoutRoot,
  targetMainRoot: scriptCheckoutRoot,
  family: [scriptCheckoutRoot],
  plansDir: path.join(scriptCheckoutRoot, ".plans-probe"),
};

let res;
try {
  res = cap.checkField(value, { type }, anchors, {});
} catch (e) {
  process.stdout.write("threw:" + (e && e.message ? e.message : "unknown"));
  process.exit(0);
}

if (res && res.error) {
  process.stdout.write(/unknown capability type/.test(res.error) ? "unknown-type" : "reject");
} else {
  process.stdout.write("ok");
}
