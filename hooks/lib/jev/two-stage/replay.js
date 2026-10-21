"use strict";
// hooks/lib/jev/two-stage/replay.js — everything after the write-ahead (#2460): append the
// decision record once, settle the fixed file through the owner marker, write the done
// marker, then drop the claim and the copies. Every step is idempotent, so a finalize re-run
// and the orphan sweep both finish a stopped ticket with exactly the uncrashed outcome.
// FALLBACK=<reason> follows SETTLE= only when the merge demoted the output (#2677) or the
// settle demoted it for a changed source (FALLBACK=source-changed, #2701).

const pending = require("../pending");
const { appendDecisionOnce } = require("../decision-record");
const { settleComplexity } = require("./settle-complexity");
const { settleSkip } = require("./settle-skip");
const { sourcesChanged } = require("./source-fresh");
const { readDone, writeDone, crash, removeSources } = require("./paths");
const { UNDECIDABLE_SIGNAL } = require("../../../workflow-state/complexity-routing");

function settleRecord(sid, tid, hand, v) {
  return {
    version: 2, record_type: "settle", ts: new Date().toISOString(), point: hand.point,
    session_id: sid, stage: hand.stage, ticket: tid, settle: v.settle, detail: v.detail || null, owner: v.owner || null,
  };
}

function appendOrThrow(rec) {
  const r = appendDecisionOnce(rec);
  if (!r || !r.ok) throw new Error("decision log append failed");
}

// At most one line: the merge's reason first, else a settle demoted for a changed source
// (settled is the verdict the settle record carries). A pre-#2677 claim has no result.fallback.
function fallbackLines(r, settled) {
  if (typeof r.fallback === "string" && r.fallback) return [`FALLBACK=${r.fallback}`];
  return settled && settled.detail === "source-changed" ? ["FALLBACK=source-changed"] : [];
}

function cleanup(sid, tid) {
  pending.releaseClaim(sid, tid);
  removeSources(sid, tid);
}

// The skip settle. Its outcome is written into the claim before anything else, so a re-run
// relays the same record-skip-judgment lines instead of calling it a second time.
function replaySkip(sid, tid, hand, opts) {
  const r = hand.result;
  let v = hand.settled;
  if (!v) {
    v = settleSkip(sid, r.target, r.conditions, r.source, { id: tid, created_ms: hand.created_ms }, tid,
      { stage: hand.stage, artifacts_sha256: hand.artifacts_sha256 });
    if (!pending.rewriteClaim(sid, tid, Object.assign({}, hand, { settled: v }))) throw new Error("claim rewrite failed");
  }
  if (v.settle !== "ok" && hand.record_decision) appendOrThrow(settleRecord(sid, tid, hand, v));
  crash(opts, "after-settle");
  const lines = [
    "RESULT=ok",
    `SKIP=${v.settle === "ok" && r.skip === true}`,
    `ADOPTED=${r.adopted}`,
    `MODE=${hand.mode}`,
    `SETTLE=${v.settle}`,
  ].concat(fallbackLines(r, v), v.detail === "newer-owner" ? [] : v.rsj_lines || []);
  writeDone(sid, tid, { created_ms: hand.created_ms, point: hand.point, stage: r.stage, target: r.target, stdout_lines: lines, exit: 0 });
  crash(opts, "after-done");
  cleanup(sid, tid);
  return { exit: 0, stdout_lines: lines };
}

// The signals this ticket settles: its merged result while the stage sources are still the
// bytes fingerprinted at query time, else the fail-safe level. Decided once and written into
// the claim, so a re-run settles the same value whatever the sources are by then.
function settledSignals(sid, tid, hand) {
  if (typeof hand.settle_signals_csv === "string") return hand.settle_signals_csv;
  const csv = sourcesChanged(sid, hand.stage, hand.artifacts_sha256) ? UNDECIDABLE_SIGNAL : hand.result.signals_csv;
  if (!pending.rewriteClaim(sid, tid, Object.assign({}, hand, { settle_signals_csv: csv }))) throw new Error("claim rewrite failed");
  return csv;
}

// replayFinalized(sid, tid, hand, opts) -> {exit, stdout_lines}. hand carries finalized:true,
// result {stage, merged_line, signals_csv, adopted} (or a skip result with target) and the
// record. Throws on a failed step.
function replayFinalized(sid, tid, hand, opts = {}) {
  const done = readDone(sid, tid);
  if (done) {
    cleanup(sid, tid);
    return { exit: typeof done.exit === "number" ? done.exit : 0, stdout_lines: done.stdout_lines };
  }
  const r = hand.result;
  if (hand.record_decision) appendOrThrow(hand.record);
  crash(opts, "after-append");
  if (r.target) return replaySkip(sid, tid, hand, opts);
  const csv = settledSignals(sid, tid, hand);
  const line = csv === r.signals_csv ? r.merged_line : `SIGNALS: ${UNDECIDABLE_SIGNAL}`;
  const v = settleComplexity(sid, r.stage, line, csv, { id: tid, created_ms: hand.created_ms }, opts);
  const stale = csv !== r.signals_csv;
  const recorded = v.settle === "ok" && stale ? Object.assign({}, v, { detail: "source-changed" }) : v;
  if ((v.settle !== "ok" || stale) && hand.record_decision) appendOrThrow(settleRecord(sid, tid, hand, recorded));
  crash(opts, "after-settle");
  const lines = [
    "RESULT=ok",
    `SIGNALS_CSV=${v.settle === "ok" ? csv : "-"}`,
    `ADOPTED=${r.adopted}`,
    `MODE=${hand.mode}`,
    `SETTLE=${v.settle}`,
  ].concat(fallbackLines(r, recorded));
  writeDone(sid, tid, { created_ms: hand.created_ms, point: hand.point, stage: r.stage, stdout_lines: lines, exit: 0 });
  crash(opts, "after-done");
  cleanup(sid, tid);
  return { exit: 0, stdout_lines: lines };
}

module.exports = { replayFinalized, settleRecord, fallbackLines };
