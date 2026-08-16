#!/usr/bin/env node
// Claude Code UserPromptSubmit hook: surface a stalled workflow mechanism at the
// next user turn (#1979).
//
// A session once sat idle overnight waiting for a notification that never came:
// write_tests stayed in_progress, every quiet layer kept honouring it, and
// nothing ever told the user. The next prompt is the earliest moment a human is
// present to hear about it. Fail-open: every error path exits 0.
"use strict";

const fs = require("fs");
const { detectStalledSteps, reportMechanismFailureOnce } = require("./lib/mechanism-failure");

const SID_RE = /^[A-Za-z0-9_-]+$/;

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(4096);
  try {
    while (true) {
      const n = fs.readSync(0, buf, 0, buf.length);
      if (n === 0) break;
      chunks.push(buf.slice(0, n));
    }
  } catch (_e) {}
  return Buffer.concat(chunks).toString("utf8");
}

// `state-absent` is the commonest shape this hook sees — most prompts are typed
// in sessions that never ran /workflow-init — so it is normal, not a failure.
// Reporting it would also write a ledger that suppresses the session's FIRST
// genuine stall, reintroducing #1979 through the code meant to close it.
function reportableFindings(sid) {
  const findings = detectStalledSteps(sid) || [];
  return findings.filter((f) => f && f.kind !== "state-absent");
}

function describe(findings) {
  const items = findings.map((f) => "'" + f.step + "' (" + f.kind + ")").join(", ");
  return (
    "mechanism-failure: the workflow mechanism has stalled — " + items + ". " +
    "Nothing settled the step, so every quiet layer kept honouring it. " +
    "Check whether the delegated work actually finished, then settle the step " +
    "with next-step --advance (or reset it) before continuing."
  );
}

function main() {
  let input = null;
  try { input = JSON.parse(readStdin()); } catch (_e) { input = null; }

  let sid = input && typeof input.session_id === "string" ? input.session_id : null;
  if (!sid) {
    try { sid = require("./workflow-state").resolveSessionId() || null; } catch (_e) { sid = null; }
  }
  if (!sid || !SID_RE.test(sid)) return {};

  const findings = reportableFindings(sid);
  if (findings.length === 0) return {};

  for (const finding of findings) {
    try { reportMechanismFailureOnce(sid, finding); } catch (_e) {}
  }

  const message = describe(findings);
  return {
    blocks: true,
    systemMessage: message,
    hookSpecificOutput: {
      hookEventName: "UserPromptSubmit",
      additionalContext: message,
    },
  };
}

if (require.main === module) {
  let out = {};
  try { out = main() || {}; } catch (_e) { out = {}; }
  try { process.stdout.write(JSON.stringify(out)); } catch (_e) {}
  process.exit(0);
}

module.exports = { reportableFindings, describe };
