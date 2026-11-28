"use strict";
// #3144 S2: who reviews a plan stage's pre-confirm audit run. The assigned PM of the issues the session
// closes reviews it instead of the supervisor-audit subagent; the destination is decided before the gate
// arms, so a run never waits on a PM it cannot name. Candidates come from pmCandidatesOf (S1-1), the same
// judgment the PM's verdict write meets, so the gate never sends a run to a PM whose write would be refused.

const path = require("path");

const ROOT = path.resolve(__dirname, "..", "..", "..", "..");
const W = () => require(path.join(ROOT, "hooks", "lib", "pm-review-writer"));
const PCA = () => require(path.join(ROOT, "hooks", "lib", "pre-confirm-audit"));
const FF = () => require(path.join(ROOT, "bin", "lib", "forge-failure"));
const { CONVENTIONAL_AUDIT_CHOSEN_NAME } = require(path.join(ROOT, "hooks", "lib", "sentinel-patterns"));
// The gate runs outside the hook budget, so its owner lookup waits longer than the hooks' OWNER_TIMEOUT_MS.
const GATE_OWNER_TIMEOUT_MS = 4000;

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

// routeOf(sid, {runId}) -> {route:"pm", pms} | {route:"subagent"} | {route:"ask", reason, pms, failure}.
// A run the user sent to the conventional audit (S2-4) is subagent without an owner lookup. Undecidable owners
// are ask offering only the decided candidates, so a local holder is never offered (S2-1); failure is the
// reason code of a lookup that failed as a whole, null on a partial failure.
function routeOf(sid, opts) {
  const runId = opts && opts.runId;
  if (runId && W().isFallbackRun(findingsOf(sid), runId)) return { route: "subagent", fallback: true };
  let pc;
  try { pc = W().pmCandidatesOf(sid, { timeoutMs: GATE_OWNER_TIMEOUT_MS }); } catch { pc = { decided: false, cands: [], reason: "owner-error" }; }
  if (!pc.decided) {
    const reason = reasonCode(pc.reason);
    return { route: "ask", reason, pms: (pc.cands || []).slice(), failure: reason === "owner-undecidable" ? null : reason };
  }
  if (pc.cands.length === 0) return { route: "subagent" };
  if (pc.cands.length === 1) return { route: "pm", pms: pc.cands.slice() };
  return { route: "ask", reason: "several-assigned-pms", pms: pc.cands.slice() };
}

const safe = (s) => String(s == null ? "" : s).replace(/[^A-Za-z0-9_.:-]/g, "");

const FORGE_CLASSES = () => [FF().TIMEOUT, FF().BUDGET_EXHAUSTED, FF().SPAWN_FAILED];

// askHint(step, reason, pms, failure?) -> the audit-wait hint of the ask route: nothing is armed; the user picks.
// Only the forge time-out classes carry a next action; any other failure shows its reason code alone.
function askHint(step, reason, pms, failure) {
  const action = failure && FORGE_CLASSES().includes(failure) ? ` ${FF().nextActionOf(failure)}` : "";
  const choices = (pms || []).map((p) => `the assigned PM ${safe(p.tag)} ${safe(p.session_id)} (rerun next-step --gate --audit-route pm:${safe(p.tag)})`);
  choices.push(`the conventional supervisor audit (you run echo "<<${CONVENTIONAL_AUDIT_CHOSEN_NAME}: ${safe(step)} <reason>>>" via Bash and the user approves it in the permission dialog)`);
  if (reason !== "several-assigned-pms") choices.push("waiting and rerunning next-step --gate later");
  return `The destination of the plan stage audit is not decided (${safe(reason)}), so no audit is armed yet.${action} ` +
    "Ask the user where the audit goes and rerun the gate on the chosen route: " +
    choices.join(", or ") + ". Do not ask for plan approval and do not emit the completion sentinel yet.";
}

// pickRequested(sid, value) -> {pm} | {refused}: `pm` or `pm:<tag>` among the current decided candidates.
function pickRequested(sid, value) {
  const m = /^pm(?::([A-Za-z0-9_.-]+))?$/.exec(value);
  if (!m) return { refused: "audit-route-invalid", pms: [] };
  const r = routeOf(sid, { runId: null });
  const cands = r.route === "subagent" ? [] : r.pms;
  const pm = m[1] ? cands.find((c) => c.tag === m[1]) : (cands.length === 1 ? cands[0] : null);
  if (pm) return { pm };
  const whole = r.route === "ask" && cands.length === 0;
  return { refused: whole ? r.reason : "audit-route-not-a-candidate", pms: cands, failure: whole ? r.failure : null };
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
    if (!p.pm) return { route: "ask", reason: p.refused, pms: p.pms, failure: p.failure };
    return armFor(p.pm, Boolean(inFlightId));
  }
  const r = routeOf(sid, { runId: inFlightId });
  const dest = inFlightId ? W().destOfRun(findingsOf(sid), inFlightId) : null;
  const current = r.route === "subagent" ? null : r.pms.find((c) => c.session_id === dest) || null;
  if (r.route === "ask") {
    return current ? { route: "pm", arm: { ok: true, audit_run_id: inFlightId, run_id: inFlightId, reused: true }, pm: current }
      : { route: "ask", reason: r.reason, pms: r.pms, failure: r.failure };
  }
  if (r.route === "subagent") {
    const arm = PCA().armStage(sid, step, ctx) || {};
    return { route: "subagent", arm };
  }
  return armFor(r.pms[0], Boolean(inFlightId) && !current);
}

module.exports = { routeOf, decideArm, askHint, setRequestedRoute, requestedRoute, GATE_OWNER_TIMEOUT_MS };
