"use strict";
// Scene helpers for the #2698 change-3 suites (alert and audit as one intervention). Builds on
// fixture.js: real writer calls run in a child with the scene env, real hooks run on stdin, and
// transcripts carry timestamped human prompts so countHumanPromptsSince can count P.

const X = require("./fixture");

const WRITER = X.lib("hooks/lib/supervisor-state-writer.js");
const GUARD = "hooks/supervisor-guard.js";
const DISPLAY = "hooks/stop-l2-findings-display.js";

// writer(dir, fn, ...args) -> the JSON-serialised return value of the real writer export.
// A missing export yields { missingExport: fn } so the caller can assert on it.
function writer(dir, fn, ...args) {
  const out = X.nodeEval(dir, `
const w = require(${JSON.stringify(WRITER)});
const fn = process.argv[2];
if (typeof w[fn] !== "function") { process.stdout.write(JSON.stringify({ missingExport: fn })); process.exit(0); }
const r = w[fn](...JSON.parse(process.argv[3]));
process.stdout.write(JSON.stringify(r === undefined ? null : r));`, [fn, JSON.stringify(args)]);
  return JSON.parse(out);
}

// stepKey(dir, sid, step) -> the transition key "<step>#<updated_seq>" from the workflow projection.
function stepKey(dir, sid, step) {
  const out = X.nodeEval(dir, `
const w = require(${JSON.stringify(X.lib("hooks/workflow-state.js"))});
const s = w.readState(process.argv[2]);
const e = s && s.current && s.current.steps && s.current.steps[process.argv[3]];
process.stdout.write(JSON.stringify(e && e.status === "complete" ? process.argv[3] + "#" + e.updated_seq : null));`, [sid, step]);
  return JSON.parse(out);
}

// The anchor of every scene: the alert review completed at T0 + 1 min; prompts sit around it.
const T0 = Date.now() - 60 * 60 * 1000;
const iso = (min) => new Date(T0 + min * 60000).toISOString();
const LAST_RUN_AT = iso(1);

// turns(prompts, { dialogLast, untimed }) -> transcript entries. prompts are minute offsets from T0;
// each opens a non-dialog turn (Bash then a plain report) unless dialogLast makes the final turn a
// question answered after Grep only. untimed drops the timestamp of the last prompt (P undecidable).
function turns(prompts, opts = {}) {
  const out = [];
  prompts.forEach((min, i) => {
    const last = i === prompts.length - 1;
    const extra = last && opts.untimed ? {} : { timestamp: iso(min) };
    if (last && opts.dialogLast) {
      out.push(X.U("Where is this function called from?", extra), X.A(X.TU("Grep")), X.R(),
        X.A(X.T("It is called from line 12 of hooks/a.js.")));
    } else {
      out.push(X.U(`Run task ${i}.`, extra), X.A(X.TU("Bash", { command: "ls" })), X.R(),
        X.A(X.T(`Task ${i} is done.`)));
    }
  });
  return out;
}

// P = prompts after LAST_RUN_AT: [0] -> 0, [0,2] -> 1, [0,2,3] -> 2.
const PROMPTS = { 0: [0], 1: [0, 2], 2: [0, 2, 3] };

let seq = 0;
// scene(root, tag, sup) -> {dir, sid}: workflow started (clarify_intent complete = an unconsumed
// TR1 edge) and the supervisor state seeded with sup ({alert, audit, layer1}).
function scene(root, tag, sup = {}) {
  seq += 1;
  const dir = X.sceneDir(root, `${tag}-${seq}`);
  const sid = `a${tag.replace(/[^A-Za-z0-9]/g, "")}${seq}`;
  X.seedStarted(dir, sid);
  X.seedSup(dir, sid, sup);
  return { dir, sid };
}

// armUnshown(s) -> the run armed by the real writer for the TR1 edge, without launch_shown
// (an "unshown run": pending, audit_dispatched_at null). It consumes the TR1 transition.
function armUnshown(s) {
  const key = stepKey(s.dir, s.sid, "clarify_intent");
  return writer(s.dir, "armAuditRun", s.sid, {
    tr_ids: ["TR1"], sub_checks: ["intent-internal"], transitions: [key],
    cause: "step-complete:clarify_intent", cwd: s.dir, plans_dir: s.dir,
  });
}

// completeWriteCode(s) -> the new TR4 edge key (write_code complete, unconsumed).
function completeWriteCode(s) {
  X.markSteps(s.dir, s.sid, [["write_code", "complete"]]);
  return stepKey(s.dir, s.sid, "write_code");
}

const guard = (s, entries, name) => X.runHook(GUARD, s.dir, X.stopInput(s.dir, s.sid, entries, name));
const display = (s, entries, name) => X.runHook(DISPLAY, s.dir, X.stopInput(s.dir, s.sid, entries, name));
const auditOf = (s) => (X.readSup(s.dir, s.sid) || {}).audit || {};
const ledgerEntry = (audit, id) => (Array.isArray(audit.ledger) ? audit.ledger : []).find((e) => e && e.id === id) || null;
const stdoutLines = (r) => String(r.stdout || "").split("\n").filter((l) => l.trim() !== "");
const reasonOf = (r) => (r.json && typeof r.json.reason === "string" ? r.json.reason : "");
const hasLaunch = (text) => /Run ID: run-\d{4}/.test(text) && /supervisor-audit/.test(text);
const ALERT_MARK = /Alert mode review required|Alert mode: cumulative_severity=error/;

// A schema-valid alert finding.
const finding = (severity, detail) => ({
  severity, categories: ["workflow"], reporter: "supervisor", detail,
  reason: "fixture finding", timestamp: iso(1),
});

module.exports = {
  writer, stepKey, T0, iso, LAST_RUN_AT, turns, PROMPTS, scene, armUnshown, completeWriteCode,
  guard, display, auditOf, ledgerEntry, stdoutLines, reasonOf, hasLaunch, ALERT_MARK, finding,
};
