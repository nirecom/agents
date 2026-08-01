#!/usr/bin/env node
// PostToolUse recorder (#1610): records native worktree entry/exit transitions
// so the Stop advisory hook has a positive-evidence source independent of the
// transcript. Fail-open in every branch; independent of hooks/workflow-mark.js.
//
// Since #1733 each transition is its own `worktree` event carrying the branch, the
// cwd, the worktree path, and `path_source` — HOW that path was determined. Two
// entries into the same worktree are now two distinguishable records instead of one
// overwritten timestamp, and worktree_entered_at / worktree_exited_at are derived
// from the stream by the projection rather than stored.
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
    const { readState, appendEvents, resolveWorktreeContext } = require("./workflow-state/state-io");
    const sid = input.session_id;
    if (!sid) process.exit(0);
    // No state file means no session to attach the transition to. Creating one here
    // would fabricate a session out of a worktree move.
    if (!readState(sid)) process.exit(0);

    const toolInput = input.tool_input && typeof input.tool_input === "object" ? input.tool_input : {};

    const transition = tool === "EnterWorktree" ? "entered" : "exited";
    const ctx = resolveWorktreeContext(toolInput.path);
    const base = {
      kind: "worktree",
      transition,
      git_branch: ctx.git_branch,
      cwd: ctx.cwd,
      provenance: "observed",
      origin: "worktree-postuse",
    };

    if (transition === "entered" || ctx.path_source === "tool_input") {
      appendEvents(sid, [
        Object.assign({}, base, { worktree_path: ctx.worktree_path, path_source: ctx.path_source }),
      ]);
    } else {
      // An exit with no usable path of its own: the hook process is not standing in
      // the worktree that was left, so the path recorded on the most recent entry is
      // the honest answer — and path_source says exactly that it was inherited.
      // Resolved inside the lock so a concurrent entry cannot be missed.
      appendEvents(sid, (events) => {
        let priorPath = null;
        for (let i = events.length - 1; i >= 0; i--) {
          const e = events[i];
          if (e && e.kind === "worktree" && e.transition === "entered") {
            priorPath = e.worktree_path === undefined ? null : e.worktree_path;
            break;
          }
        }
        return [Object.assign({}, base, { worktree_path: priorPath, path_source: "prior-entry" })];
      });
    }
  } catch (_) {}

  process.exit(0);
}
