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
// approval is the real gate. Fail-open: every error path approves.
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
      // Copy: `buf` is reused every iteration, so a slice/subarray VIEW would be
      // overwritten in place by the next read and corrupt the assembled payload.
      chunks.push(Buffer.from(buf.subarray(0, n)));
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
