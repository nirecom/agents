#!/usr/bin/env node
"use strict";
// PostToolUse hook: record the dispatching workflow step `in_progress` (#2013).
//
// WHY: a delegated step hands the turn to a subagent for minutes. Without a
// record, the C4 premature-stop guard reads ACTION=invoke and nudges the user
// mid-dispatch. Marking the step removes the need for a manual NEXT_STEP_PAUSE.
//
// FAIL-SAFE: a PostToolUse throw breaks the user's tool call, so every path
// exits 0 with no stdout. Nothing here ever repairs or overwrites state.

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

// A dispatch made from INSIDE a subagent must not mark the parent's step: the
// C4 guard runs on the main conversation only. Any non-empty agent_id, of any
// type, counts as "this is a child turn".
function isSubagentTurn(input) {
  const id = input.agent_id;
  if (id === undefined || id === null) return false;
  return String(id).length > 0;
}

function main() {
  let input;
  try {
    const raw = readStdin();
    if (!raw || !raw.trim()) return;
    input = JSON.parse(raw);
  } catch (_) {
    return;
  }
  if (!input || typeof input !== "object" || Array.isArray(input)) return;
  if (typeof input.session_id !== "string" || !input.session_id) return;
  if (isSubagentTurn(input)) return;

  const policy = require("./lib/step-in-flight-policy");
  if (!policy.isDispatchTool(input.tool_name)) return;

  const { resolveSessionId, getStatePath, readState, markStep } = require("./workflow-state");
  const { resolveCurrentEffectiveStep } = require("./workflow-state/current-step");

  let sid = null;
  try {
    sid = resolveSessionId({
      sessionIdFromInput: input.session_id,
      transcriptPath: typeof input.transcript_path === "string" ? input.transcript_path : "",
    });
  } catch (_) {}
  if (!sid) return;

  // Corrupt state is left strictly alone — the mechanism-failure reporter needs
  // that evidence, and "no state file yet" is a different situation entirely.
  const statePath = getStatePath(sid);
  const hasStateFile = fs.existsSync(statePath);
  if (hasStateFile && !readState(sid)) return;

  // WI-10 lookahead: during /workflow-init the first Agent dispatch happens
  // before (or at) workflow_init, so the step that owns the dispatch is the one
  // that comes next — `research`. Bounded to exactly that window (CPR-UNV).
  let step = hasStateFile ? resolveCurrentEffectiveStep(sid) : null;
  if (step === null || step === "workflow_init") step = "research";
  if (!policy.isStepInFlightCandidate(step)) return;

  // Idempotent: repeat dispatches during one delegated step append no events.
  const state = hasStateFile ? readState(sid) : null;
  const entry = state && state.steps && state.steps[step];
  if (entry && entry.status === "in_progress") return;

  markStep(sid, step, "in_progress", {}, {
    provenance: "observed",
    origin: "postuse-in-flight",
  });
}

if (require.main === module) {
  try {
    main();
  } catch (_) {
    /* fail-safe: never break the user's tool call */
  }
  process.exit(0);
}

module.exports = { isSubagentTurn };
