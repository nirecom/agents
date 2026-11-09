"use strict";
// hooks/workflow-state/workflow-abort.js — the workflow_aborted record of a session (#2920): read it,
// record it once under the state lock, and pick the session-upstreams a session-downstream should abort.
// Every reader fails toward "not aborted".

const { SESSION_ID_VALID_RE, readState, readRawState, appendEvents } = require("./state-io");
const { projectState } = require("./state-io/projection");
const { stateAncestors } = require("./state-ancestry");
const { recordedStatusOf } = require("./effective-state/post-delivery");

const isValidSid = (v) => typeof v === "string" && SESSION_ID_VALID_RE.test(v);
const isDelivered = (state) => recordedStatusOf(state, "merge_to_main") === "complete";

function readStateOrNull(sid) {
  if (!isValidSid(sid)) return null;
  try {
    if (!readRawState(sid)) return null;
    return readState(sid);
  } catch (_) {
    return null;
  }
}

// readWorkflowAbort(sidOrState) -> the projected {origin, reason, downstream_session_id, recorded_at, seq} or null.
function readWorkflowAbort(sidOrState) {
  try {
    const state = typeof sidOrState === "string" ? readStateOrNull(sidOrState) : sidOrState;
    if (!state || typeof state !== "object" || !Array.isArray(state.events)) return null;
    return projectState(state).workflow_aborted || null;
  } catch (_) {
    return null;
  }
}

function isWorkflowAborted(sid) {
  return readWorkflowAbort(typeof sid === "string" ? sid : null) !== null;
}

// recordWorkflowAborted(targetSid, {reason, origin, downstreamSid}) -> {recorded, reason}.
function recordWorkflowAborted(targetSid, opts) {
  const o = opts || {};
  if (!isValidSid(targetSid)) return { recorded: false, reason: "invalid-session-id" };
  try {
    if (!readRawState(targetSid)) return { recorded: false, reason: "no-state" };
    let refusal = null;
    const event = { kind: "workflow_aborted", reason: o.reason, origin: o.origin, provenance: "declared" };
    if (o.origin !== "abort-sentinel") event.downstream_session_id = o.downstreamSid;
    appendEvents(targetSid, (_events, current) => {
      if (readWorkflowAbort(current)) refusal = "already-aborted";
      else if (isDelivered(current)) refusal = "delivered";
      return refusal ? [] : [event];
    });
    return refusal ? { recorded: false, reason: refusal } : { recorded: true, reason: null };
  } catch (e) {
    return { recorded: false, reason: `error: ${e && e.name ? e.name : "Error"}: ${e && e.message ? e.message : e}` };
  }
}

// selectAbortTargets(downstreamState) -> [{sid}] of every ancestor, oldest first, that has a state
// and is neither aborted nor delivered. The session-downstream itself is never selected; nothing is written.
function selectAbortTargets(downstreamState) {
  const self = downstreamState && downstreamState.session_id;
  const targets = [];
  for (const sid of stateAncestors(downstreamState)) {
    if (sid === self || targets.some((t) => t.sid === sid)) continue;
    const st = readStateOrNull(sid);
    if (!st || readWorkflowAbort(st) || isDelivered(st)) continue;
    targets.push({ sid });
  }
  return targets;
}

// An abort-sentinel abort no session-downstream has taken over yet: its worktree is still its own to clean.
const isUnclaimedSentinelAbort = (abort) => !!abort && abort.origin === "abort-sentinel" && abort.downstream_session_id === null;

// selectHandoverTargets(downstreamState) -> [{sid}] of every ancestor, oldest first, whose abort is an
// unclaimed abort-sentinel one. Nothing is written.
function selectHandoverTargets(downstreamState) {
  const self = downstreamState && downstreamState.session_id;
  const targets = [];
  for (const sid of stateAncestors(downstreamState)) {
    if (sid === self || targets.some((t) => t.sid === sid)) continue;
    if (isUnclaimedSentinelAbort(readWorkflowAbort(readStateOrNull(sid)))) targets.push({ sid });
  }
  return targets;
}

// recordAbortHandover(targetSid, {origin, downstreamSid}) -> {recorded, reason}: names the session-downstream that
// adopted an abort-sentinel-aborted session, so that session's next-step stops sending it to cleanup.
function recordAbortHandover(targetSid, opts) {
  const o = opts || {};
  if (!isValidSid(targetSid)) return { recorded: false, reason: "invalid-session-id" };
  try {
    if (!readRawState(targetSid)) return { recorded: false, reason: "no-state" };
    let refusal = null;
    const event = { kind: "workflow_abort_handover", downstream_session_id: o.downstreamSid, origin: o.origin, provenance: "declared" };
    appendEvents(targetSid, (_events, current) => {
      const abort = readWorkflowAbort(current);
      if (!abort) refusal = "not-aborted";
      else if (!isUnclaimedSentinelAbort(abort)) refusal = "already-handed-over";
      return refusal ? [] : [event];
    });
    return refusal ? { recorded: false, reason: refusal } : { recorded: true, reason: null };
  } catch (e) {
    return { recorded: false, reason: `error: ${e && e.name ? e.name : "Error"}: ${e && e.message ? e.message : e}` };
  }
}

// abortUpstreamsFor(downstreamSid, origin, reason) -> [{sid, recorded, reason, handover?}]: the one
// routine both scenario-B entry points run — abort every live session-upstream, then hand over every
// unclaimed abort-sentinel one. Each entry reports its own outcome; none undoes another.
function abortUpstreamsFor(downstreamSid, origin, reason) {
  const downstreamState = readState(downstreamSid);
  const aborts = selectAbortTargets(downstreamState).map(({ sid }) =>
    Object.assign({ sid }, recordWorkflowAborted(sid, { origin, downstreamSid, reason })));
  const handovers = selectHandoverTargets(downstreamState).map(({ sid }) =>
    Object.assign({ sid, handover: true }, recordAbortHandover(sid, { origin, downstreamSid })));
  return aborts.concat(handovers);
}

module.exports = {
  readWorkflowAbort, isWorkflowAborted, recordWorkflowAborted, selectAbortTargets,
  selectHandoverTargets, recordAbortHandover, abortUpstreamsFor,
};
