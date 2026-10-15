"use strict";
// hooks/lib/jev/two-stage/finalize.js — `jev-judge finalize` (#2460): re-output a done ticket,
// otherwise claim (or take over) the ticket, judge it from its frozen policy and its own
// answer file, write the result ahead into the claim, and replay the side effects from there.
// A write-ahead result is only ever replayed: no new judgment, no fail-safe.

const fs = require("fs");
const path = require("path");

const pending = require("../pending");
const { registryEntry } = require("../registry");
const { isValidId } = require("../state-paths");
const { compareOwner, readOwner } = require("./settle-complexity");
const { readSkipOwner } = require("./settle-skip");
const { judgeComplexity } = require("./merge");
const { judgeSkip } = require("./merge-skip");
const { replayFinalized } = require("./replay");
const { TICKET_RE, readDone, errorResult, crash, removeSources, validHand } = require("./paths");

const NORMALIZER = path.join(__dirname, "..", "..", "..", "..", "bin", "workflow", "normalize-judge-signals");

const SKIP_HEADER = ["RESULT=", "SKIP=", "ADOPTED=", "MODE=", "SETTLE="];

// A skip done marker whose MS now names a newer owner: the header only, as superseded.
function reoutputSkip(sid, tid, done, lines) {
  const m = readSkipOwner(sid, done.target);
  if (!m || m.owner_id === tid || compareOwner(m, { id: tid, created_ms: done.created_ms }) <= 0) return null;
  return {
    exit: 0,
    stdout_lines: lines.filter((l) => SKIP_HEADER.some((h) => l.startsWith(h)))
      .map((l) => (l.startsWith("SKIP=") ? "SKIP=false" : l === "SETTLE=ok" ? "SETTLE=superseded" : l)),
  };
}

// The recorded stdout, in the superseded form when a newer owner took the fixed file since.
function reoutput(sid, tid, done) {
  const lines = done.stdout_lines.slice();
  if (lines.includes("SETTLE=ok") && typeof done.target === "string") {
    const r = reoutputSkip(sid, tid, done, lines);
    if (r) return r;
  } else if (lines.includes("SETTLE=ok") && typeof done.stage === "string") {
    const m = readOwner(sid, done.stage);
    if (m && m.owner_id !== tid && compareOwner(m, { id: tid, created_ms: done.created_ms }) > 0) {
      return {
        exit: 0,
        stdout_lines: lines.map((l) => (l.startsWith("SIGNALS_CSV=") ? "SIGNALS_CSV=-" : l === "SETTLE=ok" ? "SETTLE=superseded" : l)),
      };
    }
  }
  return { exit: typeof done.exit === "number" ? done.exit : 0, stdout_lines: lines };
}

// A run stopped after the done marker leaves its claim and copies; drop them without rewriting.
function dropLeftovers(sid, tid) {
  if (pending.takeOverClaim(sid, tid) !== null) pending.releaseClaim(sid, tid);
  removeSources(sid, tid);
}

function hasOtherClaim(sid, tid) {
  try {
    return fs.readdirSync(pending.pendingDir(sid)).some((n) => n.startsWith(`${tid}.claimed-`));
  } catch (_e) {
    return false;
  }
}

// {hand} | {error}: this process's claim of the ticket, or why there is none.
function claimTicket(sid, tid) {
  const hand = pending.claimPending(sid, tid);
  if (hand !== null) return { hand };
  const taken = pending.takeOverClaim(sid, tid);
  if (taken !== null) return { hand: taken };
  return { error: hasOtherClaim(sid, tid) ? "in-progress" : "ticket-missing" };
}

// The adapter is the ticket's own (validHand: the registry still names the same one).
function judge(sid, tid, hand) {
  const adapter = require(hand.adapter);
  if (hand.target) return judgeSkip(sid, tid, hand, adapter);
  return judgeComplexity(sid, tid, hand, adapter, require(NORMALIZER).normalize);
}

// finalize(args, opts) -> {exit, stdout_lines}. args: {sid|session, ticket}; opts (module API
// only, also read from args): resolveEntry, crashAt.
async function finalize(args, optsArg = {}) {
  const a = args || {};
  const opts = Object.assign({}, a, optsArg);
  const sid = a.sid || a.session || a.sessionId;
  const tid = a.ticket;
  if (!isValidId(sid) || typeof tid !== "string" || !TICKET_RE.test(tid)) return { exit: 2, stdout_lines: [] };
  const resolveEntry = typeof opts.resolveEntry === "function" ? opts.resolveEntry : registryEntry;
  try {
    const done = readDone(sid, tid);
    if (done) {
      dropLeftovers(sid, tid);
      return reoutput(sid, tid, done);
    }
    const c = claimTicket(sid, tid);
    if (c.error) {
      const late = readDone(sid, tid);
      return late ? reoutput(sid, tid, late) : errorResult(c.error);
    }
    let hand = c.hand;
    if (!validHand(hand, resolveEntry) || hand.ticket !== tid || hand.session_id !== sid) {
      pending.releaseClaim(sid, tid);
      return errorResult("ticket-invalid");
    }
    if (hand.finalized !== true) {
      const j = judge(sid, tid, hand);
      hand = Object.assign({}, hand, { finalized: true, result: j.result, record: j.record });
      if (!pending.rewriteClaim(sid, tid, hand)) return { exit: 3, stdout_lines: [] };
      crash(opts, "after-wal");
    }
    return replayFinalized(sid, tid, hand, opts);
  } catch (_e) {
    return { exit: 3, stdout_lines: [] };
  }
}

module.exports = { finalize, runFinalize: finalize };
