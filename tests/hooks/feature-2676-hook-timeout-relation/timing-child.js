"use strict";
// Child process for the decision-timing-log cases of feature-2676-hook-timeout-relation.js.
// argv[2] is the mode, argv[3] "stub" makes the log append throw; the parent points
// AGENTS_STATE_DIR at a temp dir and reads the log.
// stdout carries only the decision; stderr carries one "INFO <json>" line for the parent.
const fs = require("fs");
const path = require("path");

const LIB = path.resolve(__dirname, "..", "..", "..", "hooks", "lib");
const mode = process.argv[2];
const DELAY_MS = 300;
const info = {};

// The log write must not change the decision even when the append itself throws.
if (process.argv[3] === "stub") {
  const rotating = require(path.join(LIB, "jsonl-rotating-log.js"));
  rotating.appendJsonlRotating = () => { throw new Error("append-throws stub"); };
}

const limit = require(path.join(LIB, "decision-time-limit.js"));
const allow = JSON.stringify({ hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "allow" } });

// check-late: the clock reads as already past the limit, so the check asks.
const armOptions = mode === "check-late"
  ? { hookName: "x-hook", uptimeSec: () => (limit.DECISION_TIME_LIMIT_MS + 1000) / 1000 }
  : { hookName: "x-hook" };

info.listenersBefore = process.listenerCount("exit");
if (mode !== "unarmed") limit.armDecisionTimeLimit(armOptions);
if (mode === "double") limit.armDecisionTimeLimit({ hookName: "second-hook" });
info.listenersAfter = process.listenerCount("exit");

// Registered after arm, so it runs after the module's own exit listener.
process.on("exit", () => {
  info.uptimeAtLastExitListenerMs = process.uptime() * 1000;
  fs.writeSync(2, `INFO ${JSON.stringify(info)}\n`);
});

if (mode === "delay") {
  info.delayMs = DELAY_MS;
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, DELAY_MS);
}
if (mode === "ask") limit.askAndExit("example check");
if (mode === "check-late") limit.checkDecisionTime("example check");
fs.writeSync(1, allow + "\n");
if (mode === "exit2") process.exit(2);
