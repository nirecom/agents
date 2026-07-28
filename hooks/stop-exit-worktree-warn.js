#!/usr/bin/env node
// Stop hook (#1610): warn when a session used the EnterWorktree native tool but
// never called ExitWorktree before session stop, leaving the extension-host
// worktree binding unreleased.
//
// Advisory-only by design: this hook MUST NEVER block. A Stop-time block is an
// unrecoverable deadlock (the session cannot proceed to release the binding), so
// every branch fails open and this hook never emits a `decision` key.
//
// Positive-evidence only: it warns solely on positive entry evidence
// (EnterWorktree in the transcript or worktree_entered_at in state) and never on
// the mere absence of exit evidence. Consequently, if the upstream native tool
// name ever changes, `EnterWorktree` yields zero hits and this hook goes SILENT
// BY DESIGN — fail-open, no false-warning noise.
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

const ADVISORY =
  "[Workflow] EnterWorktree was used in this session but ExitWorktree was never called before session stop. Call the ExitWorktree tool to release the extension-host worktree binding — see skills/_shared/worktree-transition.md.";

if (require.main === module) {
  let input = {};
  try {
    const raw = readStdin();
    if (!raw) process.exit(0);
    input = JSON.parse(raw);
  } catch (_) {
    process.exit(0);
  }

  // TRANSCRIPT EVIDENCE — always attempted; a missing or unreadable transcript
  // is treated as "no evidence" and never throws.
  let transcriptEntered = false;
  let transcriptExited = false;
  const transcriptPath = input.transcript_path;
  if (transcriptPath) {
    let lines = [];
    try {
      lines = fs.readFileSync(transcriptPath, "utf8").split("\n");
    } catch (_) {
      lines = [];
    }
    let order = 0;
    let lastEnterIdx = -1;
    let lastExitIdx = -1;
    for (const line of lines) {
      if (!line.trim()) continue;
      let entry;
      try {
        entry = JSON.parse(line);
      } catch (_) {
        continue;
      }
      if (entry.type !== "assistant") continue;
      const content =
        entry.message && Array.isArray(entry.message.content)
          ? entry.message.content
          : [];
      for (const item of content) {
        if (!item || item.type !== "tool_use") continue;
        order++;
        if (item.name === "EnterWorktree") lastEnterIdx = order;
        if (item.name === "ExitWorktree") lastExitIdx = order;
      }
    }
    transcriptEntered = lastEnterIdx >= 0;
    transcriptExited = lastExitIdx >= 0 && lastExitIdx > lastEnterIdx;
  }

  // STATE EVIDENCE — read the workflow state file for durable entry/exit
  // timestamps. Any failure leaves both booleans false.
  let stateEntered = false;
  let stateExited = false;
  try {
    const { readState } = require("./workflow-state/state-io");
    const state = readState(input.session_id);
    if (state && typeof state === "object") {
      const enteredAt = state.worktree_entered_at;
      const exitedAt = state.worktree_exited_at;
      if (
        typeof enteredAt === "string" &&
        enteredAt.length > 0 &&
        !isNaN(new Date(enteredAt).getTime())
      ) {
        stateEntered = true;
      }
      if (
        typeof exitedAt === "string" &&
        exitedAt.length > 0 &&
        !isNaN(new Date(exitedAt).getTime())
      ) {
        stateExited = true;
      }
    }
  } catch (_) {}

  const enteredEvidence = stateEntered || transcriptEntered;
  const exitedEvidence = stateExited || transcriptExited;

  if (enteredEvidence && !exitedEvidence) {
    try {
      process.stdout.write(
        JSON.stringify({ additionalContext: ADVISORY }) + "\n"
      );
    } catch (_) {}
  }
  process.exit(0);
}
