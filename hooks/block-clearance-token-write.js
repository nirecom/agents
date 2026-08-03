#!/usr/bin/env node
// PreToolUse hook: block direct writes to — and deletions of — any CLEARANCE TOKEN
// (<workflowDir>/<sid>.off-clearance, minted only by bin/request-off-clearance after a
// Phase1 examination, #1608) and the session-override MARKERS (<sid>.workflow-off /
// .worktree-off / .issue-close-verified / .next-step-paused / .off-emergency-invoked),
// which hooks/lib/session-markers.js honours purely on existence (#1780 H-1/H-2).
// DELETE is guarded as strictly as overwrite — removing either re-arms the bypass.
//
// WHY THE MARKER GATE LIVES HERE (#1780 H-1/H-2): marker integrity is a
// LOCATION-INDEPENDENT property. hooks/enforce-worktree.js is a worktree-location
// guard whose tail allows every write from a linked worktree on a feature branch
// — the normal working mode — so its marker gate
// (hooks/enforce-worktree/bash-write-scope/marker-gate.js) is inert exactly where
// the work happens, and it never runs for Edit/Write at all when the target sits
// outside a git repo (the workflow dir does). This hook is registered for
// Edit|Write|MultiEdit|editFiles|Bash|runInTerminal|runCommands and blocks
// regardless of worktree, so it is the primary gate; marker-gate.js is kept as
// defence in depth. Both read one protected-basename SSOT,
// hooks/lib/protected-basenames.js (CPR-2), whose OFF_CLEARANCE_TOKEN_SUFFIXES
// array is the class-based extension point (CPR-4) for future clearance tokens.
//
// TRUST MODEL (accepted limitation): this is a BEST-EFFORT deterrent, not a hard
// gate. Dynamic path construction (variable concatenation, base64, an alternate
// interpreter) and edits to the examiner / codex / this hook itself are NOT
// detectable here. The real gate is Phase2 human approval (settings.json `ask`,
// which the model cannot self-approve) plus the audit trail.
// READ side (#1709): the only sanctioned way to read a token is a plain shell
// read (cat / Get-Content / ls); interpreter bodies are blocked by default and
// pass only when they match one of the anchored read-only shapes.
//
// Fail-open: every error path approves rather than blocking.
//
// Dispatch + re-export only — analysis lives in ./block-clearance-token-write/
// (file-split, rules/coding/file-split.md: the entrypoint exceeded the 500-line
// HARD limit once the marker gate was added).
"use strict";

const fs = require("fs");
const { evaluateProtectedWrite, TOKEN_BLOCK_MSG, MARKER_BLOCK_MSG, collectEditWritePaths } = require("./block-clearance-token-write/dispatch");
const { bashHitsProtected } = require("./block-clearance-token-write/bash-scan");
const { classifyProtectedPath, hitsProtectedPath } = require("./lib/protected-basenames");

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

function approve() { console.log(JSON.stringify({ decision: "approve" })); process.exit(0); }
function block(reason) { console.log(JSON.stringify({ decision: "block", reason })); process.exit(0); }

if (require.main === module) {
  let input;
  try {
    input = JSON.parse(readStdin());
  } catch (_e) {
    approve();
  }
  if (!input || typeof input !== "object") approve();

  let verdict = null;
  try {
    verdict = evaluateProtectedWrite(input.tool_name, input.tool_input || {});
  } catch (_e) {
    approve(); // fail-open
  }

  if (!verdict) approve();
  block(verdict.reason);
}

module.exports = {
  TOKEN_BLOCK_MSG,
  MARKER_BLOCK_MSG,
  collectEditWritePaths,
  evaluateProtectedWrite,
  bashHitsProtected,
  classifyProtectedPath,
  hitsProtectedPath,
};
