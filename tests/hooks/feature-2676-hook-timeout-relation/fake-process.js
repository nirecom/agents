"use strict";
// A fake process for the #2676 decision-time-limit TL1 tests (feature-2676-hook-timeout-relation.js
// and feature-2676-limited-child-process.js): a clock that moves only when the test says so,
// collected stdout writes, and an exit stub that throws ExitCalled.
// The fake is handed to armDecisionTimeLimit as options and, as a fallback, swapped into the
// process globals (Date.now / process.uptime / process.stdout.write / process.exit) while a call
// runs, so the tests hold whichever of the two the module reads.
const path = require("path");

const LIB = path.resolve(__dirname, "..", "..", "..", "hooks", "lib");

class ExitCalled extends Error {
  constructor(code) { super(`exit(${code})`); this.code = code; }
}

function fakeProcess({ startMs = 1000000, uptimeSec = 0 } = {}) {
  const state = { nowMs: startMs, written: [] };
  state.now = () => state.nowMs;
  state.uptime = () => uptimeSec + (state.nowMs - startMs) / 1000;
  state.write = (text) => { state.written.push(String(text)); return true; };
  state.exit = (code) => { throw new ExitCalled(code); };
  return state;
}

// Synchronous on purpose: node:test writes nothing while the globals are swapped.
function withFake(fake, fn) {
  const saved = { now: Date.now, uptime: process.uptime, write: process.stdout.write, exit: process.exit };
  Date.now = fake.now;
  process.uptime = fake.uptime;
  process.stdout.write = fake.write;
  process.exit = fake.exit;
  try { return fn(); } finally {
    Date.now = saved.now;
    process.uptime = saved.uptime;
    process.stdout.write = saved.write;
    process.exit = saved.exit;
  }
}

// freshRequire(fake, names) -> { modules, error }: drops the hooks/lib modules from the require
// cache and loads `names` again, so each case starts unarmed.
const CHAIN = ["decision-time-limit.js", "limited-child-process.js", "permission-decision-output.js", "hook-deadline.js"];
function freshRequire(fake, names) {
  for (const name of CHAIN) delete require.cache[path.join(LIB, name)];
  const modules = {};
  let error = null;
  withFake(fake, () => {
    try { for (const name of names) modules[name] = require(path.join(LIB, name)); } catch (err) { error = err; }
  });
  return { modules, error };
}

const armOptions = (fake, hookName) => ({ hookName, now: fake.now, uptimeSec: fake.uptime, write: fake.write, exit: fake.exit });

// runCaught(fake, fn) -> { exited, code, value, thrown }: runs fn under the fake and reports
// whether it ended the process, returned, or threw something else.
function runCaught(fake, fn) {
  try {
    return { exited: false, code: null, value: withFake(fake, fn), thrown: null };
  } catch (err) {
    if (err instanceof ExitCalled) return { exited: true, code: err.code, value: undefined, thrown: null };
    return { exited: false, code: null, value: undefined, thrown: err };
  }
}

const writtenJson = (fake) => JSON.parse(fake.written.join("").trim());

module.exports = { ExitCalled, fakeProcess, withFake, freshRequire, armOptions, runCaught, writtenJson };
