"use strict";
// Shared #3144 fixture: a workflow session (the target) whose intent closes stubbed issues, its supervisor
// audit runs, the destination / fallback findings and the pm-review rows, all made from the S1-1 constants
// of hooks/lib/pm-review-writer.js and written straight into the state files (no C2-C4 writer is used).
// The caller runs isolate() before the first helper call and installs the owner stub (owner-stub-preload.js).
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "..", "..", "..");
const PRELOAD = path.join(__dirname, "owner-stub-preload.js");
const rel = (p) => path.join(ROOT, p);
const FP = { a: "a".repeat(40), b: "b".repeat(40), c: "c".repeat(40) };

// mod(p) -> a module of the checkout; a missing one fails the case with a clear reason.
function mod(p) {
  try { return require(rel(p)); } catch (e) { throw new Error(`${p} could not be loaded (not implemented yet?): ${e.message}`); }
}
const W = () => mod("hooks/lib/pm-review-writer.js");
const io = () => require(rel("hooks/workflow-state/state-io"));
const sup = () => require(rel("hooks/lib/supervisor-state-writer"));
const shared = () => require(rel("hooks/lib/supervisor-state-writer/shared"));
const ctlDir = (sid) => require(rel("hooks/workflow-state/state-io/control-dir")).getSessionControlDir(sid);
const recPath = (sid) => path.join(ctlDir(sid), "pm-review-review-rounds.jsonl");
const uuid = () => crypto.randomUUID();

// make(tmp) -> helpers bound to one owner-stub file under tmp.
function make(tmp) {
  const stubFile = path.join(tmp, "owner-stub.json");
  const ownerLog = path.join(tmp, "owner-log.jsonl");
  fs.writeFileSync(stubFile, "{}");
  const env = () => ({ PM3144_OWNER_STUB: stubFile, PM3144_OWNER_LOG: ownerLog });
  Object.assign(process.env, env());

  // pm(tag) -> {tag, session_id} of a fresh PM session.
  const pm = (tag) => ({ tag, session_id: uuid() });
  // setOwners({no: answer}, {no: [holders]}) -> the stub answers; answer is a pm, "timeout", "absent", "throw", null.
  function setOwners(map, holders) {
    const cfg = { __holders: holders || {} };
    for (const [n, a] of Object.entries(map)) {
      if (a === "timeout") cfg[n] = { ok: false, reason: "timeout" };
      else if (a === "absent") cfg[n] = { ok: true, owner: null, fieldAbsent: true };
      else if (a === "throw") cfg[n] = { throw: "fixture owner lookup exception" };
      else if (a === null) cfg[n] = { ok: true, owner: null };
      else cfg[n] = { ok: true, owner: { tag: a.tag, session_id: a.session_id } };
    }
    fs.writeFileSync(stubFile, JSON.stringify(cfg));
  }
  const ownerCalls = () => {
    try { return fs.readFileSync(ownerLog, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)); } catch (_) { return []; }
  };
  const clearLog = () => { try { fs.rmSync(ownerLog, { force: true }); } catch (_) { /* absent */ } };

  // target(issueNos, opts) -> a workflow session id whose intent closes owner/repo#<n> for each n.
  function target(issueNos, opts) {
    const sid = uuid();
    const plans = process.env.WORKFLOW_PLANS_DIR;
    fs.mkdirSync(plans, { recursive: true });
    const refs = issueNos.map((n) => `- example-owner/example-repo#${n} fixture`).join("\n");
    fs.writeFileSync(path.join(plans, `${sid}-intent.md`), `# intent\n\n## Issues\n\n${refs}\n\n## Goal\n\nfixture\n`);
    fs.writeFileSync(path.join(plans, `${sid}-outline.md`), "# outline\n\nfixture outline body\n");
    io().writeState(sid, io().createInitialState(sid, { cwd: (opts && opts.cwd) || tmp, git_branch: "fixture" }));
    io().markStep(sid, "workflow_init", "complete");
    return sid;
  }

  // arm(sid, cause) -> a pending run id (TR2 for a pre-confirm run, TR4 otherwise).
  function arm(sid, cause) {
    const c = cause || "pre-confirm:outline";
    const r = sup().armAuditRun(sid, {
      tr_ids: [c.startsWith("pre-confirm:") ? "TR2" : "TR4"], cause: c,
      plans_dir: process.env.WORKFLOW_PLANS_DIR, plan_session_id: sid, launch_shown: true, supersede_unsettled: true,
    });
    if (!r || !r.ok || !r.audit_run_id) throw new Error("fixture arm failed: " + JSON.stringify(r));
    return r.audit_run_id;
  }
  const settle = (sid, runId) => sup().finalizeAuditRun(sid, { audit_run_id: runId, verdict: "CONTINUE", verdict_summary: "fixture" });
  // addFindings(sid, findings) -> pushes findings into audit.findings of the supervisor state.
  function addFindings(sid, findings) {
    const p = shared().getStatePath(sid, { forWrite: true });
    const st = sup().readState(sid);
    st.audit.findings = (Array.isArray(st.audit.findings) ? st.audit.findings : []).concat(findings);
    shared().writeAtomic(p, st);
  }
  const dest = (sid, runId, pmSid) => addFindings(sid, [W().destFinding(runId, pmSid)]);
  const fallback = (sid, runId) => addFindings(sid, [W().fallbackFinding(runId)]);
  const findings = (sid) => { const st = sup().readState(sid); return (st && st.audit && st.audit.findings) || []; };

  // pm-review rows, in the S1-4 shape; written directly so C1 does not need the CLI.
  const reqRow = (round, pmSid, pr, fp) => ({ counter_round: round, verdict: "REQUESTED", source: W().SOURCE_REQUEST_PREFIX + pmSid, run_id: W().PR_RUN_PREFIX + pr, fingerprint: fp });
  const pmRow = (round, verdict, writerSid, pr, fp) => ({ counter_round: round, verdict, source: W().SOURCE_PM, writer_sid: writerSid, run_id: W().PR_RUN_PREFIX + pr, fingerprint: fp });
  const userRow = (round, pr, fp, unconfirmed) => ({ counter_round: round, verdict: "ACCEPTED", source: unconfirmed ? W().SOURCE_USER_PR_UNCONFIRMED : W().SOURCE_USER, run_id: W().PR_RUN_PREFIX + pr, fingerprint: fp });
  function addRows(sid, rows) {
    fs.mkdirSync(ctlDir(sid), { recursive: true });
    const have = readRows(sid).length;
    const at = new Date().toISOString();
    const text = rows.map((r, i) => JSON.stringify(Object.assign({ format: "pm-review", loop_cycle: 1, row_no: have + i + 1, state_sid: sid, at }, r))).join("\n") + "\n";
    fs.appendFileSync(recPath(sid), text);
  }
  function readRows(sid) {
    let t = "";
    try { t = fs.readFileSync(recPath(sid), "utf8"); } catch (_) { return []; }
    return t.split(/\r?\n/).filter(Boolean).map((l) => { try { return JSON.parse(l); } catch (_) { return null; } }).filter(Boolean);
  }

  return { stubFile, ownerLog, env, pm, setOwners, ownerCalls, clearLog, target, arm, settle, addFindings, dest, fallback,
    findings, reqRow, pmRow, userRow, addRows, readRows };
}

module.exports = { ROOT, PRELOAD, FP, rel, mod, W, io, sup, ctlDir, recPath, uuid, make };
