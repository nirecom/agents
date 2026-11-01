"use strict";
// hooks/lib/turn-generation.js — the session's current turn generation (#2461): the turn id of the
// latest user prompt and the transcript it was written in, both from prompt-turn.json. A turn
// written before the transcript path was recorded has no generation; callers then do nothing.
// The recorded path is file content, so it is trusted only as a .jsonl under Claude Code's projects/ directory.

const fs = require("fs");
const os = require("os");
const path = require("path");
const { PROMPT_TURN_FILE, readPromptTurn } = require("./prompt-turn-id");
const { controlPath } = require("../workflow-state/state-io/control-dir");
const { toWindowsPath } = require("./branch-diff");

// <CLAUDE_CONFIG_DIR, else ~/.claude>/projects, resolved.
function transcriptRoot() {
  const cfg = process.env.CLAUDE_CONFIG_DIR;
  const base = typeof cfg === "string" && cfg !== "" ? toWindowsPath(cfg) : path.join(os.homedir(), ".claude");
  return path.resolve(base, "projects");
}

// True when tp ends in .jsonl and resolves strictly under transcriptRoot().
function isTrustedTranscriptPath(tp) {
  if (typeof tp !== "string" || !tp.endsWith(".jsonl")) return false;
  const fold = (p) => (process.platform === "win32" ? p.toLowerCase() : p);
  const rel = path.relative(fold(transcriptRoot()), fold(path.resolve(toWindowsPath(tp))));
  return rel !== "" && rel !== ".." && !rel.startsWith(`..${path.sep}`) && !path.isAbsolute(rel);
}

// readTurnGeneration(sid) -> {turnId, transcriptPath}, or null when absent, malformed, path-less,
// or the path is not a trusted transcript path.
function readTurnGeneration(sid) {
  try {
    const turn = readPromptTurn(sid);
    if (!turn) return null;
    const b = JSON.parse(fs.readFileSync(controlPath(sid, PROMPT_TURN_FILE), "utf8"));
    const tp = b && b.turn_id === turn.turnId ? b.transcript_path : null;
    if (typeof tp !== "string" || tp === "" || !isTrustedTranscriptPath(tp)) return null;
    return { turnId: turn.turnId, transcriptPath: tp };
  } catch (_e) {
    return null;
  }
}

module.exports = { isTrustedTranscriptPath, readTurnGeneration };
