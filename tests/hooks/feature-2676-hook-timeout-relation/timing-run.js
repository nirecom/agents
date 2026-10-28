"use strict";
// Parent side of the decision-timing-log cases of feature-2676-hook-timeout-relation.js: runs
// timing-child.js with AGENTS_STATE_DIR under the caller's temp root and reads back the log.
const assert = require("node:assert");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const TIMING_CHILD = path.join(__dirname, "timing-child.js");
const TIMING_FIELDS = ["armedAtMs", "asked", "exitAtMs", "hookName", "pid", "startedAt"];
// How far before the parent's spawn call the child's own start may be read (clock granularity).
const START_SLACK_MS = 2000;
let childSerial = 0;

// runChild(stateRoot, mode, { stateDir, stub }) -> { status, stdout, stderr, pid, info, logPath, lines, spawnedAt, endedAt }
function runChild(stateRoot, mode, { stateDir, stub = false } = {}) {
  const agentsStateDir = stateDir || path.join(stateRoot, `child-${++childSerial}`);
  const args = [TIMING_CHILD, mode].concat(stub ? ["stub"] : []);
  const spawnedAt = Date.now();
  const result = spawnSync(process.execPath, args, {
    env: { ...process.env, AGENTS_STATE_DIR: agentsStateDir }, encoding: "utf8", timeout: 30000,
  });
  const endedAt = Date.now();
  const infoLine = (result.stderr || "").split(/\r?\n/).find((line) => line.startsWith("INFO "));
  const logPath = path.join(agentsStateDir, "logs", "hook-decision-timing.jsonl");
  let lines = null;
  try { lines = fs.readFileSync(logPath, "utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line)); } catch (_err) { lines = null; }
  return { ...result, info: infoLine ? JSON.parse(infoLine.slice(5)) : null, logPath, lines, spawnedAt, endedAt, agentsStateDir };
}

const decisionOf = (run) => JSON.parse(run.stdout.trim()).hookSpecificOutput.permissionDecision;

function onlyLine(run) {
  assert.strictEqual(run.status, 0, `child exits 0 (stderr: ${run.stderr})`);
  assert.ok(Array.isArray(run.lines), `log file written at ${run.logPath}`);
  assert.strictEqual(run.lines.length, 1, `exactly one log line: ${JSON.stringify(run.lines)}`);
  return run.lines[0];
}

// The six fields, their types, and the child's start inside the parent's spawn window.
function assertFields(line, run) {
  assert.deepStrictEqual(Object.keys(line).sort(), TIMING_FIELDS);
  assert.strictEqual(line.hookName, "x-hook");
  assert.strictEqual(line.pid, run.pid, "pid is the child's");
  assert.strictEqual(typeof line.asked, "boolean");
  for (const field of ["startedAt", "armedAtMs", "exitAtMs"]) {
    assert.ok(Number.isFinite(line[field]), `${field} is a finite number: ${line[field]}`);
  }
  assert.ok(line.armedAtMs >= 0 && line.armedAtMs <= line.exitAtMs, `0 <= armedAtMs ${line.armedAtMs} <= exitAtMs ${line.exitAtMs}`);
  assert.ok(line.startedAt >= run.spawnedAt - START_SLACK_MS && line.startedAt <= run.endedAt,
    `startedAt ${line.startedAt} lies within the spawn window [${run.spawnedAt}, ${run.endedAt}]`);
}

// A failing log write changes neither the exit code nor the decision, and prints no error.
function assertSameOutcome(good, bad) {
  assert.deepStrictEqual([bad.status, bad.stdout], [good.status, good.stdout]);
  assert.doesNotMatch(bad.stderr, /Error|at .*decision-time-limit/, `no error on stderr: ${bad.stderr}`);
}

// A state dir under a regular file: the log directory can never be created.
function unwritableStateDir(stateRoot) {
  const blocker = path.join(stateRoot, `blocker-${++childSerial}`);
  fs.writeFileSync(blocker, "a regular file, not a directory\n");
  return path.join(blocker, "state");
}

module.exports = { runChild, decisionOf, onlyLine, assertFields, assertSameOutcome, unwritableStateDir };
