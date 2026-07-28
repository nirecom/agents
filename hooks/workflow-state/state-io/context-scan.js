"use strict";
// Transcript scan that recovers the active session's state for a given context.
// Entrypoint-private to state-io.js.

const fs = require("fs");
const os = require("os");
const path = require("path");
const { _listJsonlByMtime } = require("../session-id");
const { readState } = require("./core");

const SESSION_ID_RE = /Current workflow session_id:\s*([^\s\\]+)/;

function findLatestStateForContext(ctx) {
  if (!ctx || typeof ctx.cwd !== "string") return null;

  const encoded = ctx.cwd.toLowerCase().replace(/[^a-zA-Z0-9]/g, "-");
  const transcriptBase = process.env.CLAUDE_TRANSCRIPT_BASE_DIR ||
    path.join(os.homedir(), ".claude", "projects");
  const transcriptDir = path.join(transcriptBase, encoded);

  let files;
  try {
    files = _listJsonlByMtime(transcriptDir).slice(0, 10);
  } catch (e) {
    return null;
  }

  for (const { name } of files) {
    const filePath = path.join(transcriptDir, name);
    const foundIds = [];
    try {
      const content = fs.readFileSync(filePath, "utf8");
      for (const line of content.split("\n")) {
        if (!line) continue;
        try {
          const entry = JSON.parse(line);
          if (entry.type !== "attachment") continue;
          const att = entry.attachment;
          if (!att || att.exitCode !== 0) continue;
          if (!["SessionStart", "PostCompact"].includes(att.hookEvent)) continue;
          const m = (att.stdout || "").match(SESSION_ID_RE);
          if (m) foundIds.push(m[1]);
        } catch (e) {}
      }
    } catch (e) { continue; }

    if (foundIds.length === 0) continue;

    for (const id of [...foundIds].reverse()) {
      try {
        const state = readState(id);
        if (!state) continue;
        if ((state.git_branch ?? null) !== (ctx.git_branch ?? null)) continue;
        const allPending = Object.values(state.steps || {})
          .every((v) => !v || v.status === "pending");
        if (allPending) continue;
        if (state.steps?.user_verification?.status === "complete") break;
        return state;
      } catch (e) { continue; }
    }
  }
  return null;
}

module.exports = {
  SESSION_ID_RE,
  findLatestStateForContext,
};
