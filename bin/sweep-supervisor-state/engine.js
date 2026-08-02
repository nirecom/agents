#!/usr/bin/env node
"use strict";

// Directory walker + scope guard + backup writer for sweep-supervisor-state.sh.
// Emits a single-line JSON summary on stdout. The shell wrapper owns argv
// grammar, usage errors, and human-readable rendering.
//
// Usage: engine.js --plans-dir <dir> [--apply] [--session <SID>]
//                  [--current-session <SID>]

const fs = require("fs");
const path = require("path");
const { scrub } = require("./scrub");

const STATE_SUFFIX = "-supervisor-state.json";
const BACKUP_ROOT_NAME = ".sweep-supervisor-state-backup";
const RECENT_WINDOW_MS = 24 * 60 * 60 * 1000;

function parseArgs(argv) {
  const opts = { plansDir: null, apply: false, session: null, currentSession: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--plans-dir") opts.plansDir = argv[++i];
    else if (a === "--apply") opts.apply = true;
    else if (a === "--session") opts.session = argv[++i];
    else if (a === "--current-session") opts.currentSession = argv[++i];
  }
  return opts;
}

function utcStamp(d) {
  return d.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}Z$/, "Z");
}

function sessionIdOf(state, file) {
  if (state && typeof state.session_id === "string" && state.session_id.length > 0) {
    return state.session_id;
  }
  return path.basename(file, STATE_SUFFIX);
}

// isLive reports whether the session is still in flight and therefore off
// limits. Unconditional — there is no override flag.
function isLive(state, sessionId, currentSession) {
  if (currentSession && sessionId === currentSession) return true;
  const alert = state.alert || {};
  const audit = state.audit || {};
  if (alert.alert_phase === "pending") return true;
  if (audit.audit_phase === "pending" || audit.audit_phase === "in_progress") return true;
  return false;
}

function isRecent(state, now) {
  const raw = state.last_updated;
  if (typeof raw !== "string") return false;
  const t = Date.parse(raw);
  if (Number.isNaN(t)) return false;
  return now - t < RECENT_WINDOW_MS;
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  const summary = {
    scanned: 0,
    skipped_live: 0,
    skipped_recent: 0,
    files_contaminated: 0,
    files_modified: 0,
    records_removed: 0,
    files_emptied: 0,
    files_skipped_unparsable: 0,
    backup_dir: "",
    errors: [],
    details: [],
    apply: opts.apply,
  };

  const plansDir = opts.plansDir;
  let entries = [];
  try {
    entries = fs.readdirSync(plansDir).filter((n) => n.endsWith(STATE_SUFFIX)).sort();
  } catch (e) {
    summary.errors.push("plans dir unreadable: " + (e && e.code ? e.code : "unknown"));
    process.stdout.write(JSON.stringify(summary) + "\n");
    return;
  }

  const now = Date.now();
  const pending = []; // { file, cleaned, removed, raw }

  for (const name of entries) {
    const file = path.join(plansDir, name);
    summary.scanned++;

    let raw;
    let state;
    try {
      raw = fs.readFileSync(file, "utf8");
      state = JSON.parse(raw);
    } catch (_) {
      summary.files_skipped_unparsable++;
      summary.details.push({ file: name, status: "unparsable" });
      continue;
    }

    const sid = sessionIdOf(state, name);
    if (opts.session && sid !== opts.session) {
      summary.details.push({ file: name, status: "out_of_scope" });
      continue;
    }
    if (isLive(state, sid, opts.currentSession)) {
      summary.skipped_live++;
      summary.details.push({ file: name, status: "skipped_live" });
      continue;
    }
    if (isRecent(state, now)) {
      summary.skipped_recent++;
      summary.details.push({ file: name, status: "skipped_recent" });
      continue;
    }

    const { cleaned, removed } = scrub(state);
    if (removed.length === 0) {
      summary.details.push({ file: name, status: "clean" });
      continue;
    }
    summary.files_contaminated++;
    summary.details.push({
      file: name,
      status: opts.apply ? "modified" : "candidate",
      records_removed: removed.length,
    });
    pending.push({ file, name, cleaned, removed, raw });
  }

  if (!opts.apply || pending.length === 0) {
    process.stdout.write(JSON.stringify(summary) + "\n");
    return;
  }

  // Backup is created lazily — only when something is actually about to change.
  const backupRoot = path.join(plansDir, BACKUP_ROOT_NAME);
  let backupDir = path.join(backupRoot, utcStamp(new Date()));
  let attempt = 1;
  while (fs.existsSync(backupDir)) {
    attempt++;
    backupDir = path.join(backupRoot, utcStamp(new Date()) + "-" + attempt);
  }
  try {
    fs.mkdirSync(backupDir, { recursive: true });
  } catch (e) {
    summary.errors.push("backup dir creation failed: " + (e && e.code ? e.code : "unknown"));
    process.stdout.write(JSON.stringify(summary) + "\n");
    return;
  }
  summary.backup_dir = backupDir;

  const manifestFiles = [];
  for (const item of pending) {
    try {
      fs.writeFileSync(path.join(backupDir, item.name), item.raw);
      fs.writeFileSync(item.file, JSON.stringify(item.cleaned, null, 2));
    } catch (e) {
      summary.errors.push(item.name + ": " + (e && e.code ? e.code : "write failed"));
      continue;
    }
    summary.files_modified++;
    summary.records_removed += item.removed.length;
    if (item.cleaned.layer1.findings.length === 0) summary.files_emptied++;
    manifestFiles.push({
      file: item.name,
      records_removed: item.removed.length,
      removed_record_details: item.removed,
    });
  }

  try {
    fs.writeFileSync(
      path.join(backupDir, "manifest.json"),
      JSON.stringify(
        { generated_at: new Date().toISOString(), plans_dir: plansDir, files: manifestFiles },
        null,
        2
      )
    );
  } catch (e) {
    summary.errors.push("manifest write failed: " + (e && e.code ? e.code : "unknown"));
  }

  process.stdout.write(JSON.stringify(summary) + "\n");
}

main();
