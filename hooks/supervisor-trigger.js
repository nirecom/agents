#!/usr/bin/env node
// PostToolUse hook (Bash matcher): EM Supervisor Layer 2 wakeup writer.
// - If last_run_at is null OR > 5 min ago, AND next_check_at is not set,
//   set next_check_at = now.
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

  let resolveSessionId, isWorkflowOff, readState, writeLayer2State;
  try {
    ({ resolveSessionId } = require("./lib/workflow-state"));
    ({ isWorkflowOff } = require("./lib/session-markers"));
    ({ readState, writeLayer2State } = require("./lib/supervisor-state-writer"));
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

  const layer2 = (state && state.layer2) || {};
  const last = layer2.last_run_at == null ? null : layer2.last_run_at;
  const fiveMinMs = 5 * 60 * 1000;
  let elapsed = Infinity;
  if (last) {
    const parsed = Date.parse(last);
    if (!Number.isNaN(parsed)) elapsed = Date.now() - parsed;
  }
  const nextCheck = layer2.next_check_at == null ? null : layer2.next_check_at;

  if (elapsed > fiveMinMs && !nextCheck) {
    try {
      writeLayer2State(sessionId, { next_check_at: new Date().toISOString() });
    } catch (_) {}
  }

  // Re-read to reflect any timer-branch write
  let state2 = null;
  try {
    state2 = readState(sessionId);
  } catch (_) {
    state2 = null;
  }
  const l2 = (state2 && state2.layer2) || {};
  const cumSev = l2.cumulative_severity == null ? null : l2.cumulative_severity;
  const findings = Array.isArray(l2.findings) ? l2.findings : [];
  const findingCount = findings.length;

  let advisory = null;
  if (cumSev === "error") {
    advisory = `[EM Supervisor] Layer 2 has flagged a blocking concern (${findingCount} finding(s)). Review the next Stop turn — supervisor-guard.js will block.`;
  } else if (cumSev === "warning" || cumSev === "notice") {
    advisory = `[EM Supervisor] Layer 2 advisory (${cumSev}): ${findingCount} finding(s) recorded. See agents/supervisor.md for context.`;
  }

  done(advisory);
}
