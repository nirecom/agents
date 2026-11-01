"use strict";
// Test-only preload for tests/hooks/feature-2461-continue-on-stop.js (#2461): loaded with
// NODE_OPTIONS `--require <this file>`, it replaces only the bin/workflow/next-step process
// (every other node process runs unchanged) by the $FAKE_NEXT_STEP mode: exit:<rc> (no output),
// empty (exit 0, no output), hang:<ms> (sleeps past the caller's timeout), or stdout:<text>.
// Holds no cases of its own; an unset FAKE_NEXT_STEP leaves the process untouched.

const MODE = process.env.FAKE_NEXT_STEP || "";
const script = String(process.argv[1] || "").replace(/\\/g, "/");
if (MODE && script.endsWith("bin/workflow/next-step")) {
  const [kind, ...rest] = MODE.split(":");
  const arg = rest.join(":");
  if (kind === "exit") process.exit(Number(arg) || 1);
  if (kind === "empty") process.exit(0);
  if (kind === "hang") {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, Number(arg) || 8000);
    process.exit(0);
  }
  if (kind === "stdout") {
    require("fs").writeSync(1, arg.replace(/\\n/g, "\n"));
    process.exit(0);
  }
}
