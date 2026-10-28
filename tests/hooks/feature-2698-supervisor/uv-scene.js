"use strict";
// Scene helpers for the #2597 / #2521 / #2534 reviewed-verdict-acceptance suites: the USER_VERIFIED
// gate (feature-2698-alert-audit-sequence.js T-UV) and the pre-merge backstop
// (feature-2597-supervisor-check-acceptance.js T-PM). Builds on fixture.js: every gate, the
// freshness computation and the sentinel handler run in a child with the scene env pinned.

const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const X = require("./fixture");
const S = require("./audit-scene");

const SENT = "WORKFLOW_SUPERVISOR_VERDICT_ACCEPTED";
const REASON = "reviewed the findings with the user; accepted as is";
const now = () => new Date().toISOString();

// make(ROOT) -> the helper set bound to one test root (scenes and repos are created under it).
function make(ROOT) {
  let seq = 0;
  // scene(tag) -> {dir, sid} without workflow seeding: both gates read only supervisor state and plans.
  const scene = (tag) => ({ dir: X.sceneDir(ROOT, `${tag}-${++seq}`), sid: `uv${tag.replace(/[^A-Za-z0-9]/g, "")}${seq}` });
  // gitRepo() -> a repo on a feature branch off main, so the code side (input_version) is computable.
  function gitRepo() {
    const d = path.join(ROOT, `repo-${++seq}`);
    fs.mkdirSync(d, { recursive: true });
    const g = (...a) => {
      const r = spawnSync("git", a, { cwd: d, encoding: "utf8" });
      assert.strictEqual(r.status, 0, `git ${a.join(" ")}: ${r.stderr}`);
    };
    g("init", "-q", "-b", "main");
    for (const [k, v] of [["core.hooksPath", "/dev/null"], ["core.autocrlf", "false"], ["commit.gpgsign", "false"],
      ["user.email", "t@example.invalid"], ["user.name", "tester"]]) g("config", k, v);
    fs.writeFileSync(path.join(d, "seed.txt"), "seed\n");
    g("add", "-A");
    g("commit", "-q", "-m", "seed");
    g("checkout", "-q", "-b", "feature/uv");
    return d.replace(/\\/g, "/");
  }
  return { scene, gitRepo };
}

// writePlans(s, names, tag) — the named plan artifacts for the scene session (plans dir = scene dir).
const writePlans = (s, names, tag = "v1") => {
  for (const n of names) fs.writeFileSync(path.join(s.dir, `${s.sid}-${n}.md`), `# ${n}\n${tag}\n`);
};
// fresh(s, cwd) -> computeFreshnessKey for the scene, as both gates compute it.
const fresh = (s, cwd) => JSON.parse(X.nodeEval(s.dir, `
const fp = require(${JSON.stringify(X.lib("hooks/lib/diff-fingerprint.js"))});
process.stdout.write(JSON.stringify(fp.computeFreshnessKey(process.argv[3], process.env.WORKFLOW_PLANS_DIR, process.argv[2])));`,
[s.sid, cwd]));
// run(id, verdict, f, tr) -> a terminal ledger entry recording f the way armCore does.
const run = (id, verdict, f, tr = "TR5") => ({
  id, outcome: "terminal", cause: "step-complete:user_verification", tr_ids: [tr], verdict,
  freshness_key: f.freshness_key, artifact_keys: f.artifact_keys, trigger_input_keys: { [tr]: f.input_version },
  sub_checks: ["recurrence-patterns"], input_key: { "recurrence-patterns": f.freshness_key }, terminal_at: now(),
});
// seedRuns(s, runs, extra) — a settled ledger whose last entry is the last terminal run.
const seedRuns = (s, runs, extra = {}) => {
  const last = runs[runs.length - 1];
  X.seedSup(s.dir, s.sid, { audit: Object.assign({ ledger: runs, last_terminal_run_id: last.id,
    audit_verdict_summary: last.verdict, audit_phase: "done", audit_run_id: last.id,
    run_seq: Number(last.id.slice(4)) }, extra) });
};
// record(runId, verdict, f) -> an acceptance record in the shape the recorder pins (run_id, verdict,
// freshness_key, artifact_keys, trigger_key), for cases the handler refuses to record.
const record = (runId, verdict, f) => ({ run_id: runId, verdict, freshness_key: f.freshness_key,
  artifact_keys: f.artifact_keys, trigger_key: f.input_version, reason: REASON, actor: "t", recorded_at: now() });
// tr5At(s, cwd) -> the reason checkUserVerifiedAudit hands to blockFn ("APPROVE" on approve).
function tr5At(s, cwd) {
  return JSON.parse(X.nodeEval(s.dir, `
process.env.WORKFLOW_SESSION_ID = process.argv[2];
const m = require(${JSON.stringify(X.lib("hooks/workflow-gate/user-verified-audit.js"))});
let got = null;
m.checkUserVerifiedAudit(process.argv[2], process.argv[3], {
  approveFn: () => { got = "APPROVE"; }, blockFn: (r) => { got = r; },
});
process.stdout.write(JSON.stringify(got));`, [s.sid, cwd]));
}
// preMerge(s, cwd) -> "PASS" when checkSupervisorPreMerge lets the merge through, else the deny
// reason; "NOT-AUTHORITATIVE" when it found no supervisor state.
function preMerge(s, cwd) {
  return JSON.parse(X.nodeEval(s.dir, `
const m = require(${JSON.stringify(X.lib("hooks/workflow-gate/supervisor-check.js"))});
let denied = null;
const r = m.checkSupervisorPreMerge(process.argv[2], "squash", process.argv[3], { blockFn: (x) => { denied = String(x); } });
process.stdout.write(JSON.stringify(denied !== null ? denied : (r && r.authoritative ? "PASS" : "NOT-AUTHORITATIVE")));`,
  [s.sid, cwd]));
}
// accept(s, runId) -> the messages of the real sentinel handler recording the acceptance.
function accept(s, runId) {
  return JSON.parse(X.nodeEval(s.dir, `
const h = require(${JSON.stringify(X.lib("hooks/workflow-mark/supervisor-block-override-handler.js"))});
const msgs = [];
const cmd = 'echo "<<' + process.argv[4] + ': ' + process.argv[3] + ' ' + process.argv[5] + '>>"';
h.handle({ cmd, sessionId: process.argv[2], pushMessage: (m) => msgs.push(String(m)),
  signalFatal: (m) => msgs.push(String(m)), repoCwd: process.cwd() });
process.stdout.write(JSON.stringify(msgs));`, [s.sid, runId, SENT, REASON])).join("\n");
}
// The commands the real PreToolUse entry routes to each gate.
const UV_CMD = 'echo "<<WORKFLOW_USER_VERIFIED: verified the fix end to end in the app>>"';
const MERGE_CMD = "gh pr merge 42 --squash --delete-branch";
// realGate(s, cmd, cwd) -> {decision, reason} of the real hooks/workflow-gate.js on a Bash payload,
// the env pinned as the feature-2256 bash harness pins it (empty cfg folder, plan session = sid).
function realGate(s, cmd, cwd) {
  const cfg = path.join(s.dir, "cfg");
  fs.mkdirSync(cfg, { recursive: true });
  fs.writeFileSync(path.join(cfg, ".env"), "");
  const env = Object.assign(X.envFor(s.dir), { AGENTS_MAIN_ROOT: cfg.replace(/\\/g, "/"), WORKFLOW_SESSION_ID: s.sid });
  for (const k of ["ENFORCE_WORKFLOW", "ENFORCE_WORKTREE"]) delete env[k];
  const input = JSON.stringify({ tool_name: "Bash", tool_input: { command: cmd, cwd }, session_id: s.sid });
  const r = spawnSync(process.execPath, [path.join(X.REPO, "hooks", "workflow-gate.js")],
    { input, env, cwd: s.dir, encoding: "utf8", timeout: 60000 });
  let o = null;
  try { o = JSON.parse(String(r.stdout || "").trim().split("\n").filter(Boolean).pop() || "null"); } catch (_e) { o = null; }
  return { decision: o ? String(o.decision || "none") : `parse-error(${r.status}): ${String(r.stderr).slice(0, 300)}`,
    reason: o ? String(o.reason || "") : "" };
}
const overridesOf = (s) => S.auditOf(s).block_overrides || [];
const isArm = (r) => typeof r === "string" && /audit run has been armed/.test(r);

// unsettledSlot(s, runs, phase) — runs plus a newer shown TR6 run-0012 sitting in the slot at phase.
function unsettledSlot(s, runs, phase, extra = {}) {
  const last = runs[runs.length - 1];
  const ledger = runs.concat([{ id: "run-0012", outcome: "armed", tr_ids: ["TR6"], cause: "severity-threshold:error",
    verdict: null, freshness_key: null, sub_checks: ["scope-drift"], input_key: { "scope-drift": null }, armed_at: now() }]);
  X.seedSup(s.dir, s.sid, { audit: Object.assign({ ledger, last_terminal_run_id: last.id,
    audit_verdict_summary: last.verdict, audit_run_id: "run-0012", audit_phase: phase, run_seq: 12,
    pending_sub_checks: ["scope-drift"], audit_dispatched_at: now() }, extra) });
}

module.exports = {
  SENT, REASON, now, make, writePlans, fresh, run, seedRuns, record, tr5At, preMerge, accept,
  overridesOf, isArm, unsettledSlot, UV_CMD, MERGE_CMD, realGate,
};
