"use strict";
// Prints the workflow VALID_STEPS, one per line, so bin/review-loop-upstream can
// order B return steps without a second copy of the step list (CPR-SSOT).
// Exit 1 when the list cannot be read; the caller fails closed on any nonzero rc.

const path = require("path");

try {
  const stateIo = require(path.join(__dirname, "..", "..", "..", "hooks", "workflow-state", "state-io.js"));
  const steps = stateIo.VALID_STEPS;
  if (!Array.isArray(steps) || steps.length === 0) {
    process.stderr.write("step-order: VALID_STEPS is empty\n");
    process.exit(1);
  }
  process.stdout.write(`${steps.join("\n")}\n`);
} catch (err) {
  process.stderr.write(`step-order: ${err && err.message ? err.message : String(err)}\n`);
  process.exit(1);
}
