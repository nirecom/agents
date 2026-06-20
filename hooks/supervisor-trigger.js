#!/usr/bin/env node
// PostToolUse hook (Bash matcher): EM Supervisor Layer 2 finding-presence gate.
// - If command is a C2 escape-hatch (ENFORCE_*_OFF sentinel) and l2_armed_at
//   is not already set, set l2_armed_at = now (trigger L2 review at Stop).
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
  let ENFORCE_WORKFLOW_OFF_RE_DQ, ENFORCE_WORKFLOW_OFF_LOOKSLIKE_RE;
  let ENFORCE_WORKTREE_OFF_RE_DQ, ENFORCE_WORKTREE_OFF_LOOKSLIKE_RE;
  try {
    ({ resolveSessionId } = require("./lib/workflow-state"));
    ({ isWorkflowOff } = require("./lib/session-markers"));
    ({ readState, writeLayer2State } = require("./lib/supervisor-state-writer"));
    ({
      ENFORCE_WORKFLOW_OFF_RE_DQ,
      ENFORCE_WORKFLOW_OFF_LOOKSLIKE_RE,
      ENFORCE_WORKTREE_OFF_RE_DQ,
      ENFORCE_WORKTREE_OFF_LOOKSLIKE_RE,
    } = require("./lib/sentinel-patterns"));
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

  const command = (input.tool_input && input.tool_input.command) || "";
  const isEscapeHatch =
    ENFORCE_WORKFLOW_OFF_RE_DQ.test(command) ||
    ENFORCE_WORKFLOW_OFF_LOOKSLIKE_RE.test(command) ||
    ENFORCE_WORKTREE_OFF_RE_DQ.test(command) ||
    ENFORCE_WORKTREE_OFF_LOOKSLIKE_RE.test(command);

  const layer2 = (state && state.layer2) || {};
  const l2ArmedAt = layer2.l2_armed_at == null ? null : layer2.l2_armed_at;
  const cumSev = layer2.cumulative_severity == null ? null : layer2.cumulative_severity;
  const findings = Array.isArray(layer2.findings) ? layer2.findings : [];
  const findingCount = findings.length;

  const layer1Findings = (state && state.layer1 && Array.isArray(state.layer1.findings)) ? state.layer1.findings : [];
  const hasBlockingFinding = layer1Findings.some(f => f && f.severity && f.severity !== "notice");

  if (isEscapeHatch && !l2ArmedAt && hasBlockingFinding) {
    try {
      writeLayer2State(sessionId, { l2_armed_at: new Date().toISOString() });
    } catch (_) {}
  }

  let advisory = null;
  if (cumSev === "error") {
    advisory = `[EM Supervisor] Layer 2 has flagged a blocking concern (${findingCount} finding(s)). Review the next Stop turn — supervisor-guard.js will block.`;
  } else if (cumSev === "warning" || cumSev === "notice") {
    advisory = `[EM Supervisor] Layer 2 advisory (${cumSev}): ${findingCount} finding(s) recorded. See agents/supervisor.md for context.`;
  }

  done(advisory);
}
