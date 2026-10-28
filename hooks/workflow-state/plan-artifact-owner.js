"use strict";
// hooks/workflow-state/plan-artifact-owner.js — the one path every generation of a session chain
// reads and writes a plan artifact at (#2633, #2748). Plan artifacts are named after
// first_session_id (hooks/workflow-state/state-ancestry.js), so a session-downstream adopted via
// resume-session keeps reading and writing <first_session_id>-<kind>.md, however many generations
// later. No other name is a candidate: the own sid, the approval record and the upstream all
// point at that one file once the session chain is migrated (CPR-SSOT).

const fs = require("fs");
const { getPlansArtifactPath } = require("../lib/plans-artifact-registry");
const { SESSION_ID_VALID_RE } = require("./state-io/core");
const { stepForSuffix } = require("./plan-stage-table");
const { resolveFirstSid } = require("./state-ancestry");

const validSid = (sid) => typeof sid === "string" && SESSION_ID_VALID_RE.test(sid);

// resolvePlanArtifactOwner(sessionId, kind, state?, opts?) -> { ownerSid, path, exists, via }.
// kind: intent | outline | detail. state defaults to readState(sessionId); an explicit state (the
// copy under evaluation during inheritance) is used as given. opts.plansDir overrides the plans dir.
// via: "own" | "first-session" | "missing". Throws only on an invalid sessionId or an unknown kind.
function resolvePlanArtifactOwner(sessionId, kind, state, opts) {
  const step = stepForSuffix(kind);
  if (!step) throw new Error(`plan-artifact-owner: unknown plan artifact kind: ${JSON.stringify(kind)}`);
  if (!validSid(sessionId)) throw new Error(`plan-artifact-owner: invalid session id: ${JSON.stringify(sessionId)}`);
  const plansDir = opts && opts.plansDir;
  const resolved = resolveFirstSid(sessionId, state);
  const ownerSid = validSid(resolved) ? resolved : sessionId;
  const p = getPlansArtifactPath(ownerSid, kind, plansDir ? { plansDir } : undefined);
  const exists = fs.existsSync(p);
  const via = !exists ? "missing" : ownerSid === sessionId ? "own" : "first-session";
  return { ownerSid, path: p, exists, via };
}

module.exports = { resolvePlanArtifactOwner };
