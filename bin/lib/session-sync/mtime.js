"use strict";
// Transcript mtime from its last entry timestamp (#2658); option-like values never reach touch.

const fs = require("node:fs");
const path = require("node:path");
const { splitLines } = require("./jsonl");

function decideMtime(text) {
  let ts = null;
  for (const line of splitLines(text || "")) {
    try {
      const o = JSON.parse(line);
      if (o && typeof o.timestamp === "string") ts = o.timestamp;
    } catch (_) { /* non-JSON line carries no timestamp */ }
  }
  if (ts === null) return { ok: false, reason: "no-timestamp" };
  if (ts.startsWith("-")) return { ok: false, reason: "option-like" };
  const ms = Date.parse(ts);
  if (!Number.isFinite(ms)) return { ok: false, reason: "unparseable" };
  return { ok: true, date: new Date(ms), timestamp: ts };
}

const REASON_TEXT = {
  "no-timestamp": "no timestamp",
  "option-like": "rejecting option-like timestamp",
  "unparseable": "unparseable timestamp",
};

function* transcripts(dir) {
  let entries = [];
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch (_) {
    return;
  }
  for (const e of entries) {
    const p = path.join(dir, e.name);
    if (e.isDirectory() && e.name !== ".git") yield* transcripts(p);
    else if (e.isFile() && e.name.endsWith(".jsonl") && e.name !== ".history.jsonl") yield p;
  }
}

// restoreAll(projectsDir, {dryRun, style}, out, err) — the cc-session-mtime sweep; never fatal.
function restoreAll(projectsDir, { dryRun = false, style = "touch" } = {}, out, err) {
  if (!fs.existsSync(projectsDir)) {
    err(`warn: projects dir not found: ${projectsDir}`);
    return;
  }
  for (const file of transcripts(projectsDir)) {
    let text = "";
    try {
      text = fs.readFileSync(file, "utf8");
    } catch (_) {
      continue;
    }
    const d = decideMtime(text);
    if (!d.ok) {
      err(`warn: ${REASON_TEXT[d.reason]} in ${file}`);
    } else if (dryRun) {
      out(style === "set" ? `would set ${file} mtime to ${d.timestamp}` : `would touch -d ${d.timestamp} -- ${file}`);
    } else {
      try {
        fs.utimesSync(file, d.date, d.date);
      } catch (e) {
        err(`warn: failed to set mtime on ${file}: ${e.message}`);
      }
    }
  }
}

module.exports = { decideMtime, restoreAll };
