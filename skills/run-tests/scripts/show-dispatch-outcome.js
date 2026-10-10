"use strict";
// show-dispatch-outcome.js --session <sid> — read-only display of the latest
// test-runner dispatch outcome (#2544, WD-BG). Prints three header lines and `---`;
// only a trusted outcome is followed by the YAML a foreground dispatch prints.
// run_tests state is never shown: this call's own PostToolUse ingests the outcome.

const path = require("path");

const ROOT = path.join(__dirname, "..", "..", "..");
const { latestDispatch } = require(path.join(ROOT, "hooks", "workflow-state", "dispatch-settlement"));
const { readTrustedOutcome } = require(path.join(ROOT, "hooks", "workflow-run-tests", "dispatch-outcome"));
const { workers } = require(path.join(ROOT, "hooks", "lib", "worker-dispatch-registry"));
const emit = require(path.join(ROOT, "bin", "worker-dispatch", "emit"));

const RE_SESSION_ID = /^[A-Za-z0-9_-]+$/;
const WORKER = "test-runner";

function sessionArg(argv) {
  const i = argv.indexOf("--session");
  return i >= 0 && i + 1 < argv.length ? argv[i + 1] : null;
}

function header(stem, state, reason) {
  process.stdout.write(`DISPATCH_STEM=${stem}\nOUTCOME=${state}\nOUTCOME_REASON=${reason}\n---\n`);
}

function main(argv) {
  const sid = sessionArg(argv);
  if (typeof sid !== "string" || !RE_SESSION_ID.test(sid)) {
    process.stderr.write("usage: show-dispatch-outcome.sh --session <sid>\n");
    return 2;
  }
  const latest = latestDispatch({ sessionId: sid, worker: WORKER });
  if (latest === null) {
    header("none", "absent", "no-dispatch");
    return 0;
  }
  const trusted = readTrustedOutcome({ sessionId: sid, stem: latest.stem });
  if (trusted.outcome === null) {
    header(latest.stem, trusted.reason === "absent" ? "absent" : "untrusted", trusted.reason || "unknown");
    return 0;
  }
  header(latest.stem, "present", "-");
  emit.write(workers[WORKER], emit.resultFromOutcome(trusted.outcome));
  return 0;
}

process.exitCode = main(process.argv.slice(2));
