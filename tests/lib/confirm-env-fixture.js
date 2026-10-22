"use strict";
// tests/lib/confirm-env-fixture.js — the JS twin of confirm-env-fixture.sh.
// Tests: tests/lib/confirm-env-fixture.js
// Tags: test-infrastructure, shared-lib, confirm-gate, fixture, scope:common
// #2726/#2729: the plan-stage CONFIRM flags are read from $AGENTS_MAIN_ROOT/.env only. A driver
// sets them by writing a .env in a temp dir and pointing AGENTS_MAIN_ROOT at it (for a child via
// its env, for this process via withConfirmEnv), never through process.env.CONFIRM_<STAGE>.
const fs = require("fs");
const path = require("path");

const PLAN_KEYS = Object.freeze(["CONFIRM_INTENT", "CONFIRM_OUTLINE", "CONFIRM_DETAIL"]);
let seq = 0;

// confirmEnvRoot(baseDir, vars, {local}) -> dir holding .env (and .env.local when `local` is given).
// vars / local: {KEY: value}; a null value omits the key.
function confirmEnvRoot(baseDir, vars, opts) {
  const dir = path.join(baseDir, `cfg-${process.pid}-${++seq}`);
  fs.mkdirSync(dir, { recursive: true });
  const body = (o) => Object.entries(o || {}).filter(([, v]) => v !== null && v !== undefined).map(([k, v]) => `${k}=${v}`).join("\n") + "\n";
  fs.writeFileSync(path.join(dir, ".env"), body(vars));
  if (opts && opts.local) fs.writeFileSync(path.join(dir, ".env.local"), body(opts.local));
  return dir;
}

// childEnvWith(dir, base) -> a copy of base (default process.env) with AGENTS_MAIN_ROOT=dir and
// the plan-stage keys removed, so only the file decides.
function childEnvWith(dir, base) {
  const env = Object.assign({}, base || process.env);
  for (const k of PLAN_KEYS) delete env[k];
  env.AGENTS_MAIN_ROOT = dir;
  return env;
}

// withConfirmEnv(dir, fn, exported) -> fn() run with process.env.AGENTS_MAIN_ROOT=dir; `exported`
// ({KEY: value}) additionally sets process env keys (to prove they are ignored). Restored after.
function withConfirmEnv(dir, fn, exported) {
  const over = Object.assign({ AGENTS_MAIN_ROOT: dir }, exported || {});
  for (const k of PLAN_KEYS) if (!(k in over)) over[k] = null;
  const saved = {};
  for (const k of Object.keys(over)) {
    saved[k] = process.env[k];
    if (over[k] === null) delete process.env[k]; else process.env[k] = over[k];
  }
  try { return fn(); } finally {
    for (const k of Object.keys(saved).reverse()) {
      if (saved[k] === undefined) delete process.env[k]; else process.env[k] = saved[k];
    }
  }
}

module.exports = { PLAN_KEYS, confirmEnvRoot, childEnvWith, withConfirmEnv };
