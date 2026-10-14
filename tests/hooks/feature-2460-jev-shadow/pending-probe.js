#!/usr/bin/env node
"use strict";
// Pending write probe for k-fallbacks.sh (#2460): the session dir is renamed away (as a retention
// tombstone does) between the tmp write and the final rename, <fails> times in a row.
// Usage: node pending-probe.js <pending.js> <pending|unlogged> <sid> <tid> <fails>
// Prints "<result>|<final entries in the live pending dir>|<.tmp left there>|<injections>".
// Takeover probe for m-pending-v2.sh: node pending-probe.js <pending.js> takeover <sid> <tid> <dead|live|stale>
// seeds <tid>.claimed-<owner pid> and calls takeOverClaim. Prints
// "<returned marker or null>|<entries, own pid shown as SELF, seeded owner pid as OWNER>".
const fs = require("fs");
const path = require("path");
const cp = require("child_process");

const [pendPath, kind, sid, tid, fails] = process.argv.slice(2);
const pending = require(pendPath);

if (kind === "takeover") {
  if (typeof pending.takeOverClaim !== "function") {
    process.stdout.write("EXPORT_MISSING: takeOverClaim");
    process.exit(0);
  }
  let child = null;
  let owner;
  if (fails === "dead") {
    owner = Number(cp.spawnSync(process.execPath, ["-e", "process.stdout.write(String(process.pid))"]).stdout);
  } else {
    child = cp.spawn(process.execPath, ["-e", "setTimeout(() => {}, 120000)"], { stdio: "ignore" });
    owner = child.pid;
  }
  const dir = pending.pendingDir(sid);
  fs.mkdirSync(dir, { recursive: true });
  const claim = path.join(dir, tid + ".claimed-" + owner);
  fs.writeFileSync(claim, JSON.stringify({ version: 2, point: "complexity-judge", marker: "M" }));
  if (fails === "stale") { const t = new Date(Date.now() - 11 * 60 * 1000); fs.utimesSync(claim, t, t); }
  let out;
  try {
    const ret = pending.takeOverClaim(sid, tid, {});
    let obj = ret;
    if (typeof ret === "string") { try { obj = JSON.parse(ret); } catch (_e) { obj = { marker: "raw:" + ret }; } }
    out = obj === null || obj === undefined ? "null" : String(obj.marker);
  } catch (e) {
    out = "threw:" + (e && (e.code || e.message));
  }
  let names = [];
  try { names = fs.readdirSync(dir).sort(); } catch (_e) { names = []; }
  const shown = names.map((n) => n.replace(".claimed-" + process.pid, ".claimed-SELF").replace(".claimed-" + owner, ".claimed-OWNER"));
  if (child) child.kill();
  process.stdout.write([out, shown.join(",")].join("|"));
  process.exit(0);
}

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
