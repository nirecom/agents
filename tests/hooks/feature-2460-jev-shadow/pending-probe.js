#!/usr/bin/env node
"use strict";
// Pending write probe for k-fallbacks.sh (#2460): the session dir is renamed away (as a retention
// tombstone does) between the tmp write and the final rename, <fails> times in a row.
// Usage: node pending-probe.js <pending.js> <pending|unlogged> <sid> <tid> <fails>
// Prints "<result>|<final entries in the live pending dir>|<.tmp left there>|<injections>".
const fs = require("fs");
const path = require("path");

const [pendPath, kind, sid, tid, fails] = process.argv.slice(2);
const pending = require(pendPath);
const sessDir = path.dirname(pending.pendingDir(sid));
const realRename = fs.renameSync;
let injected = 0;
fs.renameSync = function (src) {
  if (injected < Number(fails) && String(src).endsWith(".tmp") && String(src).startsWith(sessDir + path.sep)) {
    injected++;
    realRename(sessDir, path.join(path.dirname(sessDir), ".tomb-" + sid + "-" + injected));
  }
  return realRename.apply(this, arguments);
};

let result;
try {
  if (kind === "pending") {
    pending.writePending(sid, tid, { point: "complexity-judge" });
    result = "ok";
  } else {
    result = String(pending.writeUnlogged(sid, tid, { point: "complexity-judge" }));
  }
} catch (e) {
  result = "threw:" + (e && e.code);
}
fs.renameSync = realRename;

let names = [];
try { names = fs.readdirSync(pending.pendingDir(sid)).sort(); } catch (_e) { names = []; }
const finals = names.filter((n) => !n.endsWith(".tmp"))
  .map((n) => (n.startsWith(tid + ".unlogged-") ? tid + ".unlogged-*" : n));
process.stdout.write([result, finals.join(","), names.filter((n) => n.endsWith(".tmp")).length, injected].join("|"));
