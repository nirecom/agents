"use strict";
// hooks/lib/prompt-turn-id.js — one turn id per user prompt (#2768). The UserPromptSubmit hook
// removes the previous prompt-turn.json and writes a fresh {turn_id, created_at}; plan-sync reads it
// back. No transcript is read: the removal before the write is what keeps a stale id from surviving.

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { controlPath } = require("../workflow-state/state-io/control-dir");
const { resolveSessionId } = require("../workflow-state/session-id");

const PROMPT_TURN_FILE = "prompt-turn.json";
const SID_RE = /^[A-Za-z0-9_-]+$/;
const TURN_ID_RE = /^[0-9a-f]{32}$/;

const validSid = (sid) => typeof sid === "string" && SID_RE.test(sid);

// writePromptTurn(sid, deps) -> the new turn id, or null when the write fails (deps.fs for tests).
function writePromptTurn(sid, deps) {
  const xfs = (deps && deps.fs) || fs;
  if (!validSid(sid)) return null;
  let tmp = null;
  try {
    const dst = controlPath(sid, PROMPT_TURN_FILE, { forWrite: true });
    const turnId = crypto.randomBytes(16).toString("hex");
    const body = { turn_id: turnId, created_at: new Date().toISOString() };
    tmp = path.join(path.dirname(dst), `${PROMPT_TURN_FILE}.${process.pid}.${crypto.randomBytes(4).toString("hex")}.tmp`);
    xfs.writeFileSync(tmp, JSON.stringify(body) + "\n", { flag: "wx" });
    xfs.renameSync(tmp, dst);
    return turnId;
  } catch (_e) {
    if (tmp) { try { xfs.unlinkSync(tmp); } catch (_) {} }
    return null;
  }
}

// readPromptTurn(sid) -> {turnId, createdAt (ISO)}, or null when absent or malformed.
function readPromptTurn(sid) {
  try {
    if (!validSid(sid)) return null;
    const b = JSON.parse(fs.readFileSync(controlPath(sid, PROMPT_TURN_FILE), "utf8"));
    if (!b || typeof b !== "object") return null;
    if (typeof b.turn_id !== "string" || !TURN_ID_RE.test(b.turn_id)) return null;
    if (typeof b.created_at !== "string" || !Number.isFinite(Date.parse(b.created_at))) return null;
    return { turnId: b.turn_id, createdAt: b.created_at };
  } catch (_e) {
    return null;
  }
}

// resolveTurnContext(input) -> {sid, turnId} for the session's recorded turn, else null.
function resolveTurnContext(input) {
  try {
    const sid = resolveSessionId({
      sessionIdFromInput: input && input.session_id,
      transcriptPath: input && typeof input.transcript_path === "string" ? input.transcript_path : "",
    });
    if (!validSid(sid)) return null;
    const turn = readPromptTurn(sid);
    return turn ? { sid, turnId: turn.turnId } : null;
  } catch (_e) {
    return null;
  }
}

module.exports = { PROMPT_TURN_FILE, writePromptTurn, readPromptTurn, resolveTurnContext };
