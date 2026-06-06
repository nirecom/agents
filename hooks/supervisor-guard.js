#!/usr/bin/env node
// Stop hook: EM Supervisor Layer 2 wakeup-injection + block-on-error.
// - cumulative_severity === 'error' -> decision:block, exit 2
// - next_check_at non-null -> additionalContext wakeup instruction
// - cumulative_severity in {warning, notice} -> additionalContext advisory
// - both -> single additionalContext combining both
// - all-null -> exit 0 silently
// - stop_hook_active === true -> exit 0 immediately
// - any error -> fail-open (exit 0 silently)
"use strict";

const fs = require("fs");
const path = require("path");

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

if (require.main === module) {
  let input = {};
  try {
    const raw = readStdin();
    if (!raw) process.exit(0);
    input = JSON.parse(raw);
  } catch (_) {
    process.exit(0);
  }

  if (input.stop_hook_active === true) process.exit(0);

  let resolveSessionId, isWorkflowOff, readState;
  try {
    ({ resolveSessionId } = require("./lib/workflow-state"));
    ({ isWorkflowOff } = require("./lib/session-markers"));
    ({ readState } = require("./lib/supervisor-state-writer"));
  } catch (_) {
    process.exit(0);
  }

  let sessionId = null;
  try {
    sessionId = resolveSessionId({
      sessionIdFromInput: input.session_id,
      transcriptPath: input.transcript_path,
    });
  } catch (_) {
    process.exit(0);
  }
  if (!sessionId) process.exit(0);

  try {
    if (isWorkflowOff(sessionId)) process.exit(0);
  } catch (_) {
    process.exit(0);
  }

  let state = null;
  try {
    state = readState(sessionId);
  } catch (_) {
    state = null;
  }
  if (!state) process.exit(0);

  const layer2 = state.layer2 || {};
  const nextCheck = layer2.next_check_at == null ? null : layer2.next_check_at;
  const cumSev = layer2.cumulative_severity == null ? null : layer2.cumulative_severity;
  const findings = Array.isArray(layer2.findings) ? layer2.findings : [];

  const agentsDir = process.env.AGENTS_CONFIG_DIR || "";
  const supervisorPath = agentsDir ? path.join(agentsDir, "agents", "supervisor.md") : "agents/supervisor.md";

  if (cumSev === "error") {
    const topDetail = findings.length > 0 ? findings[findings.length - 1].detail : "(no detail)";
    const reason = `[EM Supervisor] Layer 2 has determined cumulative_severity=error. Top finding: "${topDetail}". Follow agents/supervisor.md (${supervisorPath}) to resolve before continuing.`;
    try {
      process.stdout.write(JSON.stringify({ decision: "block", reason }) + "\n");
    } catch (_) {}
    process.exit(2);
  }

  const parts = [];

  if (nextCheck) {
    parts.push(
      `[EM Supervisor] Layer 2 check is due. Register a ScheduleWakeup for now+5s and on wakeup follow agents/supervisor.md (${supervisorPath}). Session ID: ${sessionId}.`
    );
  }

  if (cumSev === "warning" || cumSev === "notice") {
    parts.push(
      `[EM Supervisor] Layer 2 advisory (${cumSev}): ${findings.length} finding(s). Review agents/supervisor.md for the full checklist and resolution path.`
    );
  }

  if (parts.length > 0) {
    try {
      process.stdout.write(JSON.stringify({ additionalContext: parts.join("\n\n") }) + "\n");
    } catch (_) {}
  }
  process.exit(0);
}
