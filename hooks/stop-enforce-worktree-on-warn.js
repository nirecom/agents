#!/usr/bin/env node
// Stop hook (#372): emit additionalContext warning when WORKTREE_OFF was proposed
// during the session but the matching WORKTREE_ON sentinel was never Bash-emitted
// before session stop. Advisory only; never blocks.
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

  const transcriptPath = input.transcript_path;
  if (!transcriptPath) process.exit(0);

  let OFF_DQ, OFF_LL, ON_DQ, ON_LL;
  try {
    ({
      ENFORCE_WORKTREE_OFF_RE_DQ: OFF_DQ,
      ENFORCE_WORKTREE_OFF_LOOKSLIKE_RE: OFF_LL,
      ENFORCE_WORKTREE_ON_RE_DQ: ON_DQ,
      ENFORCE_WORKTREE_ON_LOOKSLIKE_RE: ON_LL,
    } = require("./lib/sentinel-patterns"));
  } catch (_) {
    process.exit(0);
  }

  let lines;
  try {
    lines = fs.readFileSync(transcriptPath, "utf8").split("\n");
  } catch (_) {
    process.exit(0);
  }

  let cmdOrder = 0;
  let lastOffIdx = -1;
  let lastOnIdx = -1;
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
      if (!item || item.type !== "tool_use" || item.name !== "Bash") continue;
      const cmd = (item.input && item.input.command) || "";
      cmdOrder++;
      if (OFF_DQ.test(cmd) || OFF_LL.test(cmd)) lastOffIdx = cmdOrder;
      if (ON_DQ.test(cmd) || ON_LL.test(cmd)) lastOnIdx = cmdOrder;
    }
  }

  if (lastOffIdx >= 0 && (lastOnIdx < 0 || lastOffIdx > lastOnIdx)) {
    const advisory =
      "[Workflow] ENFORCE_WORKTREE_OFF was proposed but the matching ENFORCE_WORKTREE_ON sentinel was not Bash-emitted before session stop. Run: echo \"<<WORKFLOW_ENFORCE_WORKTREE_ON: <reason>>>\" to restore enforcement explicitly, or let the next session restore it automatically.";
    try {
      process.stdout.write(JSON.stringify({ additionalContext: advisory }) + "\n");
    } catch (_) {}
  }
  process.exit(0);
}
