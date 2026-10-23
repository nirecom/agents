"use strict";
// hooks/workflow-state/plan-artifact-owner.js — SSOT for which session owns the plan artifact a
// session reads AND writes (#2633, #2631). A session adopted via resume-session reads and writes
// only its root owner's <root-sid>-<kind>.md, never its own; every reader/writer resolves it here.
// The chain walks upstream_session_id (state of each node, visited set, max depth 10; an invalid
// sid stops it). Candidates (valid sid, not the own sid), first existing file wins: approval record
// -> root -> intermediate nodes from the root toward the direct upstream -> direct upstream ->
// approval history. A declared owner without any file -> the root's path (else the first candidate)
// as the write target (exists:false, "owner-missing"). No declared owner (non-resumed session, or
// state === null) -> the own path ("own" when it exists, else "missing").

const fs = require("fs");
const { getPlansArtifactPath } = require("../lib/plans-artifact-registry");
const { SESSION_ID_VALID_RE } = require("./state-io/core");
const { stepForSuffix } = require("./plan-stage-table");

const validSid = (sid) => typeof sid === "string" && SESSION_ID_VALID_RE.test(sid);
const MAX_CHAIN_DEPTH = 10;

function approvalRecordOwner(state, step) {
  const pa = (state && (state.plan_approvals || (state.current && state.current.plan_approvals))) || null;
  const rec = pa && typeof pa === "object" ? pa[step] : null;
  return rec && typeof rec === "object" ? rec.artifact_session_id : null;
}

function approvalHistoryOwner(state, step) {
  const events = state && Array.isArray(state.events) ? state.events : [];
  for (let i = events.length - 1; i >= 0; i--) {
    const e = events[i];
    if (e && e.kind === "plan_approval" && e.step === step && validSid(e.artifact_session_id)) {
      return e.artifact_session_id;
    }
  }
  return null;
}

// upstreamChain(sessionId, state) -> [direct upstream, ..., root]; [] for a non-resumed session.
function upstreamChain(sessionId, state) {
  const chain = [];
  const visited = new Set([sessionId]);
  let cur = state ? state.upstream_session_id : null;
  while (validSid(cur) && !visited.has(cur) && chain.length < MAX_CHAIN_DEPTH) {
    chain.push(cur);
    visited.add(cur);
    let next = null;
    try { next = require("./state-io").readState(cur); } catch (_) { next = null; }
    cur = next ? next.upstream_session_id : null;
  }
  return chain;
}

function chainVia(sid, chain) {
  if (sid === chain[0]) return "upstream";
  return sid === chain[chain.length - 1] ? "root" : "upstream-chain";
}

// resolvePlanArtifactOwner(sessionId, kind, state?, opts?) -> { ownerSid, path, exists, via }.
// kind: intent | outline | detail. state defaults to readState(sessionId). opts.plansDir overrides
// the plans dir. Throws only on an invalid sessionId or an unknown kind.
function resolvePlanArtifactOwner(sessionId, kind, state, opts) {
  const step = stepForSuffix(kind);
  if (!step) throw new Error(`plan-artifact-owner: unknown plan artifact kind: ${JSON.stringify(kind)}`);
  if (!validSid(sessionId)) throw new Error(`plan-artifact-owner: invalid session id: ${JSON.stringify(sessionId)}`);
  const plansDir = opts && opts.plansDir;
  const pathOf = (sid) => getPlansArtifactPath(sid, kind, plansDir ? { plansDir } : undefined);

  let st = state;
  if (st === undefined) {
    try { st = require("./state-io").readState(sessionId); } catch (_) { st = null; }
  }
  const chain = st ? upstreamChain(sessionId, st) : [];
  const candidates = [
    ["approval-record", approvalRecordOwner(st, step)],
    ...chain.slice().reverse().map((sid) => [chainVia(sid, chain), sid]),
    ["approval-history", approvalHistoryOwner(st, step)],
  ].filter(([, sid]) => validSid(sid) && sid !== sessionId);

  for (const [via, sid] of candidates) {
    const p = pathOf(sid);
    if (fs.existsSync(p)) return { ownerSid: sid, path: p, exists: true, via };
  }

  if (candidates.length > 0) {
    const ownerSid = chain.length > 0 ? chain[chain.length - 1] : candidates[0][1];
    return { ownerSid, path: pathOf(ownerSid), exists: false, via: "owner-missing" };
  }
  const ownPath = pathOf(sessionId);
  const ownExists = fs.existsSync(ownPath);
  return { ownerSid: sessionId, path: ownPath, exists: ownExists, via: ownExists ? "own" : "missing" };
}

module.exports = { resolvePlanArtifactOwner };
