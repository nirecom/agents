"use strict";
// hooks/lib/jev/two-stage/orphan.js — the sweep's handling of a cli-ticket orphan (#2460):
// a written-ahead result is replayed exactly as finalize would; a ticket nobody finalized is
// recorded once as finalize-absent (when the CLI owns the record) and never settled.
// {ok:false} keeps the sweep's claim, so a later sweep retries.

const { registryEntry } = require("../registry");
const { appendDecisionOnce } = require("../decision-record");
const { validHand, removeSources } = require("./paths");
const { absentRecord } = require("./merge");
const { replayFinalized } = require("./replay");

function handleTicketOrphan(sid, tid, hand) {
  if (!validHand(hand, registryEntry) || hand.ticket !== tid || hand.session_id !== sid) {
    removeSources(sid, tid);
    return { ok: true };
  }
  try {
    if (hand.finalized === true) {
      replayFinalized(sid, tid, hand, {});
      return { ok: true };
    }
    if (hand.record_decision) {
      const r = appendDecisionOnce(absentRecord(sid, tid, hand, require(hand.adapter)));
      if (!r || !r.ok) return { ok: false };
    }
    removeSources(sid, tid);
    return { ok: true };
  } catch (_e) {
    return { ok: false };
  }
}

module.exports = { handleTicketOrphan };
