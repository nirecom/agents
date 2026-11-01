"use strict";
// Tests: bin/worker-dispatch/workers/session-close-gate.js
// Tags: TL1, scope:issue-specific, supervisor, session-close, TL2
// #2515: a re-armed audit (audit_last_run_at older than audit_armed_at) must not be
// "repaired" to done; only a run that finished after the arm, or a terminal ledger
// entry for audit_run_id, settles it. The repair passes --run-id and a failed repair
// leaves a warning finding instead of vanishing. (a)-(f) mock spawn (TL1); the "real repair"
// cases run the gate in a child with the real spawn and the real writeAudit / report CLIs (TL2).

// TL3 gap (what this test does NOT catch):
// - the gate reached through bin/worker-dispatch from a live /session-close run (entry, anchors, family
//   resolved by the dispatcher rather than built by the driver)
require("../lib/harness");
const { isolate } = require("../lib/harness");

const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "..", "..");
const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2515-"));
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(TMP, "transcripts");
fs.mkdirSync(process.env.CLAUDE_TRANSCRIPT_BASE_DIR);

const spawnPath = require.resolve(path.join(ROOT, "bin/worker-dispatch/spawn.js"));
const calls = [];
let writeAuditStatus = 0;
require.cache[spawnPath] = {
  id: spawnPath, filename: spawnPath, loaded: true,
  exports: {
    run: (_entry, opts) => {
      calls.push({ script: opts.script, args: opts.args.slice() });
      return { status: opts.script === "writeAudit" || opts.script === "writeAlert" ? writeAuditStatus : 0, stdout: "", stderr: "" };
    },
  },
};
const gate = require(path.join(ROOT, "bin/worker-dispatch/workers/session-close-gate.js"));
const { controlPath } = require(path.join(ROOT, "hooks/workflow-state/state-io/control-dir"));

test.after(() => { restore(); fs.rmSync(TMP, { recursive: true, force: true }); });

const NOW = Date.parse("2026-10-31T12:00:00.000Z");
const iso = (offsetSec) => new Date(NOW + offsetSec * 1000).toISOString();
const auditState = (audit) => ({ audit: Object.assign({ audit_phase: "pending", ledger: [] }, audit) });
const alertState = (alert) => ({ alert: Object.assign({ alert_phase: "pending" }, alert) });

let n = 0;
function runGate(state) {
  const sid = `f2515-${++n}`;
  fs.writeFileSync(controlPath(sid, "supervisor-state.json", { forWrite: true }), JSON.stringify(state));
  calls.length = 0;
  const logDir = path.join(TMP, `logs-${n}`);
  fs.mkdirSync(logDir);
  const ctx = {
    entry: "fixture", anchors: { targetMainRoot: TMP }, logDir,
    fsguard: { writeFile: (p, body) => { fs.writeFileSync(p, body); return p; } },
  };
  const res = gate.run({ session_id: sid, outcome_json_path: path.join(TMP, "absent.json") }, ctx);
  return { sid, res, calls: calls.slice() };
}

test("(a) pending audit whose last run predates the re-arm is not repaired", () => {
  const r = gate.evaluateAudit(auditState({ audit_armed_at: iso(-60), audit_last_run_at: iso(-120), audit_run_id: "run-0002" }), NOW);
  assert.strictEqual(r.repair, null, `stale last_run_at must not repair; got ${JSON.stringify(r)}`);
  assert.strictEqual(r.gateAction, "yield", "a freshly re-armed audit is still outstanding");
});

test("(b) audit_last_run_at after audit_armed_at repairs the audit phase", () => {
  const r = gate.evaluateAudit(auditState({ audit_armed_at: iso(-120), audit_last_run_at: iso(-60), audit_run_id: "run-0002" }), NOW);
  assert.strictEqual(r.repair, "audit");
});

test("(c) a terminal ledger entry for audit_run_id repairs; an armed one does not", () => {
  const base = { audit_armed_at: iso(-60), audit_last_run_at: null, audit_run_id: "run-0003" };
  const terminal = gate.evaluateAudit(auditState(Object.assign({}, base, { ledger: [{ id: "run-0003", outcome: "terminal" }] })), NOW);
  assert.strictEqual(terminal.repair, "audit", `terminal ledger entry; got ${JSON.stringify(terminal)}`);
  const armed = gate.evaluateAudit(auditState(Object.assign({}, base, { ledger: [{ id: "run-0003", outcome: "armed" }] })), NOW);
  assert.strictEqual(armed.repair, null, "armed ledger entry is still outstanding");
  assert.strictEqual(armed.gateAction, "yield");
});

test("(d) alert side compares last_run_at with alert_armed_at", () => {
  const stale = gate.evaluateAlert(alertState({ alert_armed_at: iso(-60), last_run_at: iso(-120) }), NOW);
  assert.strictEqual(stale.repair, null, `stale alert last_run_at must not repair; got ${JSON.stringify(stale)}`);
  assert.strictEqual(stale.gateAction, "yield");
  const fresh = gate.evaluateAlert(alertState({ alert_armed_at: iso(-120), last_run_at: iso(-60) }), NOW);
  assert.strictEqual(fresh.repair, "alert");
});

// detail Step 1 (b): repair only when audit_last_run_at > audit_armed_at, so an equal pair is not finished.
test("edge: audit_last_run_at equal to audit_armed_at is not repaired (strictly after only)", () => {
  const r = gate.evaluateAudit(auditState({ audit_armed_at: iso(-60), audit_last_run_at: iso(-60), audit_run_id: "run-0004" }), NOW);
  assert.strictEqual(r.repair, null, `equal timestamps must not repair; got ${JSON.stringify(r)}`);
  assert.strictEqual(r.gateAction, "yield", "a run that did not finish after the arm is still outstanding");
});

test("edge: alert last_run_at equal to alert_armed_at is not repaired either", () => {
  const r = gate.evaluateAlert(alertState({ alert_armed_at: iso(-60), last_run_at: iso(-60) }), NOW);
  assert.strictEqual(r.repair, null, `equal alert timestamps must not repair; got ${JSON.stringify(r)}`);
  assert.strictEqual(r.gateAction, "yield");
});

test("edge: a terminal ledger entry of another run id does not settle audit_run_id", () => {
  const st = auditState({ audit_armed_at: iso(-60), audit_last_run_at: null, audit_run_id: "run-0006",
    ledger: [{ id: "run-0005", outcome: "terminal" }, { id: "run-0006", outcome: "armed" }] });
  const r = gate.evaluateAudit(st, NOW);
  assert.strictEqual(r.repair, null, `an older run's terminal entry must not repair the re-armed run; got ${JSON.stringify(r)}`);
  assert.strictEqual(r.gateAction, "yield");
  const orphan = gate.evaluateAudit(auditState({ audit_armed_at: iso(-60), audit_last_run_at: null, audit_run_id: "run-0006",
    ledger: [{ id: "run-0005", outcome: "terminal" }] }), NOW);
  assert.strictEqual(orphan.repair, null, `no entry for audit_run_id: not finished; got ${JSON.stringify(orphan)}`);
  assert.strictEqual(orphan.gateAction, "yield");
});

test("edge: null timestamps read as not finished", () => {
  const audit = gate.evaluateAudit(auditState({ audit_armed_at: iso(-60), audit_last_run_at: null, audit_run_id: "run-0001" }), NOW);
  assert.strictEqual(audit.repair, null);
  assert.strictEqual(audit.gateAction, "yield");
  const alert = gate.evaluateAlert(alertState({ alert_armed_at: iso(-60), last_run_at: null }), NOW);
  assert.strictEqual(alert.repair, null);
  assert.strictEqual(alert.gateAction, "yield");
});

test("(e) applyRepair passes --run-id <audit_run_id> to writeAudit", () => {
  writeAuditStatus = 0;
  const armed = new Date(Date.now() - 120000).toISOString();
  const ran = new Date(Date.now() - 60000).toISOString();
  const { calls: got } = runGate(auditState({ audit_armed_at: armed, audit_last_run_at: ran, audit_run_id: "run-0007" }));
  const w = got.find((c) => c.script === "writeAudit");
  assert.ok(w, `writeAudit was not called; calls=${JSON.stringify(got)}`);
  const i = w.args.indexOf("--run-id");
  assert.ok(i >= 0 && w.args[i + 1] === "run-0007", `--run-id run-0007 missing; args=${JSON.stringify(w.args)}`);
});

test("(f) a non-zero writeAudit exit leaves a warning finding", () => {
  writeAuditStatus = 3;
  const armed = new Date(Date.now() - 120000).toISOString();
  const ran = new Date(Date.now() - 60000).toISOString();
  const { calls: got } = runGate(auditState({ audit_armed_at: armed, audit_last_run_at: ran, audit_run_id: "run-0008" }));
  writeAuditStatus = 0;
  const warn = got.filter((c) => c.script === "report").find((c) => {
    const sev = c.args[c.args.indexOf("--severity") + 1];
    const detail = c.args[c.args.indexOf("--detail") + 1] || "";
    return sev === "warning" && /repair|writeAudit/i.test(detail);
  });
  assert.ok(warn, `no warning report for the failed repair; calls=${JSON.stringify(got)}`);
});

// realRepair(mode) -> the driver's JSON: the gate run in a child whose HOME / USERPROFILE is a temp
// home and whose workflow dirs are unset, so the real CLIs it spawns share that state root.
const { spawnSync } = require("node:child_process");
const DRIVER = path.join(__dirname, "fix-2515-session-close-audit-rearm", "real-repair-driver.js");
function realRepair(mode) {
  const home = path.join(TMP, `home-${mode}`);
  const main = path.join(TMP, `main-${mode}`);
  fs.mkdirSync(home, { recursive: true });
  fs.mkdirSync(main, { recursive: true });
  const env = Object.assign({}, process.env, { HOME: home, USERPROFILE: home, CLAUDE_TRANSCRIPT_BASE_DIR: process.env.CLAUDE_TRANSCRIPT_BASE_DIR });
  for (const k of ["WORKFLOW_STATE_DIR", "WORKFLOW_PLANS_DIR", "CLAUDE_CODE_SESSION_ID", "WORKFLOW_SESSION_ID", "NODE_OPTIONS"]) delete env[k];
  const r = spawnSync(process.execPath, [DRIVER, mode, main], { env, cwd: main, encoding: "utf8", timeout: 90000 });
  let out = null;
  try { out = JSON.parse(String(r.stdout).trim().split(/\r?\n/).pop()); } catch (_) { out = null; }
  assert.ok(out && !out.error, `driver failed rc=${r.status} stdout=${r.stdout} stderr=${String(r.stderr).slice(0, 600)}`);
  assert.ok(fs.existsSync(path.join(home, ".workflow-state")), "the state root stayed under the temp home");
  return out;
}
const repairWarnings = (out) => out.findings.filter((f) => f.severity === "warning" && f.reporter === "session-close-gate" && /repair|writeAudit/i.test(f.detail || ""));

test("real repair: the writeAudit CLI applies --run-id to the target run (state and ledger)", () => {
  const out = realRepair("match");
  assert.ok(out.runId, `fixture arm produced no run; ${JSON.stringify(out)}`);
  assert.strictEqual(out.before.audit_phase, "pending", "fixture starts pending");
  const w = out.calls.find((c) => c.script === "writeAudit");
  assert.ok(w, `writeAudit was not launched; calls=${JSON.stringify(out.calls)}`);
  const i = w.args.indexOf("--run-id");
  assert.ok(i >= 0 && w.args[i + 1] === out.runId, `--run-id ${out.runId} missing; args=${JSON.stringify(w.args)}`);
  assert.strictEqual(w.status, 0, `real writeAudit exit ${w.status}: ${w.stderr}`);
  assert.strictEqual(out.after.audit_phase, "done", `state not repaired; ${JSON.stringify(out.after)}`);
  assert.strictEqual(out.after.audit_armed_at, null, "audit_armed_at cleared");
  assert.strictEqual(out.after.audit_run_id, out.runId, "the repaired run is the armed run");
  const ids = (out.after.ledger || []).map((e) => e.id);
  assert.deepStrictEqual(ids, (out.before.ledger || []).map((e) => e.id), "the repair arms no new ledger run");
  assert.ok(ids.includes(out.runId), `ledger keeps the target run; ${JSON.stringify(ids)}`);
  assert.deepStrictEqual(repairWarnings(out), [], "a successful repair leaves no warning");
});

test("real repair: a run-id that no longer matches fails writeAudit and leaves a warning finding", () => {
  const out = realRepair("mismatch");
  assert.ok(out.superseded && out.superseded !== out.runId && !String(out.superseded).startsWith("ARM-FAILED"), `re-arm ${out.superseded}`);
  const w = out.calls.find((c) => c.script === "writeAudit");
  assert.ok(w, `writeAudit was not launched; calls=${JSON.stringify(out.calls)}`);
  const i = w.args.indexOf("--run-id");
  assert.ok(i >= 0 && w.args[i + 1] === out.runId, `--run-id names the run the gate read; args=${JSON.stringify(w.args)}`);
  assert.notStrictEqual(w.status, 0, "the real CLI refuses the stale run id");
  assert.strictEqual(out.after.audit_run_id, out.superseded, "the re-armed run is untouched");
  assert.notStrictEqual(out.after.audit_phase, "done", `the re-armed run must not be repaired to done; ${JSON.stringify(out.after)}`);
  assert.ok(repairWarnings(out).length >= 1, `no persisted warning finding; findings=${JSON.stringify(out.findings)}`);
});
