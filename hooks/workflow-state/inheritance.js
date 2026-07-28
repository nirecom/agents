"use strict";
// Cross-session workflow-state inheritance (#1305).
//
// A new session that starts on the same cwd+branch as a recent session inherits
// that session's step statuses, so continuing work does not restart the workflow.
// The eligibility decision itself is NOT made here — it is owned by
// evaluateInheritance() in effective-state.js (SSOT). This module only walks the
// transcript files and applies the returned verdict.
//
// SCAN CONTRACT (#1305): evaluateInheritance returns scan:"stop" for a staleness
// boundary (a finalized or implementation-complete session). "stop" aborts the
// ENTIRE search — not just the current transcript — otherwise the walk falls
// through to an older transcript and resurrects state from before the boundary.

const fs = require("fs");
const os = require("os");
const path = require("path");
const { readState } = require("./state-io");
const { _listJsonlByMtime } = require("./session-id");

// Extracts the workflow session_id announced by the SessionStart/PostCompact
// hook output embedded in a transcript attachment. Module-internal: deliberately
// NOT re-exported through the barrel.
const SESSION_ID_RE = /Current workflow session_id:\s*([^\s\\]+)/;

// Collect the workflow session ids announced inside one transcript file, in
// announcement order. Returns [] on any read failure (fail-open).
function collectSessionIds(filePath) {
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
      } catch (e) { /* fail-open: skip malformed line */ }
    }
  } catch (e) {
    return [];
  }
  return foundIds;
}

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

  // Lazy require: effective-state → evidence-resolver → state-io, and this module
  // is reached through the barrel. Deferring keeps the load order acyclic.
  const { evaluateInheritance } = require("./effective-state");

  let stopSearch = false;
  for (const { name } of files) {
    if (stopSearch) break;
    const foundIds = collectSessionIds(path.join(transcriptDir, name));
    if (foundIds.length === 0) continue;

    for (const id of [...foundIds].reverse()) {
      let state;
      try {
        state = readState(id);
      } catch (e) { continue; }
      if (!state) continue;
      if ((state.git_branch ?? null) !== (ctx.git_branch ?? null)) continue;

      const verdict = evaluateInheritance(state);
      if (verdict && verdict.eligible) {
        // The canonical session ID is the one embedded in the transcript
        // (`id`), not state.session_id — a test fixture or compacted record
        // may embed a stale or placeholder value. Normalise so that callers
        // (e.g. session-start's plan_approvals back-fill) use the right ID.
        if (state.session_id !== id) {
          state = Object.assign({}, state, { session_id: id });
        }
        return state;
      }
      if (verdict && verdict.scan === "stop") { stopSearch = true; break; }
      // scan === "continue": unusable candidate, but not a staleness boundary.
    }
    if (stopSearch) return null;
  }
  return null;
}

module.exports = { findLatestStateForContext };
