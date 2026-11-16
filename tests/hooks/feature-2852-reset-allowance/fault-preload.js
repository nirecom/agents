"use strict";
// Fault preload for tests/hooks/feature-2852-reset-from-gate.js, loaded with NODE_OPTIONS=--require
// into the hook child. F2852_FAULT=require-fails makes every module under
// hooks/workflow-state/reset-allowance fail to load; F2852_FAULT=decide-throws makes each exported
// decideReset throw when called. Every interception appends a line to F2852_FAULT_LOG, so a case
// can tell an ask caused by the fault from an ask with some other cause.
const fs = require("node:fs");
const Module = require("node:module");

const mode = process.env.F2852_FAULT;
const log = process.env.F2852_FAULT_LOG;
const TARGET = /[\\/]hooks[\\/]workflow-state[\\/]reset-allowance(?:\.js$|[\\/])/;

function note(what) {
  if (!log) return;
  try {
    fs.appendFileSync(log, `${what}\n`, "utf8");
  } catch {
    // The log is evidence only; a write failure must not change what the hook sees.
  }
}

function throwingDecide() {
  note("decideReset");
  throw new Error("fixture: decideReset failed (F2852_FAULT=decide-throws)");
}

function patchDecide(m) {
  if (!m || typeof m.decideReset !== "function" || m.decideReset === throwingDecide) return;
  try {
    m.decideReset = throwingDecide;
  } catch {
    // fall through to defineProperty below
  }
  if (m.decideReset !== throwingDecide) {
    try {
      Object.defineProperty(m, "decideReset", { value: throwingDecide, configurable: true, enumerable: true });
    } catch {
      note("decideReset-unpatchable");
    }
  }
}

if (mode === "require-fails" || mode === "decide-throws") {
  const load = Module._load;
  Module._load = function faultLoad(request, parent, isMain) {
    let file = "";
    try {
      file = Module._resolveFilename(request, parent, isMain);
    } catch {
      file = "";
    }
    if (!TARGET.test(String(file))) return load.apply(this, arguments);
    if (mode === "require-fails") {
      note(`require ${file}`);
      throw new Error(`fixture: cannot load ${file} (F2852_FAULT=require-fails)`);
    }
    const m = load.apply(this, arguments);
    patchDecide(m);
    return m;
  };
}
