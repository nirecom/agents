"use strict";
// hooks/lib/limited-child-process.js — spawnSync / execSync / execFileSync whose child timeout is
// the decision time left (#2676). Unarmed, the call reaches child_process untouched.
// Armed, the time left replaces the caller's timeout, so a hung child always ends in ask at the
// limit: a caller's own short-timeout fallback could otherwise decide allow without asking (N1).

const path = require("path");
// Called through the module object at call time, so a patched child_process is honoured.
const childProcess = require("child_process");
const { MIN_SLICE_MS } = require("./hook-deadline");
const limit = require("./decision-time-limit");
const fileStdio = require("./limited-child-process/file-stdio");

const CHECK_NAME_ARGS = 2;

function checkNameOf(command, args) {
  const words = Array.isArray(args)
    ? [path.basename(String(command)), ...args.slice(0, CHECK_NAME_ARGS).map(String)]
    : String(command).trim().split(/\s+/).slice(0, 1 + CHECK_NAME_ARGS);
  return words.join(" ");
}

// splitArgs(rest) -> { args, options }: args is optional in spawnSync / execFileSync.
function splitArgs(rest) {
  if (Array.isArray(rest[0])) return { args: rest[0], options: rest[1] };
  return { args: undefined, options: rest[0] };
}

const isTimedOut = (error) => Boolean(error) && error.code === "ETIMEDOUT";

// The stdio files are written before the child starts and read after it ends, outside the child
// timeout; a call that returns with no time left asks rather than let the hook decide late.
const isOverLimit = () => limit.remainingDecisionMs() <= 0;

// run(fnName, command, rest, checkName, returnsResult) — the shared body of the three wrappers.
function run(fnName, command, rest, checkName, returnsResult) {
  if (!limit.isDecisionTimeLimitArmed()) return childProcess[fnName](command, ...rest.values);
  const cap = Math.floor(limit.remainingDecisionMs());
  if (cap < MIN_SLICE_MS) return limit.askAndExit(checkName);
  const options = { ...(rest.options || {}), timeout: cap };
  // File stdio, not pipes: a grandchild holding a pipe would keep the call from returning at the cap.
  // A failed stdio setup asks too: a hook that crashed here would let the call through undecided.
  try {
    const result = fileStdio[fnName](command, rest.args, options);
    if (returnsResult && result && isTimedOut(result.error)) return limit.askAndExit(checkName);
    if (isOverLimit()) return limit.askAndExit(checkName);
    return result;
  } catch (error) {
    if (error && error.stdioSetupFailed) return limit.askAndExit(checkName);
    if (!returnsResult && isTimedOut(error)) return limit.askAndExit(checkName);
    if (isOverLimit()) return limit.askAndExit(checkName);
    throw error;
  }
}

function withArgs(fnName, returnsResult) {
  return (command, ...rest) => {
    const { args, options } = splitArgs(rest);
    return run(fnName, command, { args, options, values: rest }, checkNameOf(command, args), returnsResult);
  };
}

const spawnSync = withArgs("spawnSync", true);
const execFileSync = withArgs("execFileSync", false);
const execSync = (command, options) =>
  run("execSync", command, { args: undefined, options, values: options === undefined ? [] : [options] }, checkNameOf(command), false);

module.exports = { spawnSync, execSync, execFileSync, checkNameOf };
