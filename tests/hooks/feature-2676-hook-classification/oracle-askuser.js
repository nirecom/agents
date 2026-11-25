"use strict";
// Probe driver for the pre-tool-use-askuser-jev oracle entry (oracle.js): this hook needs a mock Jev
// and a seeded workflow state, so it runs through the feature-2764 fixture instead of runProbe's
// plain spawn. context.ask is X.makeAsk(ROOT, mock) and context.mock the started mock Jev. A probe
// names a scene (name), the mock's confidences (conv) and extra env. The child-control preload logs
// every child process the hook starts to F2540_LOG (stderr carries them for diagnosis); the session
// id resolver starts `git rev-parse --show-toplevel`, so the log is not empty and is not asserted.

const fs = require("node:fs");
const path = require("node:path");
const F = require("../feature-2461-jev/fixture");
const { classify } = require("../feature-2676-merged-allow-deny/fixture");

const PRELOAD = F.fwd(path.join(__dirname, "child-control-preload.js"));

// runAskuserProbe(probe, context) -> { status, signal, stdout, stderr, got }, the runProbe contract.
function runAskuserProbe(probe, context) {
  const logFile = path.join(context.tempDir("au"), "calls.jsonl");
  if (probe.conv) context.mock.conv(...probe.conv);
  const extra = { F2540_LOG: F.fwd(logFile), NODE_OPTIONS: `--require "${PRELOAD}"`, ...(probe.extra || {}) };
  const { o } = context.ask(probe.name, { source: "run-tests.calibrate", extra });
  const calls = fs.existsSync(logFile) ? fs.readFileSync(logFile, "utf8").split("\n").filter(Boolean) : [];
  const stderr = `${o.stderr || ""} child processes: ${calls.join(" ")}`;
  // The fixture's outcome drops the signal; a child killed at its timeout has a null status.
  return { status: o.status, signal: o.status === null ? "killed (timeout)" : null, stdout: o.stdout || "", stderr, got: classify(o.stdout || "") };
}

module.exports = { runAskuserProbe };
