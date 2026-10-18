"use strict";
// hooks/workflow-state/plan-artifact-owner.js — which session owns the plan artifact a session
// reads (#2633). A downstream session adopted via resume-session keeps reading the artifacts its
// upstream wrote (<upstream-sid>-<kind>.md), so every reader resolves the owner here instead of
// building <sid>-<kind>.md itself. First existing candidate wins:
//   own file -> live approval record -> upstream_session_id -> approval history (revoked records too).
// Every candidate sid is validated before it reaches a path; nothing found -> the own path, missing.

const fs = require("fs");
const { getPlansArtifactPath } = require("../lib/plans-artifact-registry");
const { SESSION_ID_VALID_RE } = require("./state-io/core");
const { stepForSuffix } = require("./plan-stage-table");

const validSid = (sid) => typeof sid === "string" && SESSION_ID_VALID_RE.test(sid);

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

// resolvePlanArtifactOwner(sessionId, kind, state?, opts?) -> { ownerSid, path, exists, via }.
// kind: intent | outline | detail. state defaults to readState(sessionId); opts.plansDir overrides
// the plans dir. Throws only on an invalid sessionId or an unknown kind.
function resolvePlanArtifactOwner(sessionId, kind, state, opts) {
  const step = stepForSuffix(kind);
  if (!step) throw new Error(`plan-artifact-owner: unknown plan artifact kind: ${JSON.stringify(kind)}`);
  if (!validSid(sessionId)) throw new Error(`plan-artifact-owner: invalid session id: ${JSON.stringify(sessionId)}`);
  const plansDir = opts && opts.plansDir;
  const pathOf = (sid) => getPlansArtifactPath(sid, kind, plansDir ? { plansDir } : undefined);

  const ownPath = pathOf(sessionId);
  if (fs.existsSync(ownPath)) return { ownerSid: sessionId, path: ownPath, exists: true, via: "own" };

  let st = state;
  if (st === undefined) {
    try { st = require("./state-io").readState(sessionId); } catch (_) { st = null; }
  }
  const candidates = [
    ["approval-record", approvalRecordOwner(st, step)],
    ["upstream", st ? st.upstream_session_id : null],
    ["approval-history", approvalHistoryOwner(st, step)],
  ];
  for (const [via, sid] of candidates) {
    if (!validSid(sid) || sid === sessionId) continue;
    const p = pathOf(sid);
    if (fs.existsSync(p)) return { ownerSid: sid, path: p, exists: true, via };
  }
  return { ownerSid: sessionId, path: ownPath, exists: false, via: "missing" };
}

module.exports = { resolvePlanArtifactOwner };
