"use strict";
// `node -r` preload, loaded after spawn-stub.js: holds the dispatcher inside the
// worker's spawn seam — after the claim, before the outcome — until the test releases it.
//   WD_HOLD_ENTERED  file created on entry (the dispatcher has claimed and reached the worker)
//   WD_HOLD_RELEASE  file the test creates to let the stubbed run proceed
// The wait is capped at 60 s so a test that forgets the release never hangs; the
// test detects the cap through its own checks, never through this stub.
const fs = require("fs");

const mod = require(process.env.WD_SPAWN_MODULE);
const inner = mod.run;
const CAP_MS = 60 * 1000;
const STEP_MS = 50;

mod.run = function heldRun(entry, opts) {
  fs.writeFileSync(process.env.WD_HOLD_ENTERED, `${process.pid}\n`);
  const cell = new Int32Array(new SharedArrayBuffer(4));
  const until = Date.now() + CAP_MS;
  while (!fs.existsSync(process.env.WD_HOLD_RELEASE) && Date.now() < until) {
    Atomics.wait(cell, 0, 0, STEP_MS);
  }
  return inner.call(this, entry, opts);
};
