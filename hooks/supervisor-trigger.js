#!/usr/bin/env node
// PostToolUse hook (Bash matcher): EM Supervisor alert mode finding-presence gate.
// - If command is a C2 escape-hatch (ENFORCE_*_OFF sentinel) and alert_armed_at
//   is not already set, set alert_armed_at = now (trigger alert review at Stop).
// - Emit an additionalContext advisory when cumulative_severity is set.
// - Fail-open everywhere; never exit 2 (PostToolUse must not block).
"use strict";

const fs = require("fs");

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(65536);
  try {
    while (true) {
      const n = fs.readSync(0, buf, 0, buf.length);
      if (n === 0) break;
      chunks.push(buf.slice(0, n));
    }
  } catch (_) {}
  return Buffer.concat(chunks).toString("utf8");
}

function done(additionalContext) {
  if (additionalContext) {
    process.stdout.write(JSON.stringify({ additionalContext }) + "\n");
  }
  process.exit(0);
}

if (require.main === module) {
  let input = {};
  try {
    const raw = readStdin();
    if (!raw) done();
    input = JSON.parse(raw);
  } catch (_) {
    done();
  }

  if (!input.tool_name || input.tool_name !== "Bash") done();

  let resolveSessionId, isWorkflowOff, readState;
  try {
    ({ resolveSessionId } = require("./lib/workflow-state"));
    ({ isWorkflowOff } = require("./lib/session-markers"));
    ({ readState } = require("./lib/supervisor-state-writer"));
  } catch (_) {
    done();
  }

  let sessionId = null;
  try {
    sessionId = resolveSessionId({
      sessionIdFromInput: input.session_id,
      transcriptPath: input.transcript_path,
    });
  } catch (_) {
    done();
  }
  if (!sessionId) done();

  try {
    if (isWorkflowOff(sessionId)) done();
  } catch (_) {
    done();
  }

  let state = null;
  try {
    state = readState(sessionId);
  } catch (_) {
    state = null;
  }

  const alert = (state && state.alert) || {};
  const cumSev = alert.cumulative_severity == null ? null : alert.cumulative_severity;
  const findings = Array.isArray(alert.findings) ? alert.findings : [];
  const findingCount = findings.length;

  let advisory = null;
  if (cumSev === "error") {
    advisory = `[EM Supervisor] Alert mode has flagged a blocking concern (${findingCount} finding(s)). Review the next Stop turn — supervisor-guard.js will block.`;
  }

  done(advisory);
}
