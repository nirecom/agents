"use strict";
// #3144 S2: who reviews a plan stage's pre-confirm audit run. The assigned PM of the issues the session
// closes reviews it instead of the supervisor-audit subagent; the destination is decided before the gate
// arms, so a run never waits on a PM it cannot name. Candidates come from pmCandidatesOf (S1-1), the same
// judgment the PM's verdict write meets, so the gate never sends a run to a PM whose write would be refused.

const path = require("path");

const ROOT = path.resolve(__dirname, "..", "..", "..", "..");
const W = () => require(path.join(ROOT, "hooks", "lib", "pm-review-writer"));
const PCA = () => require(path.join(ROOT, "hooks", "lib", "pre-confirm-audit"));
const SENTINEL = "WORKFLOW_PM_REVIEW_ACCEPTED";

// The user's `--audit-route` value of this process (cli.js sets it once, like wait-on-invoke's flags).
let requested;
const setRequestedRoute = (v) => { requested = v === undefined || v === null ? undefined : String(v); };
const requestedRoute = () => requested;

function findingsOf(sid) {
  try {
    const s = require(path.join(ROOT, "hooks", "lib", "supervisor-state-writer")).readState(sid);
    return (s && s.audit && Array.isArray(s.audit.findings)) ? s.audit.findings : [];
  } catch {
    return [];
  }
}

// The undecidable reason names local holders (pm-field-unset-held: <tags>); only its code reaches a hint.
const reasonCode = (r) => String(r || "").split(":")[0].replace(/[^A-Za-z0-9_-]/g, "") || "unknown";

// routeOf(sid, {runId}) -> {route:"pm", pms} | {route:"subagent"} | {route:"ask", reason, pms}.
// A run the user sent to the conventional audit (S2-4) is subagent without an owner lookup; undecidable
// owners are ask with no candidate, so a local holder is never offered (S2-1).
function routeOf(sid, opts) {
  const runId = opts && opts.runId;
  if (runId && W().isFallbackRun(findingsOf(sid), runId)) return { route: "subagent", fallback: true };
  let pc;
  try { pc = W().pmCandidatesOf(sid); } catch (e) { pc = { decided: false, cands: [], reason: `owner-error: ${e.message}` }; }
  if (!pc.decided) return { route: "ask", reason: reasonCode(pc.reason), pms: [] };
  if (pc.cands.length === 0) return { route: "subagent" };
  if (pc.cands.length === 1) return { route: "pm", pms: pc.cands.slice() };
  return { route: "ask", reason: "several-assigned-pms", pms: pc.cands.slice() };
}

const safe = (s) => String(s == null ? "" : s).replace(/[^A-Za-z0-9_.:-]/g, "");

// askHint(step, reason, pms) -> the audit-wait hint of the ask route: nothing is armed; the user picks.
function askHint(step, reason, pms) {
  const choices = (pms || []).map((p) => `the assigned PM ${safe(p.tag)} ${safe(p.session_id)} (rerun next-step --gate --audit-route pm:${safe(p.tag)})`);
  const rest = pms && pms.length > 0 ? "" : ", or waiting and rerunning next-step --gate later";
  return `The destination of the plan stage audit is not decided (${safe(reason)}), so no audit is armed yet. ` +
    "Ask the user where the audit goes and rerun the gate on the chosen route: " +
    choices.concat([`the conventional supervisor audit (the user runs echo <<${SENTINEL}: ${safe(step)} <reason>>>)`]).join(", or ") +
    rest + ". Do not ask for plan approval and do not emit the completion sentinel yet.";
}

// pickRequested(sid, value) -> {pm} | {refused}: `pm` or `pm:<tag>` among the current decided candidates.
function pickRequested(sid, value) {
  const m = /^pm(?::([A-Za-z0-9_.-]+))?$/.exec(value);
  if (!m) return { refused: "audit-route-invalid", pms: [] };
  const r = routeOf(sid, { runId: null });
  const cands = r.route === "subagent" ? [] : r.pms;
  const pm = m[1] ? cands.find((c) => c.tag === m[1]) : (cands.length === 1 ? cands[0] : null);
  return pm ? { pm } : { refused: r.route === "ask" && cands.length === 0 ? r.reason : "audit-route-not-a-candidate", pms: cands };
}

// decideArm(sid, step, ctx, j) -> {route, arm, pm} | {route:"ask", reason, pms, reuse?} | {released}: the arm
// branch of decideAuditGate. A run is reused only when its destination is a current candidate; any other
// in-flight run is replaced by a new counted run (S2-2); at the cap nothing is armed and the stage's
// in-flight run is released (S2-3), so the caller re-judges into the cap procedure.
function decideArm(sid, step, ctx, j) {
  const inFlightId = j && j.inFlight ? j.runId : null;
  const armFor = (pm, force) => {
    const arm = PCA().armStage(sid, step, ctx, { dest: pm.session_id, force }) || {};
    return arm.reason === "cap-reached" ? { released: true } : { route: "pm", arm, pm };
  };
  const value = requestedRoute();
  if (value !== undefined) {
    const p = pickRequested(sid, value);
    if (!p.pm) return { route: "ask", reason: p.refused, pms: p.pms };
    return armFor(p.pm, Boolean(inFlightId));
  }
  const r = routeOf(sid, { runId: inFlightId });
  const dest = inFlightId ? W().destOfRun(findingsOf(sid), inFlightId) : null;
  const current = r.route === "subagent" ? null : r.pms.find((c) => c.session_id === dest) || null;
  if (r.route === "ask") {
    return current ? { route: "pm", arm: { ok: true, audit_run_id: inFlightId, run_id: inFlightId, reused: true }, pm: current }
      : { route: "ask", reason: r.reason, pms: r.pms };
  }
  if (r.route === "subagent") {
    const arm = PCA().armStage(sid, step, ctx) || {};
    return { route: "subagent", arm };
  }
  return armFor(r.pms[0], Boolean(inFlightId) && !current);
}

module.exports = { routeOf, decideArm, askHint, setRequestedRoute, requestedRoute, SENTINEL };
