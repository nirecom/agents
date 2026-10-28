"use strict";
// hooks/lib/decision-time-limit.js — one decision time limit per allow-deny hook process (#2676).
// The limit is anchored at process start (hook-deadline.js), so module loading counts. Past the
// limit checkDecisionTime writes permissionDecision "ask" and ends the process: a prompt beats a
// hook cancelled by its settings.json timeout, which Claude Code reads as "no decision".

const fs = require("fs");
const path = require("path");
const { createDeadline } = require("./hook-deadline");
const rotatingLog = require("./jsonl-rotating-log");
const { ask } = require("./permission-decision-output");

// Below the 15 s settings.json timeout, above the worst measured ordinary decision.
// Under load from 7 parallel sessions that rose to about 8.7 s (block-case-markers) and 8.0 s
// (enforce-worktree), wall-clock durationMs from Claude Code transcripts, node start included.
// 10 s leaves 5 s before the kill for node start, output and exit. That margin is estimated
// (light hooks took at most about 1.75 s end to end); the timing log below measures it.
// Not longer: a check that never fits (a 750-file commit scan) makes the user wait this long for the ask.
// Measurements: https://github.com/nirecom/agents/issues/2676#issuecomment-6288155952
const DECISION_TIME_LIMIT_MS = 10000;
const TIMING_LOG_NAME = "hook-decision-timing.jsonl";
const TIMING_LOG_MAX_WAIT_MS = 200;

let armed = null;

// One line per armed process, matched later to the transcript's durationMs by hook name and end
// time to measure the margin (15 s minus the limit). Never throws, prints or changes the exit code.
function writeTimingLog(timing) {
  try {
    const exitAtMs = timing.uptimeSec() * 1000;
    const record = {
      hookName: armed.hookName,
      pid: process.pid,
      startedAt: timing.startedAt,
      armedAtMs: timing.armedAtMs,
      exitAtMs,
      asked: armed.asked,
    };
    const logPath = path.join(rotatingLog.resolveLogDir(), TIMING_LOG_NAME);
    rotatingLog.appendJsonlRotating(logPath, record, { maxWaitMs: TIMING_LOG_MAX_WAIT_MS });
  } catch { /* the log is diagnostic only */ }
}

function armDecisionTimeLimit({ hookName, now = Date.now, uptimeSec = process.uptime, write, exit } = {}) {
  if (armed) return;
  const deadline = createDeadline({ hookTimeoutMs: DECISION_TIME_LIMIT_MS, safetyMarginMs: 0, now, uptimeSec });
  armed = {
    hookName: String(hookName || "hook"),
    deadline,
    asked: false,
    // A synchronous write: process.exit right after an asynchronous one could drop the ask.
    write: typeof write === "function" ? write : (text) => fs.writeSync(1, text),
    exit: typeof exit === "function" ? exit : (code) => process.exit(code),
  };
  const armedAtMs = uptimeSec() * 1000;
  const timing = { uptimeSec, armedAtMs, startedAt: now() - armedAtMs };
  process.on("exit", () => writeTimingLog(timing));
}

const isDecisionTimeLimitArmed = () => armed !== null;

// Infinity while unarmed: an unarmed process has no decision time limit.
const remainingDecisionMs = () => (armed ? armed.deadline.remainingMs() : Infinity);

function limitReason(checkName) {
  const hookName = armed ? armed.hookName : "hook";
  return `${hookName}: decision time limit (${DECISION_TIME_LIMIT_MS} ms) reached before ${checkName} finished; asking instead of deciding`;
}

// Writes the ask and ends the process. Only reachable while armed.
function askAndExit(checkName) {
  armed.asked = true;
  armed.write(JSON.stringify(ask(limitReason(checkName))) + "\n");
  armed.exit(0);
}

function checkDecisionTime(checkName) {
  if (!armed || remainingDecisionMs() > 0) return;
  askAndExit(checkName);
}

module.exports = {
  DECISION_TIME_LIMIT_MS,
  armDecisionTimeLimit,
  isDecisionTimeLimitArmed,
  remainingDecisionMs,
  checkDecisionTime,
  askAndExit,
  limitReason,
};
