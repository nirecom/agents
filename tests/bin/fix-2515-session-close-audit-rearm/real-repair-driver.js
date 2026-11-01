"use strict";
// #2515 integration driver: runs session-close-gate.run with the real worker-dispatch spawn, so the
// repair launches the real bin/supervisor-write-audit (and bin/supervisor-report) children.
// spawn.js hands a child only the CHILD_ENV_ALLOWLIST (HOME / USERPROFILE, never WORKFLOW_STATE_DIR),
// so the caller isolates by pointing HOME and USERPROFILE at a temp home and leaving both workflow
// dirs unset: this process and every child then resolve <temp home>/.workflow-state.
// argv: <mode: match|mismatch> <TARGET_MAIN_ROOT dir>. Prints one JSON line.
const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..", "..", "..");
const [mode, targetRoot] = process.argv.slice(2);
for (const k of ["WORKFLOW_STATE_DIR", "WORKFLOW_PLANS_DIR"]) {
  if (process.env[k]) { console.log(JSON.stringify({ error: `${k} must be unset in the driver` })); process.exit(2); }
}

const writer = require(path.join(ROOT, "hooks/lib/supervisor-state-writer"));
const spawnPath = require.resolve(path.join(ROOT, "bin/worker-dispatch/spawn.js"));
const spawnMod = require(spawnPath);
const realRun = spawnMod.run;
const calls = [];
let superseded = null;
// Wraps (never replaces) the real run: records each child and, in mismatch mode, re-arms a new
// run just before writeAudit starts, so the --run-id the gate read no longer names the current run.
spawnMod.run = (entry, opts) => {
  if (mode === "mismatch" && opts.script === "writeAudit" && superseded === null) {
    const r = writer.armAuditRun(sid, { tr_ids: ["TR4"], cause: "step-complete:write_code", supersede_unsettled: true, cwd: targetRoot });
    superseded = (r && r.audit_run_id) || "ARM-FAILED:" + JSON.stringify(r);
  }
  const res = realRun(entry, opts);
  calls.push({ script: opts.script, args: opts.args.slice(), status: res.status, stderr: res.stderr.slice(0, 300) });
  return res;
};
const gate = require(path.join(ROOT, "bin/worker-dispatch/workers/session-close-gate.js"));
const registry = require(path.join(ROOT, "hooks/lib/worker-dispatch-registry"));

const sid = `f2515-real-${mode}-${process.pid}`;
const armed = writer.armAuditRun(sid, { tr_ids: ["TR4"], cause: "step-complete:write_code", cwd: targetRoot });
const runId = armed && armed.audit_run_id;
// The run finished after the arm but its phase flag was left pending (the #961 repair shape).
writer.writeAuditState(sid, { audit_last_run_at: new Date(Date.now() + 1000).toISOString() });
const before = writer.readState(sid) || {};

const logDir = path.join(targetRoot, `logs-${mode}`);
fs.mkdirSync(logDir, { recursive: true });
const ctx = {
  entry: registry.workers["session-close-gate"],
  anchors: { scriptCheckoutRoot: ROOT, targetMainRoot: targetRoot, family: [targetRoot] },
  logDir,
  fsguard: { writeFile: (p, body) => { fs.writeFileSync(p, body); return p; } },
};
let res;
try { res = gate.run({ session_id: sid, outcome_json_path: path.join(targetRoot, "absent.json") }, ctx); } catch (e) { res = { threw: e.message }; }
const after = writer.readState(sid) || {};
const findings = ((after.layer1 || {}).findings || []).map((f) => ({ severity: f.severity, reporter: f.reporter, detail: f.detail }));
console.log(JSON.stringify({ sid, runId, superseded, before: before.audit || null, after: after.audit || null, findings, calls, res }));
