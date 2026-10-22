"use strict";
// bin/workflow/lib/jev-complexity-adapter/request.js — the shadow path's Jev request (hook
// dispatches): header, the dispatch prompt, then intent/outline/detail, each redacted by
// redactOutbound before the 16000-char cap. The CLI path builds its state from jev-input.js.

const crypto = require("crypto");
const path = require("path");

const SCRIPT_CHECKOUT_ROOT = path.resolve(__dirname, "..", "..", "..", "..");
const {
  MAX_STATE_CHARS, ARTIFACTS,
  readArtifactsFor, notesSessionId, sliceUnits, redactOutbound,
} = require("../jev-request-common.js");

function plansDirOrNull() {
  try {
    const { getWorkflowPlansDir } = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "lib", "workflow-plans-dir.js"));
    return getWorkflowPlansDir();
  } catch (_e) {
    return null;
  }
}

// The bound WORKTREE_NOTES Session-ID's artifacts when it has any (the workflow session the
// LLM judge reads), else the hook session id's, so Jev sees the plan the LLM judge sees.
function readArtifacts(sessionId, cwd) {
  const dir = plansDirOrNull();
  if (!dir) return [];
  const notes = readArtifactsFor(dir, notesSessionId(cwd));
  return notes.length ? notes : readArtifactsFor(dir, sessionId);
}

function lineCount(text) {
  return text ? text.replace(/\n$/, "").split("\n").length : 0;
}

// The prompt is kept and later artifacts are trimmed first.
function buildRequest({ toolInput, sessionId, stage, cwd } = {}) {
  const prompt = redactOutbound(toolInput && typeof toolInput.prompt === "string" ? toolInput.prompt : "");
  const rawArts = readArtifacts(sessionId, cwd);
  const has = (n) => rawArts.some((a) => a.name === n);
  const planLines = rawArts.filter((a) => a.name !== "detail").reduce((n, a) => n + lineCount(a.text), 0);
  const arts = rawArts.map((a) => ({ name: a.name, text: redactOutbound(a.text) }));
  const header = [
    `stage: ${stage || "unknown"}`,
    `intent+outline lines: ${planLines}`,
    `artifacts: ${ARTIFACTS.map((n) => `${n}=${has(n) ? "present" : "absent"}`).join(" ")}`,
    "",
  ].join("\n");
  let state = `${header}\n## dispatch prompt\n${prompt}\n`;
  let truncated = false;
  if (state.length > MAX_STATE_CHARS) {
    state = sliceUnits(state, MAX_STATE_CHARS);
    truncated = true;
  }
  const sources = [];
  for (const a of arts) {
    if (truncated) break;
    const section = `\n## ${a.name}.md\n${a.text}`;
    const room = MAX_STATE_CHARS - state.length;
    if (section.length <= room) {
      state += section;
    } else {
      state += sliceUnits(section, room);
      truncated = true;
    }
    if (room > 0) sources.push(a.name);
  }
  return {
    state,
    input: {
      bytes: Buffer.byteLength(state),
      sha256: crypto.createHash("sha256").update(state).digest("hex"),
      truncated,
      sources,
    },
  };
}

module.exports = { buildRequest };
