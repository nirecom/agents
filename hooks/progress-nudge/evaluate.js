"use strict";
// The full path of hooks/progress-nudge.js: one evaluation of an active session.
//   4a  step completes since the cursor (PostToolUse command tool / Agent / Task, Stop) — never capped
//   4c  transcript growth (lib/progress-pressure) — never at Stop
//   4d  the compaction pending flag (lib/progress-compaction)
//   burst  the once-per-session suggestion for the user — never capped
// 4c and 4d share a cap of CAP_MAX requests per CAP_WINDOW_MS; a capped 4d is dropped.
// Any request moves the baseline to the measured transcript, so it is not re-asked at once.

const fs = require("fs");
const { toMillis } = require("../lib/handoff-sidecar");
const PF = require("../lib/progress-file");
const { computePressureSignal, writeBaseline } = require("../lib/progress-pressure");
const { isCommandTool } = require("../lib/tool-command-text");
const { MTIME_TOLERANCE_MS } = require("./light");
const { buildMessage } = require("./message");

const CAP_WINDOW_MS = 60 * 60 * 1000;
const CAP_MAX = 2;
// Lock waits stay inside the 5 s hook timeout (settings.json), node startup included:
// phase (a) waits at most CURSOR_LOCK_WAIT_MS, everything after its commit POST_COMMIT_BUDGET_MS.
const CURSOR_LOCK_WAIT_MS = 1000;
const POST_COMMIT_BUDGET_MS = 1500;

function statOrNull(p) {
  try { return fs.statSync(p); } catch (_) { return null; }
}

// newCompletes(sid, cursor) -> {steps, maxSeq} — complete step_status events after cursor,
// excluding the backfilled ones (inherited history is not progress of this session).
function newCompletes(sid, cursor) {
  let st = null;
  try { st = require("../workflow-state/state-io").readState(sid); } catch (_) { st = null; }
  const events = st && Array.isArray(st.events) ? st.events : [];
  const steps = [];
  let maxSeq = cursor;
  for (const e of events) {
    if (!e || typeof e.seq !== "number" || e.seq <= cursor) continue;
    if (e.seq > maxSeq) maxSeq = e.seq;
    if (e.kind === "step_status" && e.status === "complete" && e.provenance !== "backfilled" && typeof e.step === "string") {
      steps.push(e.step);
    }
  }
  return { steps, maxSeq };
}

// Moves the baseline when session-progress.md was written after it (the model's update counts).
function progressUpdatePatch(cur, progressPath, transcriptPath, now, created) {
  const m = statOrNull(progressPath);
  if (!m) return {};
  const seen = typeof cur.progress_seen_mtime === "number" ? cur.progress_seen_mtime : null;
  if (created || (seen !== null && Math.abs(m.mtimeMs - seen) <= MTIME_TOLERANCE_MS)) {
    return seen === m.mtimeMs ? {} : { progress_seen_mtime: m.mtimeMs };
  }
  const baseAt = toMillis(cur.baseline_at);
  const patch = { progress_seen_mtime: m.mtimeMs };
  if (seen !== null && baseAt !== null && m.mtimeMs > baseAt) {
    const t = statOrNull(transcriptPath);
    if (t) Object.assign(patch, { baseline_bytes: t.size, baseline_at: new Date(now).toISOString(), transcript_path: transcriptPath });
    patch.last_update_at = new Date(now).toISOString();
    patch.progress_updates = (Number(cur.progress_updates) || 0) + 1;
    // An update written after the latest compaction answers that compaction's pending request.
    const lastCompaction = (Array.isArray(cur.compactions_at) ? cur.compactions_at : []).map(toMillis)
      .filter((t) => t !== null).reduce((a, b) => Math.max(a, b), null);
    if (cur.compaction_pending === true && lastCompaction !== null && m.mtimeMs > lastCompaction) patch.compaction_pending = false;
  }
  return patch;
}

// evaluate({sid, event, tool, transcriptPath, now}) -> additionalContext string | null.
function evaluate(o) {
  const { sid, event, tool, transcriptPath, now } = o;
  const ensured = PF.ensureProgressFile(sid);
  // No usable progress file: consume nothing, so the completes are requested once it can be created.
  if (!ensured.path) return null;
  const progressPath = ensured.path;
  const stepCandidate = event === "Stop" || (event === "PostToolUse" && (isCommandTool(tool) || tool === "Agent" || tool === "Task"));
  const steps = PF.updatePressure(sid, (cur) => {
    const pre = { progress_path: progressPath };
    Object.assign(pre, progressUpdatePatch(cur, progressPath, transcriptPath, now, ensured.created));
    if (!stepCandidate) return { patch: pre, result: [] };
    const cursor = typeof cur.event_cursor === "number" ? cur.event_cursor : 0;
    const r = newCompletes(sid, cursor);
    if (r.maxSeq !== cursor) pre.event_cursor = r.maxSeq;
    return { patch: pre, result: r.steps };
  }, { lockWaitMs: CURSOR_LOCK_WAIT_MS });
  // Fail open. Phase (a) failed or its lock wait timed out: nothing was consumed, so return null
  // and the next run delivers the completes. Phase (b) failed: the cursor already moved past the
  // steps, so deliver them; the rest stays pending for next run.
  if (steps === null) return null;

  // The cursor is committed: every later lock wait is bounded so the hook timeout cannot kill
  // the run before the steps are delivered. A timeout falls into the d === null path below.
  const budgetStart = Date.now();
  const remaining = () => POST_COMMIT_BUDGET_MS - (Date.now() - budgetStart);
  let volume = null;
  if (event !== "Stop" && remaining() > 0 && !isCapped(PF.readPressure(sid) || {}, now)) {
    const sig = computePressureSignal({ sid, transcriptPath, now, lockWaitMs: Math.max(1, remaining()) });
    if (sig.shouldNudge) volume = sig.bytesSince;
  }
  const left = remaining();
  const d = left > 0 ? PF.updatePressure(sid, (cur) => decide(cur, now, steps, volume), { lockWaitMs: left }) : null;
  if (d === null) {
    return steps.length > 0 ? buildMessage({ steps, bytesSince: null, compaction: false, burst: false, progressPath }) : null;
  }
  if (!d.fired) return null;
  const t = statOrNull(transcriptPath);
  const baselineLeft = remaining();
  if (t && d.volume === null && baselineLeft > 0) writeBaseline(sid, t.size, now, transcriptPath, { lockWaitMs: baselineLeft });
  return buildMessage({ steps, bytesSince: d.volume, compaction: d.compaction, burst: d.burst, progressPath });
}

function recentRequests(cur, now) {
  return (Array.isArray(cur.requests_at) ? cur.requests_at : []).map(toMillis)
    .filter((t) => t !== null && now - t < CAP_WINDOW_MS);
}

function isCapped(cur, now) {
  return recentRequests(cur, now).length >= CAP_MAX;
}

// decide(cur, now, steps, measured) -> {patch, result} — the decision phase, run under the
// pressure lock; a volume measured before a concurrent request capped the session is dropped.
function decide(cur, now, steps, measured) {
  const requests = recentRequests(cur, now);
  const capped = requests.length >= CAP_MAX;
  const volume = capped ? null : measured;
  const compaction = !capped && cur.compaction_pending === true;
  const burst = cur.burst_pending === true;

  const post = { requests_at: requests.map((t) => new Date(t).toISOString()) };
  if (capped && cur.compaction_pending === true) post.compaction_pending = false;
  const fired = steps.length > 0 || volume !== null || compaction || burst;
  const result = { fired, volume, compaction, burst };
  if (!fired) return { patch: post, result };
  const counts = Object.assign({}, cur.counts || {});
  const bump = (k, n) => { counts[k] = (Number(counts[k]) || 0) + n; };
  if (steps.length > 0) bump("step_complete", steps.length);
  if (volume !== null) bump("volume", 1);
  if (compaction) bump("compaction", 1);
  if (volume !== null || compaction) post.requests_at.push(new Date(now).toISOString());
  // A 4d request is not a reset point: compactions in a row ask only once (intent 4d).
  if (steps.length > 0 || volume !== null) post.last_request_at = new Date(now).toISOString();
  if (compaction) post.compaction_pending = false;
  if (burst) post.burst_pending = false;
  post.counts = counts;
  return { patch: post, result };
}

module.exports = { CAP_WINDOW_MS, CAP_MAX, evaluate };
