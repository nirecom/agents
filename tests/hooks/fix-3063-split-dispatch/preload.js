"use strict";
// Tests: hooks/workflow-state/dispatch-settlement.js
// Tags: TL2, hooks, run-tests, fault-injection, fixture, scope:issue-specific
// node --require preload for the #3063 cases. F3063_EACCES_DIR: fs.readdirSync throws EACCES
// for that one directory only (every other path reads as usual). F3063_THROW_RECORD_PARTS=1:
// run-parts.recordParts throws; patched before record-run.js destructures it at load.

const fs = require("fs");
const path = require("path");

const norm = (p) => {
  const r = path.resolve(String(p));
  return process.platform === "win32" ? r.toLowerCase() : r;
};

if (process.env.F3063_EACCES_DIR) {
  const want = norm(process.env.F3063_EACCES_DIR);
  const original = fs.readdirSync;
  fs.readdirSync = function readdirWithEacces(p, ...rest) {
    if (typeof p === "string" && norm(p) === want) {
      const e = new Error(`EACCES: permission denied, scandir '${p}'`);
      Object.assign(e, { code: "EACCES", errno: -13, syscall: "scandir", path: p });
      throw e;
    }
    return original.call(fs, p, ...rest);
  };
}

if (process.env.F3063_THROW_RECORD_PARTS === "1") {
  const rp = require(path.join(__dirname, "..", "..", "..", "hooks", "workflow-run-tests", "run-parts.js"));
  rp.recordParts = () => {
    throw new Error("f3063-injected recordParts failure");
  };
}
