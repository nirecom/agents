"use strict";
// Tests: hooks/workflow-run-tests/dispatch-outcome.js
// Tags: TL2, hooks, run-tests, dispatch-outcome, fixture, scope:issue-specific
// Shared kit for the #3063 cases: child runs of the real hook / show-dispatch-outcome /
// dispatchPrecondition, optionally under preload.js (EACCES on one control dir, or a
// throwing recordParts), plus outcome placement variants (absent, untrusted, restored).

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const F = require("../../lib/run-tests-outcome-fixture");

const PRELOAD = path.join(__dirname, "preload.js");
const PRECONDITION_PROBE = path.join(__dirname, "precondition-probe.js");
const HOOK = path.join(F.ROOT, "hooks", "workflow-run-tests.js");
const SHOW = path.join(F.ROOT, "skills", "run-tests", "scripts", "show-dispatch-outcome.js");
const SCAN_FAILED_STEM = "control-dir-scan-failed";

let n = 0;
function session(tag) {
  const sid = `s-3063-${tag}-${++n}`;
  F.seedPrefix(sid);
  return sid;
}

// opts: { eaccesSid, throwRecordParts } — which preload faults the child gets.
function faultEnv(opts) {
  const o = opts || {};
  const env = {};
  if (o.eaccesSid) env.F3063_EACCES_DIR = F.controlDir(o.eaccesSid);
  if (o.throwRecordParts) env.F3063_THROW_RECORD_PARTS = "1";
  return env;
}

function node(script, args, input, opts) {
  const env = faultEnv(opts);
  const pre = Object.keys(env).length > 0 ? ["--require", PRELOAD] : [];
  const r = spawnSync(process.execPath, pre.concat([script], args || []), {
    input: input || "", encoding: "utf8", timeout: 30000, cwd: F.tmp(),
    env: Object.assign({}, process.env, env),
  });
  if (r.error) throw new Error(`${path.basename(script)} did not run: ${r.error.message}`);
  return { status: r.status, stdout: (r.stdout || "").replace(/\r/g, ""), stderr: r.stderr || "" };
}

// hook(sid, command, exit, stdout, cwd, opts) — one PostToolUse call; throws on a non-zero exit.
function hook(sid, command, exitCode, stdout, cwd, opts) {
  const input = { tool_name: "Bash", session_id: sid, tool_input: { command, cwd: cwd || F.ROOT_FWD }, tool_response: { exit_code: exitCode, stdout: stdout || "" } };
  const r = node(HOOK, [], JSON.stringify(input), opts);
  if (r.status !== 0) throw new Error(`hook exit ${r.status}: ${r.stderr}`);
  return r;
}
const poke = (sid, opts) => hook(sid, "git status", 0, "", F.ROOT_FWD, opts);

const show = (sid, opts) => node(SHOW, ["--session", sid], "", opts);

// The dispatchPrecondition answer in a child, so the EACCES preload can reach its scan.
function precondition(sid, entry, opts) {
  const r = node(PRECONDITION_PROBE, [sid, JSON.stringify(entry || {})], "", opts);
  if (r.status !== 0) throw new Error(`precondition probe exit ${r.status}: ${r.stderr}`);
  return JSON.parse(r.stdout);
}

const outcomePath = (sid, stem) => path.join(F.controlDir(sid), `${stem}.outcome.json`);

// place(sid, o) plus o.absent (outcome file removed) or o.untrusted (session_id forged).
function place(sid, o) {
  const stem = F.placeOutcome(sid, o);
  const p = outcomePath(sid, stem);
  if (o.absent) fs.rmSync(p, { force: true });
  if (o.untrusted) {
    const j = JSON.parse(fs.readFileSync(p, "utf8"));
    j.session_id = `${sid}-forged`;
    fs.writeFileSync(p, `${JSON.stringify(j)}\n`);
  }
  return stem;
}

// The outcome of an already-dispatched stem lands later: rewrite its files, keep its marker mtime.
function land(sid, o) {
  const marker = path.join(F.controlDir(sid), `worker-test-runner-${o.seq}.dispatched`);
  const t = fs.statSync(marker).mtime;
  const stem = F.placeOutcome(sid, o);
  fs.utimesSync(marker, t, t);
  return stem;
}

// seedComplete(sid) — run_tests complete with a passing observation, as a green run leaves it.
function seedComplete(sid) {
  F.seed(sid, [F.status("run_tests", "complete"), F.note("run_outcome", "pass")]);
}

const rerunList = (sid) => F.mod("bin/workflow/lib/run-tests-baseline-evidence/rerun-list.js").rerunList(sid);
const runParts = () => F.mod("hooks/workflow-run-tests/run-parts.js");
const headerLines = (stdout) => stdout.split("\n").filter((l) => /^(DISPATCH_STEM|OUTCOME|OUTCOME_REASON)=/.test(l));
const stemsShown = (stdout) => stdout.split("\n").filter((l) => l.startsWith("DISPATCH_STEM=")).map((l) => l.slice("DISPATCH_STEM=".length));

module.exports = {
  SCAN_FAILED_STEM, session, hook, poke, show, precondition, place, land, seedComplete,
  rerunList, runParts, headerLines, stemsShown,
};
