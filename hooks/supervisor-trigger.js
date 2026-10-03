#!/usr/bin/env node
// PostToolUse hook (Bash matcher): EM Supervisor alert mode finding-presence gate.
// - If command is a scheduled-review escape-hatch (ENFORCE_*_OFF sentinel) and alert_armed_at
//   is not already set, set alert_armed_at = now (trigger alert review at Stop).
// - Emit an additionalContext advisory when cumulative_severity is set.
// - Fail-open everywhere; never exit 2 (PostToolUse must not block).
"use strict";

const fs = require("fs");
// #2256 S5-a2: command-tool detection is centralized so runInTerminal/runCommands
// reach this advisory identically to Bash (SSOT: hooks/lib/tool-command-text.js).
const { isCommandTool } = require("./lib/tool-command-text");

const { readHookInput, readFailOpenDiagnostic } = require("./lib/read-stdin");

function done(additionalContext) {
  if (additionalContext) {
    process.stdout.write(JSON.stringify({ additionalContext }) + "\n");
  }
  process.exit(0);
}

if (require.main === module) {
  const r = readHookInput();
  if (r.kind !== "ok") {
    try {
      fs.writeSync(2, readFailOpenDiagnostic("supervisor-trigger", r, "supervisor trigger skipped") + "\n");
    } catch (_) {}
    done();
  }
  const input = r.input;

  if (!isCommandTool(input.tool_name)) done();

  let resolveSessionId, isWorkflowOff, readState;
  try {
    ({ resolveSessionId } = require("./workflow-state"));
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

  // Quiet layer (#1607): suppress the advisory while paused. done() emits no
  // additionalContext and writes no state — non-consuming. fail-open.
  try {
    const { isNextStepPaused } = require("./lib/session-markers");
    if (isNextStepPaused(sessionId)) done();
  } catch (_) { /* fail-open */ }

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
