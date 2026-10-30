"use strict";
// hooks/workflow-state/state-ancestry.js — the session chain of a state (#2748).
// stateAncestors(state) is the I/O-free ancestor list, oldest first. resolveFirstSid(sid, state?)
// answers the first generation of the session chain (first_session_id), which names both the
// progress file and the plan artifacts of every generation. Order: the state's first_session_id,
// then previous_session_ids[0], then a legacy sidecar root_sid (a self pin is ignored once the
// state has ancestors: a pre-#2748 session-downstream pinned itself), then — for a legacy state
// carrying upstream_session_id only — a bounded walk upstream. Nothing here writes.

const { SESSION_ID_VALID_RE } = require("./state-io/core");
const { readPressure } = require("../lib/progress-pressure-sidecar");

const MAX_LEGACY_WALK = 64;

const isValidSid = (v) => typeof v === "string" && SESSION_ID_VALID_RE.test(v);

function stateAncestors(state) {
  if (!state || typeof state !== "object") return [];
  if (Array.isArray(state.previous_session_ids)) return state.previous_session_ids.filter(isValidSid);
  if (isValidSid(state.upstream_session_id)) return [state.upstream_session_id];
  return [];
}

function dedupKeepFirst(ids) {
  return Array.from(new Set(ids));
}

// Called through the module object at call time (lazy: state-io -> ... -> this module never cycles).
function readStateOrNull(sid) {
  try { return require("./state-io").readState(sid); } catch (_) { return null; }
}

function pinnedSid(sid, state) {
  let p = null;
  try { p = readPressure(sid); } catch (_) { p = null; }
  const pinned = p && isValidSid(p.root_sid) ? p.root_sid : null;
  if (pinned === sid && stateAncestors(state).length > 0) return null;
  return pinned;
}

// decided(sid, state) -> the first_session_id one state answers without a walk, or null.
// A recorded ancestor list outranks a legacy pin: a pin that disagrees with it would send the
// migration's merge to the wrong progress file.
function decided(sid, state) {
  if (state && isValidSid(state.first_session_id)) return state.first_session_id;
  const valid = state && Array.isArray(state.previous_session_ids) ? state.previous_session_ids.filter(isValidSid) : [];
  if (valid.length) return valid[0];
  const pinned = pinnedSid(sid, state);
  if (pinned) return pinned;
  if (state && Array.isArray(state.previous_session_ids)) return sid;
  return null;
}

// legacyWalk(sid, upstream) — follows upstream_session_id for at most MAX_LEGACY_WALK hops. A cycle
// has no first generation, so every member and every tail into it agrees on its smallest sid.
function legacyWalk(sid, upstream) {
  const chain = [sid];
  let cur = upstream;
  for (let hop = 0; hop < MAX_LEGACY_WALK; hop++) {
    const at = chain.indexOf(cur);
    if (at >= 0) return chain.slice(at).sort()[0];
    const st = readStateOrNull(cur);
    if (!st) return cur;
    const answer = decided(cur, st);
    if (answer) return answer;
    if (!isValidSid(st.upstream_session_id)) return cur;
    chain.push(cur);
    cur = st.upstream_session_id;
  }
  return cur;
}

// resolveFirstSid(sid, state?) -> first_session_id; sid itself when nothing better is known or sid
// is invalid. state undefined -> readState(sid). Never throws.
function resolveFirstSid(sid, state) {
  if (!isValidSid(sid)) return sid;
  try {
    const st = state === undefined ? readStateOrNull(sid) : state;
    const answer = decided(sid, st);
    if (answer) return answer;
    if (st && isValidSid(st.upstream_session_id)) return legacyWalk(sid, st.upstream_session_id);
    return sid;
  } catch (_) {
    return sid;
  }
}

module.exports = { MAX_LEGACY_WALK, isValidSid, stateAncestors, dedupKeepFirst, resolveFirstSid };
