#!/usr/bin/env node
"use strict";
// Stop hook: surface Layer 2 supervisor findings after session completion
// when SC-7 did not run (or when the hook fires before session-close).
// Fires only when findings_surfaced_at is null and L2 has completed (or is
// in the #961 stale-pending state). Emits additionalContext only — never blocks.

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

  let resolveSessionId, resolveWorkflowSessionId, readState, writeLayer2State, getStatePath;
  let formatLayer2Findings;
  const SESSION_ID_RE = /^[A-Za-z0-9_-]+$/;

  try {
    ({ resolveSessionId } = require("./lib/workflow-state"));
    ({ resolveWorkflowSessionId } = require("./lib/resolve-workflow-session-id"));
    ({ readState, writeLayer2State, getStatePath } = require("./lib/supervisor-state-writer"));
    ({ formatLayer2Findings } = require("./lib/supervisor-findings-render"));
  } catch (_) {
    process.exit(0);
  }

  try {
    let sessionId = null;
    try {
      sessionId = resolveSessionId({
        sessionIdFromInput: input.session_id,
        transcriptPath: input.transcript_path,
      });
    } catch (_) {}
    if (!sessionId || !SESSION_ID_RE.test(sessionId)) process.exit(0);

    // Dual-ID effective-state lookup (mirrors supervisor-guard.js pattern)
    let workflowSessionId = null;
    const envWsid = process.env.WORKFLOW_SESSION_ID;
    if (envWsid && SESSION_ID_RE.test(envWsid)) {
      workflowSessionId = envWsid;
    } else {
      try {
        workflowSessionId = resolveWorkflowSessionId({});
      } catch (_) {}
    }

    let effectiveSid = sessionId;
    try {
      if (
        workflowSessionId &&
        workflowSessionId !== sessionId &&
        SESSION_ID_RE.test(workflowSessionId)
      ) {
        const primaryState = readState(sessionId);
        if (primaryState === null) {
          const fallbackState = readState(workflowSessionId);
          if (fallbackState !== null) {
            effectiveSid = workflowSessionId;
          }
        }
      }
    } catch (_) {}

    const state = readState(effectiveSid);
    if (!state) process.exit(0);

    const l2 = state.layer2;
    if (!l2 || !Array.isArray(l2.findings) || l2.findings.length === 0) process.exit(0);

    // Gate 1: not yet surfaced
    if (l2.findings_surfaced_at != null) process.exit(0);

    // Gate 2: L2 has completed or is in #961 stale-pending state
    const phase = l2.l2_phase;
    const isCompleted =
      phase === "done" ||
      phase === "frozen" ||
      (phase === "pending" && l2.last_run_at != null);
    if (!isCompleted) process.exit(0);

    // Gate 3: renderer has content
    const agentsConfigDir = process.env.AGENTS_CONFIG_DIR || "";
    const supervisorPath = agentsConfigDir ? `${agentsConfigDir}/agents/supervisor.md` : "agents/supervisor.md";
    const stateFilePath = getStatePath(effectiveSid);

    const rendered = formatLayer2Findings(l2.findings, {
      sessionId,
      workflowSessionId,
      supervisorPath,
      stateFilePath,
    });
    if (!rendered) process.exit(0);

    // Emit first so stdout delivery is proven before marking state
    process.stdout.write(JSON.stringify({ additionalContext: rendered }) + "\n");

    // Mark surfaced (best effort — fail-open; hook may re-surface on next Stop if write fails)
    try {
      const ok = writeLayer2State(effectiveSid, { findings_surfaced_at: new Date().toISOString() });
      void ok; // fail-open: acceptable if state write fails
    } catch (_) {}

    process.exit(0);
  } catch (_) {
    // Fail-open: never block on own errors
    process.exit(0);
  }
}
