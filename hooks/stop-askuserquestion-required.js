#!/usr/bin/env node
// Stop hook (#545): block when WORKFLOW_USER_VERIFIED is emitted without a
// preceding AskUserQuestion in the same assistant turn. Per
// skills/_shared/user-verified.md, AskUserQuestion must precede the sentinel
// so the user records an explicit answer.
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

  let USER_VERIFIED_RE_DQ, USER_VERIFIED_LOOKSLIKE_RE;
  try {
    ({ USER_VERIFIED_RE_DQ, USER_VERIFIED_LOOKSLIKE_RE } = require("./lib/sentinel-patterns"));
  } catch (_) {
    process.exit(0);
  }

  let lines;
  try {
    lines = fs.readFileSync(transcriptPath, "utf8").split("\n");
  } catch (_) {
    process.exit(0);
  }

  // Walk all assistant turns in transcript-tail order, recording AskUserQuestion sightings
  // and the first USER_VERIFIED Bash. Canonical flow spans multiple turns:
  //   turn N   (assistant): AskUserQuestion
  //   turn N+1 (user)     : answer
  //   turn N+2 (assistant): Bash USER_VERIFIED
  // So restricting to the last assistant turn would block the legitimate flow.
  // Scan the last 50 entries to bound work; AskUserQuestion may precede USER_VERIFIED across turns.
  const TAIL = 50;
  const tail = lines.slice(-TAIL);
  let askUserQuestionSeen = false;
  let userVerifiedFound = false;
  for (const line of tail) {
    if (userVerifiedFound) break;
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
      if (item.name === "AskUserQuestion") {
        askUserQuestionSeen = true;
        continue;
      }
      if (item.name === "Bash") {
        const cmd = (item.input && item.input.command) || "";
        if (USER_VERIFIED_RE_DQ.test(cmd) || USER_VERIFIED_LOOKSLIKE_RE.test(cmd)) {
          userVerifiedFound = true;
          break;
        }
      }
    }
  }

  if (userVerifiedFound && !askUserQuestionSeen) {
    const reason =
      "[Workflow] WORKFLOW_USER_VERIFIED emitted without a preceding AskUserQuestion. Per skills/_shared/user-verified.md, an AskUserQuestion must precede the sentinel so the user can record an explicit answer. Re-emit AskUserQuestion then the USER_VERIFIED sentinel.";
    try {
      process.stdout.write(JSON.stringify({ decision: "block", reason }) + "\n");
    } catch (_) {}
    process.exit(2);
  }
  process.exit(0);
}
