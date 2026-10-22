"use strict";
// Tests: hooks/workflow-state/inheritance/apply.js, hooks/workflow-state/completion-approval.js, hooks/workflow-state/record-step-verdict.js, hooks/workflow-mark/clarify-intent-complete-handler.js, bin/workflow/lib/next-step/verdict.js
// Tags: workflow, inheritance, approval-gate, plan-approval, resume-session, security, TL2, scope:issue-specific
// #2633-1: inheriting an upstream whose plan approval no longer verifies reverts that stage
// and every later non-pending step (cleanup included) to pending inside the one composed
// write, with an inherit_revert_reason annotation, instead of refusing the whole inheritance.
// The catch sites that still refuse a user's own completion name e.code and recoveryFor().
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const ROOT = path.resolve(__dirname, "..", "..");
const restore = isolate();
const SCRATCH = fs.mkdtempSync(path.join(os.tmpdir(), "f2633-revert-"));
fs.mkdirSync(path.join(SCRATCH, "no-transcripts"));
fs.mkdirSync(path.join(SCRATCH, "repo"));
gitInit(path.join(SCRATCH, "repo"));
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(SCRATCH, "no-transcripts");
process.env.CLAUDE_PROJECT_DIR = path.join(SCRATCH, "repo");
process.env.PLAN_SYNC_REMOTE_URL = "";
for (const k of ["CONFIRM_INTENT", "CONFIRM_OUTLINE", "CONFIRM_DETAIL"]) delete process.env[k];
process.chdir(path.join(SCRATCH, "repo"));

const req = (rel) => require(path.join(ROOT, rel));
const WS = req("hooks/workflow-state.js");
const CA = req("hooks/workflow-state/completion-approval.js");
const INH = req("hooks/workflow-state/inheritance");
const STEPS = WS.VALID_STEPS;
// #2529: a gated completion also needs a current glossary_check record; seeded right before
// each markStep so the cases keep judging the approval alone.
const { completeWithRecord } = require("../lib/glossary-check-record");
function completeStep(sid, step) {
  completeWithRecord(sid, step, path.join(SCRATCH, "repo"), WS.markStep);
}

// ---- reporting -------------------------------------------------------------
let failures = 0;
function check(name, ok, detail) {
  if (ok) { console.log(`PASS: ${name}`); return; }
  failures += 1;
  console.log(`FAIL: ${name} -- ${String(detail).replace(/\s+/g, " ").slice(0, 400)}`);
}

// ---- fixtures --------------------------------------------------------------
const SUFFIX = { clarify_intent: "intent", outline: "outline", detail: "detail" };
const BODY = {
  intent: "# Intent\n\n## Goal\n\nfixture goal\n\n## Issues\n\n- #1 fixture\n\n## Constraints\n\nnone\n",
  outline: "# Outline\n\n## Approach\n\nfixture approach\n\n## Issues\n\n- #1 fixture\n",
  detail: "# Detail\n\n## Steps\n\nfixture steps\n\n## Issues\n\n- #1 fixture\n",
};
let counter = 0;
const newSid = (tag) => `f2633-${tag}-${process.pid}-${++counter}`;
const planPath = (sid, step) => path.join(process.env.WORKFLOW_PLANS_DIR, `${sid}-${SUFFIX[step]}.md`);
const statePath = (sid) => path.join(process.env.WORKFLOW_STATE_DIR, `${sid}.json`);

function configRoot(lines) {
  const dir = path.join(SCRATCH, `cfg-${++counter}`);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, ".env"), lines.concat(["PLAN_SYNC_REMOTE_URL="]).join("\n") + "\n");
  process.env.AGENTS_MAIN_ROOT = dir;
  return dir;
}
const CFG_ON = ["CONFIRM_INTENT=on", "CONFIRM_OUTLINE=on", "CONFIRM_DETAIL=on"];

// A finished-through-merge upstream: everything before cleanup complete, cleanup skipped.
function upstreamSteps() {
  const steps = {};
  for (const s of STEPS) {
    if (s === "cleanup") steps[s] = "skipped";
    else if (s === "pre_final_report_gate" || s === "final_report") steps[s] = "pending";
    else steps[s] = "complete";
  }
  return steps;
}

// approvals: [{ step, source?, sha?: "impl"|null, omitAsid? }] — written raw, never through
// appendEvents, so a fixture can hold any record the code under test must cope with.
function writeRawState(sid, steps, approvals) {
  const at = new Date().toISOString();
  const events = [];
  for (const s of STEPS) {
    const st = steps[s];
    if (st && st !== "pending") events.push({ kind: "step_status", step: s, status: st, at, provenance: "observed", origin: "test-fixture" });
  }
  for (const a of approvals || []) {
    const source = a.source || "confirm-sentinel";
    const sha = source === "confirm-sentinel" ? (a.sha === undefined ? CA.computeArtifactSha(sid, a.step) : a.sha) : null;
    const ev = {
      kind: "plan_approval", step: a.step, source, reason: "fixture approval",
      artifact_sha256: sha, artifact_hash_status: sha ? "recorded" : "not-applicable",
      at, provenance: "declared", origin: "test-fixture",
    };
    if (!a.omitAsid) ev.artifact_session_id = sha ? (a.asid || sid) : null;
    events.push(ev);
  }
  events.forEach((e, i) => { e.seq = i + 1; });
  fs.writeFileSync(statePath(sid), JSON.stringify({
    version: 2, session_id: sid, created_at: at, workflow_type: "wf-code", events,
  }, null, 2));
}

// setup({ approved, stale, deletePlan, omitAsid, cfg }) -> { U, D }
function setup(tag, o) {
  const opts = o || {};
  configRoot(opts.cfg || CFG_ON);
  const U = newSid(`${tag}-up`);
  const D = newSid(`${tag}-down`);
  for (const step of Object.keys(SUFFIX)) fs.writeFileSync(planPath(U, step), BODY[SUFFIX[step]]);
  const approved = opts.approved || Object.keys(SUFFIX);
  writeRawState(U, upstreamSteps(), approved.map((step) => ({ step, omitAsid: !!opts.omitAsid })));
  if (opts.stale) {
    const text = fs.readFileSync(planPath(U, opts.stale), "utf8");
    // The intent digest excludes `## Issues`, so the edit lands outside it.
    fs.writeFileSync(planPath(U, opts.stale), text.replace(/fixture (goal|approach|steps)/, "edited after approval $1"));
  }
  if (opts.deletePlan) fs.unlinkSync(planPath(U, opts.deletePlan));
  writeRawState(D, {}, []);
  return { U, D };
}

function inherit(D, U, opts) {
  try {
    return { result: INH.applyInheritance(D, new Date().toISOString(), U, opts || {}), error: null };
  } catch (e) {
    return { result: null, error: e };
  }
}

const raw = (sid) => { try { return JSON.parse(fs.readFileSync(statePath(sid), "utf8")); } catch (_) { return null; } };
const evs = (sid) => ((raw(sid) || {}).events || []);
function statusIn(events, step) {
  const hit = events.filter((e) => e.kind === "step_status" && e.step === step).pop();
  return hit ? hit.status : "pending";
}
const rawStatus = (sid, step) => statusIn(evs(sid), step);
function annot(sid, step, key) {
  const hit = evs(sid).filter((e) => e.kind === "step_annotation" && e.step === step && e.key === key).pop();
  return hit ? hit.value : null;
}
const copySeq = (sid) => Number((raw(sid) || {}).upstream_copy_seq) || 0;
const appended = (sid) => evs(sid).filter((e) => Number(e.seq) > copySeq(sid));
const after = (step) => STEPS.slice(STEPS.indexOf(step) + 1);
const nonPendingAfter = (step) => after(step).filter((s) => upstreamSteps()[s] !== "pending");
const fmt = (r) => (r && Array.isArray(r.reverted_steps) ? r.reverted_steps.map((x) => (x && typeof x === "object"
  ? `${x.step}|${x.cause}|${x.code}|${x.trigger}` : String(x))) : null);
function expectedChain(trigger, code) {
  return [`${trigger}|approval|${code}|${trigger}`]
    .concat(nonPendingAfter(trigger).map((s) => `${s}|approval|follows-reverted-step|${trigger}`));
}

// Shared assertions for "trigger and every later non-pending step went back to pending".
function assertChain(label, D, r, trigger, code) {
  check(`${label}: inheritance succeeds`, r.error === null, r.error && r.error.message);
  check(`${label}: ${trigger} raw pending`, rawStatus(D, trigger) === "pending", rawStatus(D, trigger));
  check(`${label}: ${trigger} reason approval:${code}`, annot(D, trigger, "inherit_revert_reason") === `approval:${code}`,
    annot(D, trigger, "inherit_revert_reason"));
  const bad = nonPendingAfter(trigger).filter((s) => rawStatus(D, s) !== "pending"
    || annot(D, s, "inherit_revert_reason") !== `approval:follows:${trigger}`);
  check(`${label}: every later step (cleanup included) pending with approval:follows:${trigger}`, bad.length === 0,
    bad.map((s) => `${s}=${rawStatus(D, s)}/${annot(D, s, "inherit_revert_reason")}`).join(","));
  const before = STEPS.slice(0, STEPS.indexOf(trigger)).filter((s) => upstreamSteps()[s] === "complete");
  const lost = before.filter((s) => rawStatus(D, s) !== "complete");
  check(`${label}: steps before ${trigger} stay complete`, lost.length === 0, lost.join(","));
  check(`${label}: reverted_steps contract`, JSON.stringify(fmt(r.result)) === JSON.stringify(expectedChain(trigger, code)),
    JSON.stringify(fmt(r.result)));
}

// ---- cases -----------------------------------------------------------------
{
caseBegin("stale-outline-reverts-outline-and-followers", "hooks/workflow-state/inheritance/apply.js");
const { U, D } = setup("so", { stale: "outline" });
const r = inherit(D, U);
assertChain("stale outline", D, r, "outline", "artifact-hash-mismatch");
check("stale outline: clarify_intent stays complete", rawStatus(D, "clarify_intent") === "complete", rawStatus(D, "clarify_intent"));
const inh = (r.result && r.result.inherited_steps) || [];
check("stale outline: inherited_steps = still non-pending steps only",
  inh.includes("clarify_intent") && !inh.includes("outline") && !inh.includes("cleanup"), JSON.stringify(inh));
caseEnd();
}

{
caseBegin("stale-outline-revert-events-shape", "hooks/workflow-state/inheritance/apply.js");
const { U, D } = setup("se", { stale: "outline" });
inherit(D, U);
const app = appended(D);
const forStep = (s) => app.filter((e) => e.step === s && ["step_annotations_cleared", "step_status", "step_annotation"].includes(e.kind));
const ol = forStep("outline").map((e) => e.kind + (e.status ? ":" + e.status : "") + (e.key ? ":" + e.key : ""));
check("revert events: outline cleared -> pending -> inherit_revert_reason in order",
  JSON.stringify(ol) === JSON.stringify(["step_annotations_cleared", "step_status:pending", "step_annotation:inherit_revert_reason"]),
  JSON.stringify(ol));
const stamped = app.filter((e) => e.step === "outline");
check("revert events: provenance backfilled + origin session-inherit",
  stamped.length > 0 && stamped.every((e) => e.provenance === "backfilled" && e.origin === "session-inherit"),
  JSON.stringify(stamped.map((e) => [e.kind, e.provenance, e.origin])));
check("revert events: outline plan_approval_revoked in the same composition",
  app.some((e) => e.kind === "plan_approval_revoked" && e.step === "outline"), JSON.stringify(app.map((e) => e.kind)));
check("revert events: no #772 cleanup skipped event when an approval revert happened",
  !app.some((e) => e.kind === "step_status" && e.step === "cleanup" && e.status === "skipped"),
  JSON.stringify(app.filter((e) => e.step === "cleanup")));
const ev = CA.evaluateCompletionApproval(D, "outline", WS.readState(D));
check("revert events: the stale outline record no longer projects", ev.code === "no-approval-record", JSON.stringify(ev));
caseEnd();
}

{
caseBegin("stale-intent-reverts-everything-after", "hooks/workflow-state/inheritance/apply.js");
const { U, D } = setup("si", { stale: "clarify_intent" });
assertChain("stale intent", D, inherit(D, U), "clarify_intent", "artifact-hash-mismatch");
check("stale intent: workflow_init stays complete", rawStatus(D, "workflow_init") === "complete", rawStatus(D, "workflow_init"));
caseEnd();
}

{
caseBegin("stale-detail-reverts-detail-onward-only", "hooks/workflow-state/inheritance/apply.js");
const { U, D } = setup("sd", { stale: "detail" });
assertChain("stale detail", D, inherit(D, U), "detail", "artifact-hash-mismatch");
check("stale detail: outline stays complete", rawStatus(D, "outline") === "complete", rawStatus(D, "outline"));
caseEnd();
}

{
caseBegin("reapproval-after-revert-completes-outline", "hooks/workflow-state/inheritance/apply.js");
const { U, D } = setup("ra", { stale: "outline" });
inherit(D, U);
check("re-approve: outline reverted first", annot(D, "outline", "inherit_revert_reason") === "approval:artifact-hash-mismatch",
  annot(D, "outline", "inherit_revert_reason"));
let threw = null;
try {
  CA.recordPlanApproval(D, "outline", { source: "confirm-sentinel", reason: "re-approved downstream",
    artifactSha: CA.computeArtifactSha(U, "outline"), artifactHashStatus: "recorded", artifactSessionId: U });
  completeStep(D, "outline");
} catch (e) { threw = `${e.code || e.name}: ${e.message}`; }
check("re-approve: CONFIRM_OUTLINE re-approval lets markStep complete outline", threw === null, threw);
check("re-approve: outline complete on disk", rawStatus(D, "outline") === "complete", rawStatus(D, "outline"));
caseEnd();
}

{
caseBegin("confirm-outline-off-completes-after-revert", "hooks/workflow-state/inheritance/apply.js");
const { U, D } = setup("off", { stale: "outline", cfg: ["CONFIRM_INTENT=on", "CONFIRM_OUTLINE=off", "CONFIRM_DETAIL=on"] });
inherit(D, U);
check("off waiver: a stale confirm-sentinel record still reverts outline under CONFIRM_OUTLINE=off",
  annot(D, "outline", "inherit_revert_reason") === "approval:artifact-hash-mismatch", annot(D, "outline", "inherit_revert_reason"));
let threw = null;
try { completeStep(D, "outline"); } catch (e) { threw = `${e.code || e.name}: ${e.message}`; }
check("off waiver: after the record is revoked, markStep outline completes", threw === null, threw);
const last = evs(D).filter((e) => e.kind === "plan_approval" && e.step === "outline").pop();
check("off waiver: completion stamped confirm-flag-off", !!last && last.source === "confirm-flag-off", JSON.stringify(last));
caseEnd();
}

{
caseBegin("single-write-never-exposes-stale-complete", "hooks/workflow-state/inheritance/apply.js");
const { U, D } = setup("at", { stale: "outline" });
const target = path.resolve(statePath(D)).toLowerCase();
const snaps = [];
const orig = fs.renameSync;
fs.renameSync = function (src, dst) {
  if (path.resolve(String(dst)).toLowerCase() === target) {
    try { snaps.push(JSON.parse(fs.readFileSync(src, "utf8"))); } catch (_) { snaps.push(null); }
  }
  return orig.apply(this, arguments);
};
let r;
try { r = inherit(D, U); } finally { fs.renameSync = orig; }
check("atomic: inheritance succeeds", r.error === null, r.error && r.error.message);
check("atomic: exactly one write of the downstream state", snaps.length === 1, `writes=${snaps.length}`);
const s0 = snaps[0] && snaps[0].events ? snaps[0].events : [];
check("atomic: the one write already holds the copy (clarify_intent complete)", statusIn(s0, "clarify_intent") === "complete",
  statusIn(s0, "clarify_intent"));
check("atomic: no write ever shows the stale outline complete",
  snaps.length > 0 && snaps.every((s) => s && statusIn(s.events || [], "outline") === "pending"),
  JSON.stringify(snaps.map((s) => s && statusIn(s.events || [], "outline"))));
caseEnd();
}

{
caseBegin("no-record-confirm-on-reverts-with-no-approval-record", "hooks/workflow-state/inheritance/apply.js");
const { U, D } = setup("nr", { approved: ["clarify_intent", "detail"] });
assertChain("no record (on)", D, inherit(D, U), "outline", "no-approval-record");
caseEnd();
}

{
caseBegin("no-record-confirm-off-keeps-outline-complete", "hooks/workflow-state/inheritance/apply.js");
const { U, D } = setup("nf", { approved: ["clarify_intent", "detail"], cfg: ["CONFIRM_INTENT=on", "CONFIRM_OUTLINE=off", "CONFIRM_DETAIL=on"] });
const r = inherit(D, U);
check("no record (off): inheritance succeeds", r.error === null, r.error && r.error.message);
check("no record (off): outline copied complete", rawStatus(D, "outline") === "complete", rawStatus(D, "outline"));
check("no record (off): no approval revert", JSON.stringify(fmt(r.result)) === "[]", JSON.stringify(fmt(r.result)));
caseEnd();
}

{
caseBegin("intent-off-in-config-never-waives-clarify-intent", "hooks/workflow-state/inheritance/apply.js");
const { U, D } = setup("io", { approved: ["outline", "detail"], cfg: ["CONFIRM_INTENT=off", "CONFIRM_OUTLINE=on", "CONFIRM_DETAIL=on"] });
assertChain("intent off", D, inherit(D, U), "clarify_intent", "no-approval-record");
caseEnd();
}

{
caseBegin("all-approved-reverts-nothing-and-keeps-772-cleanup", "hooks/workflow-state/inheritance/apply.js");
const { U, D } = setup("ok");
const r = inherit(D, U);
check("all approved: inheritance succeeds", r.error === null, r.error && r.error.message);
check("all approved: reverted_steps empty", JSON.stringify(fmt(r.result)) === "[]", JSON.stringify(fmt(r.result)));
const lost = STEPS.filter((s) => upstreamSteps()[s] === "complete" && rawStatus(D, s) !== "complete");
check("all approved: every complete step copied complete", lost.length === 0, lost.join(","));
check("all approved: cleanup skipped (#772)", rawStatus(D, "cleanup") === "skipped", rawStatus(D, "cleanup"));
check("all approved: cleanup skip_reason inherited-from-prior-session",
  annot(D, "cleanup", "skip_reason") === "inherited-from-prior-session", annot(D, "cleanup", "skip_reason"));
check("all approved: no inherit_revert_reason anywhere",
  !evs(D).some((e) => e.kind === "step_annotation" && e.key === "inherit_revert_reason"), "found one");
check("all approved: description says nothing was held back",
  INH.describeGranularInheritance(r.result || {}).includes("Nothing was held back"), INH.describeGranularInheritance(r.result || {}));
caseEnd();
}

{
caseBegin("record-without-artifact-session-id-resolves-to-upstream", "hooks/workflow-state/inheritance/apply.js");
const { U, D } = setup("na", { omitAsid: true });
const r = inherit(D, U);
check("no artifact_session_id: inheritance succeeds", r.error === null, r.error && r.error.message);
check("no artifact_session_id: outline stays complete", rawStatus(D, "outline") === "complete", rawStatus(D, "outline"));
check("no artifact_session_id: nothing reverted", JSON.stringify(fmt(r.result)) === "[]", JSON.stringify(fmt(r.result)));
const rec = (WS.readState(D).plan_approvals || {}).outline || {};
check("no artifact_session_id: record keeps no artifact_session_id", !rec.artifact_session_id, JSON.stringify(rec));
const ev = CA.evaluateCompletionApproval(D, "outline", WS.readState(D));
check("no artifact_session_id: evaluation resolves to the upstream file", ev.approved === true, JSON.stringify(ev));
caseEnd();
}

{
caseBegin("unverifiable-upstream-artifact-reverts-with-retention-text", "hooks/workflow-state/inheritance/apply.js");
const { U, D } = setup("uv", { deletePlan: "outline" });
const r = inherit(D, U);
assertChain("deleted outline", D, r, "outline", "artifact-hash-unverifiable");
const text = r.result ? INH.describeGranularInheritance(r.result) : "";
check("deleted outline: description names the retention cause", text.includes("aged out of retention"), text);
caseEnd();
}

{
caseBegin("describe-approval-revert-wording", "hooks/workflow-state/inheritance/apply.js");
const text = INH.describeGranularInheritance({
  upstream_session_id: "up-sid", granularity: "full", inherited_steps: ["workflow_init", "clarify_intent"],
  reverted_steps: [
    { step: "outline", cause: "approval", code: "artifact-hash-mismatch", trigger: "outline" },
    { step: "detail", cause: "approval", code: "follows-reverted-step", trigger: "outline" },
  ],
});
check("describe approval: names the trigger and code",
  text.includes("Reverted to pending because the session upstream approval no longer verifies: outline (artifact-hash-mismatch)"), text);
check("describe approval: lists the followers", text.includes("also reset: detail"), text);
check("describe approval: gives the re-approval sentinel", text.includes("<<WORKFLOW_CONFIRM_OUTLINE:"), text);
check("describe approval: mismatch carries no retention note", !text.includes("aged out of retention"), text);
const unv = INH.describeGranularInheritance({
  granularity: "full", inherited_steps: [],
  reverted_steps: [{ step: "clarify_intent", cause: "approval", code: "artifact-hash-unverifiable", trigger: "clarify_intent" }],
});
check("describe unverifiable: retention note", unv.includes("aged out of retention"), unv);
check("describe unverifiable: intent sentinel", unv.includes("<<WORKFLOW_CONFIRM_INTENT:"), unv);
caseEnd();
}

{
caseBegin("describe-context-and-empty-wording", "hooks/workflow-state/inheritance/apply.js");
const ctx = INH.describeGranularInheritance({
  granularity: "context-independent-only", inherited_steps: ["clarify_intent"],
  reverted_steps: [{ step: "write_code", cause: "context", code: "worktree-dependent", trigger: null }],
});
check("describe context: keeps the evidence-does-not-travel wording", ctx.includes("evidence does not travel"), ctx);
check("describe context: names the step, not an object", ctx.includes("write_code") && !ctx.includes("[object Object]"), ctx);
const none = INH.describeGranularInheritance({ granularity: "full", inherited_steps: ["clarify_intent"], reverted_steps: [] });
check("describe empty: Nothing was held back", none.includes("Nothing was held back"), none);
caseEnd();
}

{
caseBegin("session-inherit-token-rejected-as-unknown", "hooks/workflow-state/completion-approval.js");
let code = null;
try { CA.assertSanctionedSource("session-inherit", "outline"); } catch (e) { code = e.code || e.name; }
check("sanctioned set: session-inherit is no longer a sanctioned token", code === "unknown-sanctioned-token", String(code));
let rec = null;
try {
  configRoot(CFG_ON);
  const sid = newSid("rec");
  writeRawState(sid, {}, []);
  CA.recordPlanApproval(sid, "outline", { source: "session-inherit", reason: "forged" });
  rec = "recorded";
} catch (e) { rec = e.code || e.name; }
check("sanctioned set: recordPlanApproval refuses a session-inherit source", rec === "unknown-sanctioned-token", String(rec));
caseEnd();
}

{
caseBegin("confirm-sentinel-token-still-sanctioned", "hooks/workflow-state/completion-approval.js");
let threw = null;
try { CA.assertSanctionedSource("confirm-sentinel", "outline"); } catch (e) { threw = e.code || e.name; }
check("sanctioned set: confirm-sentinel still accepted", threw === null, String(threw));
caseEnd();
}

{
caseBegin("legacy-session-inherit-record-still-reads-approved", "hooks/workflow-state/completion-approval.js");
configRoot(CFG_ON);
const sid = newSid("legacy");
writeRawState(sid, { workflow_init: "complete", outline: "complete" }, [{ step: "outline", source: "session-inherit" }]);
const ev = CA.evaluateCompletionApproval(sid, "outline", WS.readState(sid));
check("read compat: an existing session-inherit record stays hash-exempt", ev.approved === true, JSON.stringify(ev));
caseEnd();
}

// A downstream-like session whose <step> approval no longer matches its artifact.
function staleApprovalSession(tag, step, prior) {
  configRoot(CFG_ON);
  const sid = newSid(tag);
  for (const s of Object.keys(SUFFIX)) fs.writeFileSync(planPath(sid, s), BODY[SUFFIX[s]]);
  writeRawState(sid, prior, Object.keys(prior).filter((s) => SUFFIX[s] && prior[s] === "complete").map((s) => ({ step: s }))
    .concat([{ step, sha: "0".repeat(64) }]));
  return sid;
}

{
caseBegin("record-step-verdict-refusal-names-code-and-recovery", "hooks/workflow-state/record-step-verdict.js");
const { recordStepVerdict } = req("hooks/workflow-state/record-step-verdict.js");
const sid = staleApprovalSession("rsv", "outline", { workflow_init: "complete", clarify_intent: "complete", research: "complete" });
let res;
try { res = recordStepVerdict(sid, "outline", "complete", { gate: "advance" }); } catch (e) { res = { threw: e.message }; }
const msg = (res && res.message) || "";
check("record-step-verdict: still refused as unapproved", !!res && res.ok === false && res.kind === "unapproved", JSON.stringify(res));
check("record-step-verdict: message names e.code", msg.includes("artifact-hash-mismatch"), msg);
check("record-step-verdict: message carries recoveryFor(outline)", msg.includes(CA.recoveryFor("outline")), msg);
check("record-step-verdict: outline left pending", rawStatus(sid, "outline") === "pending", rawStatus(sid, "outline"));
caseEnd();
}

function clarifyHandle(sid) {
  const { handle } = req("hooks/workflow-mark/clarify-intent-complete-handler.js");
  const msgs = [];
  handle({ cmd: 'echo "<<WORKFLOW_CLARIFY_INTENT_COMPLETE>>"', sessionId: sid, pushMessage: (m) => msgs.push(m),
    signalFatal: (m) => msgs.push("FATAL:" + m) });
  return msgs.join("\n");
}

{
caseBegin("clarify-handler-hash-mismatch-message", "hooks/workflow-mark/clarify-intent-complete-handler.js");
const sid = staleApprovalSession("chm", "clarify_intent", { workflow_init: "complete" });
const msg = clarifyHandle(sid);
check("clarify handler (mismatch): names e.code", msg.includes("artifact-hash-mismatch"), msg);
check("clarify handler (mismatch): drops the false no-approval-on-record claim", !msg.includes("no approval is on record"), msg);
check("clarify handler (mismatch): carries recoveryFor(clarify_intent)", msg.includes(CA.recoveryFor("clarify_intent")), msg);
check("clarify handler (mismatch): clarify_intent left pending", rawStatus(sid, "clarify_intent") === "pending", rawStatus(sid, "clarify_intent"));
caseEnd();
}

{
caseBegin("clarify-handler-no-record-message", "hooks/workflow-mark/clarify-intent-complete-handler.js");
configRoot(CFG_ON);
const sid = newSid("cnr");
fs.writeFileSync(planPath(sid, "clarify_intent"), BODY.intent);
writeRawState(sid, { workflow_init: "complete" }, []);
const msg = clarifyHandle(sid);
check("clarify handler (no record): names e.code", msg.includes("no-approval-record"), msg);
check("clarify handler (no record): carries recoveryFor(clarify_intent)", msg.includes(CA.recoveryFor("clarify_intent")), msg);
caseEnd();
}

// persistResolutions only fires when an evidence-resolved markStep throws, so the child
// stubs markStep and the snapshot before verdict.js destructures them at load time.
const VERDICT_CHILD = [
  "const path = require('path');",
  "const [root, sid] = process.argv.slice(1);",
  "const ws = require(path.join(root, 'hooks/workflow-state.js'));",
  "const ca = require(path.join(root, 'hooks/workflow-state/completion-approval.js'));",
  "const es = require(path.join(root, 'hooks/workflow-state/effective-state.js'));",
  "ws.markStep = function () { throw new ca.UnapprovedCompletionError('outline', 'artifact-hash-mismatch', ca.recoveryFor('outline')); };",
  "es.reconcileEffectiveState = function () { const steps = {}; for (const s of ws.VALID_STEPS) steps[s] = { status: 'complete' };",
  "  return { steps, resolutions: [{ step: 'outline' }] }; };",
  "require(path.join(root, 'bin/workflow/lib/next-step/verdict.js')).computeVerdict(sid);",
].join("\n");

{
caseBegin("next-step-persist-resolutions-names-code-and-recovery", "bin/workflow/lib/next-step/verdict.js");
configRoot(CFG_ON);
const sid = newSid("nsv");
const all = {};
for (const s of STEPS) all[s] = "complete";
writeRawState(sid, all, []);
const r = spawnSync(process.execPath, ["-e", VERDICT_CHILD, ROOT, sid], { encoding: "utf8", timeout: 60000, env: process.env });
const out = (r.stdout || "") + (r.stderr || "");
check("next-step: the stubbed path reaches the unapproved-completion block", out.includes("unapproved-completion: outline"), out);
check("next-step: blocked output names e.code", out.includes("artifact-hash-mismatch"), out);
check("next-step: blocked output carries recoveryFor(outline)", out.includes(CA.recoveryFor("outline")), out);
caseEnd();
}

process.chdir(os.tmpdir());
restore();
fs.rmSync(SCRATCH, { recursive: true, force: true });
console.log(`\nResults: ${failures} failure(s)`);
process.exitCode = failures === 0 ? 0 : 1;
