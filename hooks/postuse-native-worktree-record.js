#!/usr/bin/env node
// PostToolUse recorder (#1610): records native worktree entry/exit transitions
// into workflow state (top-level keys worktree_entered_at / worktree_exited_at)
// so the Stop advisory hook has a positive-evidence source independent of the
// transcript. Fail-open in every branch; independent of hooks/workflow-mark.js.
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

if (require.main === module) {
  let input = {};
  try {
    const raw = readStdin();
    if (!raw) process.exit(0);
    input = JSON.parse(raw);
  } catch (_) {
    process.exit(0);
  }

  const tool = input.tool_name;
  if (tool !== "EnterWorktree" && tool !== "ExitWorktree") process.exit(0);

  try {
    const { readState, writeState } = require("./lib/workflow-state/state-io");
    const sid = input.session_id;
    if (!sid) process.exit(0);
    const state = readState(sid);
    if (!state) process.exit(0);
    const now = new Date().toISOString();
    if (tool === "EnterWorktree") {
      state.worktree_entered_at = now;
    } else {
      state.worktree_exited_at = now;
    }
    writeState(sid, state);
  } catch (_) {}

  process.exit(0);
}
