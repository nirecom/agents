"use strict";
// Temporary (#2748): deleted with this folder per the deletion-condition in bin/migrate-orphan-progress-files.
// Steps 3-5 of one session chain: plan renames, approval records, sidecar pins.

const fs = require("fs");
const { PLAN_STAGE_TABLE } = require("../../../workflow-state/plan-stage-table");
const { mergePressure, readPressure } = require("../../progress-pressure-sidecar");

const ORIGIN = "migrate-orphan-progress-file";

// renamePlans(renames) — oldest generation first, so the newest plan of a stage is the one left.
function renamePlans(renames) {
  for (const { from, to } of renames) {
    if (fs.existsSync(from)) fs.renameSync(from, to);
  }
}

// staleApprovals(state, chainSids, firstSid) -> plan_approvals records naming a chain sid other than firstSid.
function staleApprovals(state, chainSids, firstSid) {
  const recs = (state && state.plan_approvals) || {};
  const out = [];
  for (const step of Object.keys(PLAN_STAGE_TABLE)) {
    const rec = recs[step];
    if (!rec || rec.artifact_session_id === firstSid || !chainSids.has(rec.artifact_session_id)) continue;
    out.push({ step, rec });
  }
  return out;
}

// repointApprovals(states, chainSids, firstSid) — one backfilled plan_approval per stale record.
function repointApprovals(states, chainSids, firstSid) {
  const { appendEvents } = require("../../../workflow-state/state-io");
  for (const [sid, state] of states) {
    const events = staleApprovals(state, chainSids, firstSid).map(({ step, rec }) => ({
      kind: "plan_approval",
      step,
      source: rec.source,
      reason: rec.reason,
      artifact_sha256: rec.artifact_sha256,
      artifact_session_id: firstSid,
      artifact_hash_status: rec.artifact_hash_status,
      provenance: "backfilled",
      origin: ORIGIN,
    }));
    if (events.length) appendEvents(sid, events);
  }
}

// repin(downstreamSids, firstSid) -> sids whose self pin could not be moved.
function repin(downstreamSids, firstSid) {
  const failed = [];
  for (const sid of downstreamSids) {
    const ok = mergePressure(sid, { root_sid: firstSid }, { onlyIf: (cur) => cur.root_sid === sid });
    if (!ok && isSelfPinned(sid)) failed.push(sid);
  }
  return failed;
}

function isSelfPinned(sid) {
  try {
    const cur = readPressure(sid);
    return !!cur && cur.root_sid === sid;
  } catch (_) {
    return false;
  }
}

module.exports = { renamePlans, staleApprovals, repointApprovals, repin, isSelfPinned };
