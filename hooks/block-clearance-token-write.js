#!/usr/bin/env node
// PreToolUse hook: block direct writes to — and deletions of — any CLEARANCE TOKEN
// (`<workflowDir>/<sid>.off-clearance`, minted only by bin/request-off-clearance)
// and the session-override MARKERS that hooks/lib/session-markers.js honours purely
// on existence. DELETE is guarded as strictly as overwrite; both re-arm the bypass.
//
// This is the PRIMARY gate (marker integrity is location-independent, so
// enforce-worktree's location guard cannot carry it); marker-gate.js is defence in
// depth, and both read one SSOT, hooks/lib/protected-basenames.js. Best-effort
// deterrent only — dynamic path construction is undetectable, and Phase2 human
// approval is the real gate. Fail-open on every error path except unreadable stdin.
"use strict";

const fs = require("fs");
const { evaluateProtectedWrite, TOKEN_BLOCK_MSG, MARKER_BLOCK_MSG, collectEditWritePaths } = require("./block-clearance-token-write/dispatch");
const { bashHitsProtected } = require("./block-clearance-token-write/bash-scan");
const { classifyProtectedPath, hitsProtectedPath } = require("./lib/protected-basenames");
const { readHookInput, readFailureReason, readFailOpenDiagnostic } = require("./lib/read-stdin");

const HOOK_NAME = "block-clearance-token-write";

function approve() { console.log(JSON.stringify({ decision: "approve" })); process.exit(0); }
function block(reason) { console.log(JSON.stringify({ decision: "block", reason })); process.exit(0); }

if (require.main === module) {
  const r = readHookInput();
  if (r.kind === "read-error") block(readFailureReason(HOOK_NAME, r.error));
  if (r.kind !== "ok") {
    try { fs.writeSync(2, readFailOpenDiagnostic(HOOK_NAME, r, "check skipped") + "\n"); } catch (_) {}
    approve();
  }
  const input = r.input;
  if (!input || typeof input !== "object") approve();

  let verdict = null;
  try {
    // 3rd arg (#2108): the stdin session identity a protected stem is tested against.
    verdict = evaluateProtectedWrite(input.tool_name, input.tool_input || {}, {
      sessionId: input.session_id,
      transcriptPath: input.transcript_path,
    });
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
