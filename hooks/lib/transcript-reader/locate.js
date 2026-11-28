"use strict";
// hooks/lib/transcript-reader/locate.js — find a session's transcript by sid when the given path
// reads as nothing (#2843): the cwd's project dir first, then a bounded one-level scan of the base.

const fs = require("fs");
const path = require("path");
const { encodeCwd, getTranscriptBase } = require("../transcript-paths");

const SCAN_MAX_DIRS = 200;
const SCAN_DEADLINE_MS = 150;
const SID_RE = /^[A-Za-z0-9_-]+$/;

function toWin(p) {
  return require("../branch-diff").toWindowsPath(p);
}

function sameKey(p) {
  const r = path.resolve(toWin(p));
  return process.platform === "win32" ? r.toLowerCase() : r;
}

function sidOf(input) {
  if (typeof input.session_id === "string" && SID_RE.test(input.session_id)) return input.session_id;
  const p = input.transcript_path;
  if (typeof p !== "string" || !p.endsWith(".jsonl")) return "";
  const base = path.basename(p, ".jsonl");
  return SID_RE.test(base) ? base : "";
}

// readableMtime -> the mtime (ms) of a non-empty regular file, or -1.
function readableMtime(p) {
  try {
    const st = fs.statSync(p);
    return st.isFile() && st.size > 0 ? st.mtimeMs : -1;
  } catch (_) {
    return -1;
  }
}

const readable = (p) => readableMtime(p) >= 0;

// scan -> the newest-mtime copy, or null; at SCAN_MAX_DIRS or SCAN_DEADLINE_MS it stops and returns the
// newest copy seen so far, so a stale copy never wins over a fresher one it has already passed.
function scan(base, file, excluded) {
  const startedAt = Date.now();
  let dirs;
  try {
    dirs = fs.readdirSync(base, { withFileTypes: true });
  } catch (_) {
    return null;
  }
  let seen = 0;
  let best = null;
  let bestMtime = -1;
  for (const d of dirs) {
    if (!d.isDirectory()) continue;
    if (seen++ >= SCAN_MAX_DIRS || Date.now() - startedAt > SCAN_DEADLINE_MS) break;
    const p = path.join(base, d.name, file);
    if (excluded(p)) continue;
    const m = readableMtime(p);
    if (m > bestMtime) {
      best = p;
      bestMtime = m;
    }
  }
  return best;
}

function search(input, exclude) {
  const i = input && typeof input === "object" ? input : {};
  const sid = sidOf(i);
  if (!sid) return { hit: null, sid };
  const ex = (Array.isArray(exclude) ? exclude : [exclude]).filter((p) => typeof p === "string" && p).map(sameKey);
  const excluded = (p) => ex.includes(sameKey(p));
  const base = getTranscriptBase();
  const file = `${sid}.jsonl`;
  if (typeof i.cwd === "string" && i.cwd) {
    const c1 = path.join(base, encodeCwd(toWin(i.cwd)), file);
    if (!excluded(c1) && readable(c1)) return { hit: { path: c1, source: "cwd", sid }, sid };
  }
  const found = scan(base, file, excluded);
  return { hit: found ? { path: found, source: "scan", sid } : null, sid };
}

// locateTranscript(input, {exclude}) -> {path, source: "cwd"|"scan", sid}, or null when none is found.
function locateTranscript(input, { exclude } = {}) {
  try {
    return search(input, exclude).hit;
  } catch (_) {
    return null;
  }
}

// relocate(input, given) -> the found path, or null; names the move or the miss on stderr.
// Without a sid there is nothing to search for, so it stays silent.
function relocate(input, given) {
  let r;
  try {
    r = search(input, given);
  } catch (_) {
    return null;
  }
  try {
    if (r.hit) process.stderr.write(`transcript-reader: relocated ${given || "(none)"} -> ${r.hit.path}\n`);
    else if (r.sid) process.stderr.write(`transcript-reader: unreadable ${given || "(none)"} (sid ${r.sid})\n`);
  } catch (_) { /* stderr is best-effort */ }
  return r.hit ? r.hit.path : null;
}

module.exports = { locateTranscript, relocate, SCAN_MAX_DIRS, SCAN_DEADLINE_MS };
