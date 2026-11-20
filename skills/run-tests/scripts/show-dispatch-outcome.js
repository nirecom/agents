"use strict";
// show-dispatch-outcome.js --session <sid> — read-only display of the test-runner dispatch
// outcomes (#2544, WD-BG): one block per unconsumed dispatch in dispatch order (#3063), else the
// latest one. A block is three header lines and `---`; only a trusted outcome is followed by the
// YAML a foreground dispatch prints. An unscannable control dir prints one OUTCOME=scan-failed block.
// run_tests state is never shown: this call's own PostToolUse ingests the outcome.

const path = require("path");

const ROOT = path.join(__dirname, "..", "..", "..");
const { latestDispatch, listUnconsumed } = require(path.join(ROOT, "hooks", "workflow-state", "dispatch-settlement"));
const { readTrustedOutcome, SCAN_FAILED_STEM } = require(path.join(ROOT, "hooks", "workflow-run-tests", "dispatch-outcome"));
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
  const u = listUnconsumed({ sessionId: sid, worker: WORKER });
  if (u.reason) {
    header(SCAN_FAILED_STEM, "scan-failed", u.reason.replace(/[\r\n]+/g, " "));
    return 0;
  }
  if (u.stems.length > 0) {
    for (const d of u.stems) showStem(sid, d.stem);
    return 0;
  }
  const latest = latestDispatch({ sessionId: sid, worker: WORKER });
  if (latest === null) {
    header("none", "absent", "no-dispatch");
    return 0;
  }
  showStem(sid, latest.stem);
  return 0;
}

// One block: the header, then the YAML a foreground dispatch prints when the outcome is trusted.
function showStem(sid, stem) {
  const trusted = readTrustedOutcome({ sessionId: sid, stem });
  if (trusted.outcome === null) {
    header(stem, trusted.reason === "absent" ? "absent" : "untrusted", trusted.reason || "unknown");
    return;
  }
  header(stem, "present", "-");
  emit.write(workers[WORKER], emit.resultFromOutcome(trusted.outcome));
}

process.exitCode = main(process.argv.slice(2));
