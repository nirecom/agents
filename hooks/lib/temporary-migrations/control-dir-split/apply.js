"use strict";
// Temporary (#2434): deleted with this folder per the deletion-condition in control-dir.js.
// Atomic per-session publish. Every file is staged first; publish is exclusive
// (link, else open "wx") so a live writer's destination is never overwritten.
// Any failure unwinds this run's publishes and leaves every source untouched.
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { rewriteContent } = require("./rewrite");

const LINK_FALLBACK_CODES = new Set(["EPERM", "ENOTSUP", "EXDEV", "ENOSYS", "EOPNOTSUPP"]);

function fault() {
  return process.env.CONTROL_MIGRATION_FAULT || "";
}

function eacces(what) {
  return Object.assign(new Error(`EACCES: injected ${fault()} fault (${what})`), { code: "EACCES" });
}

function logLine(wf, line) {
  try {
    fs.mkdirSync(wf, { recursive: true });
    fs.appendFileSync(path.join(wf, "control-migration.log"), `${new Date().toISOString()} ${line}\n`);
  } catch (_) { /* diagnostic only */ }
}

function unlinkQuiet(p) {
  try { fs.unlinkSync(p); } catch (e) { if (e.code !== "ENOENT") throw e; }
}

function readOrNull(p) {
  try { return fs.readFileSync(p); } catch (e) { if (e.code === "ENOENT") return null; throw e; }
}

function prepareControlDir(ctl) {
  try {
    const st = fs.lstatSync(ctl);
    if (st.isSymbolicLink() || !st.isDirectory()) throw new Error(`${ctl} is not a real directory`);
    return false;
  } catch (e) {
    if (e.code !== "ENOENT") throw e;
  }
  fs.mkdirSync(path.dirname(ctl), { recursive: true });
  try { fs.mkdirSync(ctl); } catch (e) { if (e.code !== "EEXIST") throw e; return false; }
  return true;
}

function stage(s, sid, ctl) {
  let st;
  try { st = fs.statSync(s.src); } catch (e) {
    if (e.code === "ENOENT") return false;
    throw e;
  }
  const buf = readOrNull(s.src);
  if (buf === null) return false;
  s.bytes = rewriteContent(buf, { sid, ctlDir: ctl, name: s.name });
  s.atime = st.atime;
  s.mtime = st.mtime;
  if (fault() === "dst-unwritable") throw eacces(`stage ${s.name}`);
  s.tmp = path.join(ctl, `${s.name}.migrating.${process.pid}.${crypto.randomBytes(4).toString("hex")}.tmp`);
  fs.writeFileSync(s.tmp, s.bytes, { flag: "wx" });
  fs.utimesSync(s.tmp, s.atime, s.mtime);
  return true;
}

// true = published by this run, false = destination already existed.
function publish(s) {
  if (fault() === "link-fail") throw eacces(`publish ${s.name}`);
  try {
    fs.linkSync(s.tmp, s.dst);
    s.published = true;
    return true;
  } catch (e) {
    if (e.code === "EEXIST") return false;
    if (!LINK_FALLBACK_CODES.has(e.code)) throw e;
  }
  let fd;
  try { fd = fs.openSync(s.dst, "wx"); } catch (e) {
    if (e.code === "EEXIST") return false;
    throw e;
  }
  s.published = true;
  try { fs.writeSync(fd, s.bytes); } finally { fs.closeSync(fd); }
  fs.utimesSync(s.dst, s.atime, s.mtime);
  return true;
}

function unwind(staged, ctl, createdDir) {
  for (const s of staged) {
    try {
      if (s.published && fs.existsSync(s.src)) {
        const now = readOrNull(s.dst);
        if (now && now.equals(s.bytes)) unlinkQuiet(s.dst);
      }
    } catch (_) { /* best effort */ }
    try { if (s.tmp) unlinkQuiet(s.tmp); } catch (_) { /* best effort */ }
  }
  if (createdDir) { try { fs.rmdirSync(ctl); } catch (_) { /* not empty or gone */ } }
}

// A source a concurrent migrator already consumed counts as "identical": it reached the control dir.
function settleExisting(s) {
  const dstBytes = readOrNull(s.dst);
  if (dstBytes && dstBytes.equals(s.bytes)) return "identical";
  if (!fs.existsSync(s.src)) return "identical";
  return "conflict";
}

function applyBatch(sid, entries, { wf }) {
  if (!entries || entries.length === 0) return [];
  const ctl = path.join(wf, `${sid}.control`);
  const staged = [];
  const vanished = [];
  let createdDir = false;
  try {
    createdDir = prepareControlDir(ctl);
    for (const e of entries) {
      const s = { name: e.name, src: e.src, dst: path.join(ctl, e.name) };
      if (stage(s, sid, ctl)) staged.push(s);
      else vanished.push(s);
    }
    for (const s of staged) s.outcome = publish(s) ? "migrated" : settleExisting(s);
  } catch (err) {
    unwind(staged, ctl, createdDir);
    const why = (err && err.message) || String(err);
    return entries.map((e) => ({ sid, name: e.name, outcome: "failed", error: why }));
  }
  const rows = [];
  for (const s of staged) {
    try { unlinkQuiet(s.tmp); } catch (_) { /* swept later by the 24h cleanup */ }
    if (s.outcome === "conflict") {
      process.stderr.write(`control-migration: conflict sid=${sid} name=${s.name}: destination kept, legacy ${s.src} left in place\n`);
      logLine(wf, `conflict sid=${sid} name=${s.name} legacy=${s.src} destination kept`);
    } else {
      try { unlinkQuiet(s.src); } catch (_) { /* retried on the next run as identical */ }
    }
    rows.push({ sid, name: s.name, outcome: s.outcome });
  }
  for (const s of vanished) {
    if (fs.existsSync(s.dst)) rows.push({ sid, name: s.name, outcome: "identical" });
  }
  return rows;
}

module.exports = { applyBatch, logLine };
