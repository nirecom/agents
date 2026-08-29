"use strict";
// hooks/lib/active-session-ids.js
// Observes the session ids a clearance READER could currently key on (#2108).
// Every reader opens exactly `path.join(dir, sid + ".<kind>")`, so a basename only
// confers clearance when its STEM is one of these ids — protected-basenames.js uses
// this set to stop classifying artifact names as forged state.

// FAIL-CLOSED CONTRACT: any observation fault yields `complete:false`, and callers
// must then apply NO narrowing (identical to pre-#2108 suffix-only behaviour). A
// narrowing that failed open would be worse than the false positive it removes.

// R13 one-way dependency edge: this module must NOT require protected-basenames.js —
// a cycle would let require order decide whether the narrowing applies at all.

const fs = require("fs");

const { resolveSessionId } = require("../workflow-state/session-id");
const { getWorkflowDir } = require("../workflow-state/state-io/core");
const { enumerateWorktreeNotesSessionIds } = require("./worktree-notes-session-ids");

// The FILENAME alphabet of a state entry (mirrors SESSION_ID_VALID_RE in
// workflow-state/state-io/core.js) — not the session-id SHAPE, which
// protected-basenames.js owns. A name outside it is simply not a sid and is
// skipped; skipping is NOT a fault, so the observation stays complete.
const SID_FILENAME_STEM_RE = /^[A-Za-z0-9_-]+$/;

// Process-lifetime memo: one hook process classifies many basenames against one session
// context, and re-reading the store per basename would turn an O(1) gate into an O(n) one.
// The key must name EVERY input that decides the answer — sid, transcriptPath (it feeds
// resolveSessionId's priority 5) and cwd (the notes enumeration reads it). Keying on the
// sid alone let two calls with different transcripts share one cached set.
let memo = null;

function memoKeyOf(fromInput, transcriptPath) {
  let cwd = "";
  try {
    cwd = process.cwd();
  } catch (_) {
    cwd = "";
  }
  return JSON.stringify([fromInput, transcriptPath, cwd]);
}

function stemOfStateEntry(entry) {
  const name = String(entry);
  const dot = name.indexOf(".");
  return dot === -1 ? name : name.slice(0, dot);
}

// observeActiveSessionIds(sessionCtx): { sids: Set<string>, complete: boolean }.
// `sessionCtx` is `{ sessionId, transcriptPath }` carried out of the hook's stdin.
// `sids` is lower-cased; callers fold before testing membership.
function observeActiveSessionIds(sessionCtx) {
  const ctx = sessionCtx && typeof sessionCtx === "object" ? sessionCtx : {};
  const fromInput = typeof ctx.sessionId === "string" ? ctx.sessionId : null;
  const transcriptPath = typeof ctx.transcriptPath === "string" ? ctx.transcriptPath : null;
  const memoKey = memoKeyOf(fromInput, transcriptPath);
  if (memo && memo.key === memoKey) return memo.value;

  const sids = new Set();
  let complete = true;

  // This session's OWN id is always present: it must stay able to write its own
  // marker even when nothing on disk corroborates the id yet — but only when it is a
  // legal state-file stem, the same gate every disk-read stem passes below. Without
  // it an agent could name its own clearance stem just by sending it on stdin.
  if (fromInput && SID_FILENAME_STEM_RE.test(fromInput)) sids.add(fromInput.toLowerCase());

  // resolveSessionId() is the SSOT for "which session am I"; never duplicate its
  // 7-step chain here. A null return is an ANSWER, not a fault.
  try {
    const resolved = resolveSessionId({
      sessionIdFromInput: fromInput === null ? undefined : fromInput,
      transcriptPath: transcriptPath === null ? undefined : transcriptPath,
    });
    if (typeof resolved === "string" && resolved !== "") sids.add(resolved.toLowerCase());
  } catch (e) {
    complete = false;
  }

  // resolveSessionId() returns at its FIRST priority hit, so with a stdin sid present it
  // never reads the agent-writable WORKTREE_NOTES.md `Session-ID:` line — while a
  // clearance READER in another process, having no stdin sid, falls through to priority
  // 6/6b/6c and honours it (#2108). Every id a reader could land on there is therefore
  // clearance-bearing and must be observed here, ambiguous or not.
  const notes = enumerateWorktreeNotesSessionIds();
  if (!notes.complete) complete = false;
  for (const sid of notes.sids) {
    if (SID_FILENAME_STEM_RE.test(sid)) sids.add(sid.toLowerCase());
  }

  // The workflow state store is the only place live sessions are enumerable. The
  // plans dir is deliberately NOT read: a plan artifact proves a session existed,
  // not that a clearance reader is keyed on it.
  try {
    for (const entry of fs.readdirSync(getWorkflowDir())) {
      const stem = stemOfStateEntry(entry);
      if (stem !== "" && SID_FILENAME_STEM_RE.test(stem)) sids.add(stem.toLowerCase());
    }
  } catch (e) {
    complete = false;
  }

  const value = { sids, complete };
  memo = { key: memoKey, value };
  return value;
}

module.exports = { observeActiveSessionIds, SID_FILENAME_STEM_RE };
