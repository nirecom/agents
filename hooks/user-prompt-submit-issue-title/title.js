"use strict";
// run(input, deps) -> the session name to emit, or null (#299, #2668, #2993). A session with issues gets
// the work name, one without gets the none name once, unless its transcript already holds a custom-title
// (a /rename from before the hook): that name stays. The record makes each name emit once, so a later
// /rename stays too. After a resume the first prompt gives the name again while it is still ours.
// deps: {fetchTitle?(ref), now?(), spawnSync?} — test seams; fail-open, never throws.

const fs = require("fs");
const path = require("path");
const { targetFor, refKey } = require("./target");
const { recordSid, readRecord, writeRecord, setNewest } = require("./record");
const SN = require("../lib/session-name");

const ORIGIN_TIMEOUT_MS = 1000;
const TRACKER_TIMEOUT_MS = 3000;
const MAX_ATTEMPTS = 3;
const COOLDOWN_MS = 10 * 60 * 1000;
const { TITLE_MAX, cleanTitle } = SN;

function originOf(cwd, spawnSync) {
  const { originUrl } = require("../workflow-gate/gh-detect");
  return originUrl(cwd, { timeoutMs: ORIGIN_TIMEOUT_MS, spawnSync });
}

function fetchViaForge(ref, cwd, spawnSync) {
  const fr = require("../lib/forge-router");
  const url = originOf(cwd, spawnSync);
  if (!url) return null;
  const { type } = fr.resolveCodehostDescriptor(url, cwd);
  const tracker = fr.resolveTrackerDescriptor({ FORGE_TRACKER: fr.readTrackerConfig(cwd) }, type);
  return tracker.issueTitle(url, ref, { timeoutMs: TRACKER_TIMEOUT_MS, projectRoot: cwd, spawnSync });
}

// repoFor(cwd, spawnSync) -> the repo part of the origin URL, else the cwd basename, else null.
function repoFor(cwd, spawnSync) {
  let url;
  try { url = originOf(cwd, spawnSync); } catch (_) { url = null; }
  return SN.repoNameOf(url) || cleanTitle(path.basename(cwd));
}

// titleFor(ref, rec, d, cwd, now) -> the cached or freshly fetched title; updates rec in place.
function titleFor(ref, rec, d, cwd, now) {
  const key = refKey(ref);
  const hit = rec.titles[key];
  if (hit && typeof hit.title === "string" && hit.title) return hit.title;
  const fail = rec.failures[key];
  const attempts = fail && Number.isInteger(fail.attempts) ? fail.attempts : 0;
  if (attempts >= MAX_ATTEMPTS) return null;
  if (fail && typeof fail.last_failed_at === "number" && now - fail.last_failed_at < COOLDOWN_MS) return null;
  let title;
  try {
    title = cleanTitle(typeof d.fetchTitle === "function" ? d.fetchTitle(ref) : fetchViaForge(ref, cwd, d.spawnSync));
  } catch (_) {
    title = null;
  }
  if (title) {
    setNewest(rec.titles, key, { title });
    delete rec.failures[key];
  } else {
    setNewest(rec.failures, key, { attempts: attempts + 1, last_failed_at: now });
  }
  return title;
}

// latestCustomTitle(file) -> the customTitle of the transcript's last custom-title record, or null
// when the transcript is unreadable or carries none.
function latestCustomTitle(file) {
  let lines;
  try { lines = fs.readFileSync(file, "utf8").split("\n"); } catch (_) { return null; }
  for (let i = lines.length - 1; i >= 0; i--) {
    if (!lines[i].includes("custom-title")) continue;
    try {
      const r = JSON.parse(lines[i]);
      if (r && r.type === "custom-title" && typeof r.customTitle === "string") return r.customTitle;
    } catch (_) { /* not a record */ }
  }
  return null;
}

// resumeName(sid, state, input, rec, toWindowsPath) -> the emitted name again (its suffix moved to this session id)
// when the transcript's latest custom-title still equals it; null otherwise (a /rename wins).
function resumeName(sid, state, input, rec, toWindowsPath) {
  if (typeof rec.last_emitted !== "string") return null;
  const ctx = state && state.session_start_context;
  const raw = typeof input.transcript_path === "string" && input.transcript_path ? input.transcript_path : ctx && ctx.transcript_path;
  if (typeof raw !== "string" || !raw) return null;
  if (latestCustomTitle(toWindowsPath(raw)) !== rec.last_emitted) return null;
  const m = rec.last_emitted.match(SN.SESSION_NAME_SUFFIX_RE);
  return m ? rec.last_emitted.slice(0, m.index) + SN.sessionSuffix(sid) : rec.last_emitted;
}

// candidateFor(target, rec, d, cwd, now, sid, transcriptPath) -> the name this prompt asks for, or null.
// A transcript that already carries a custom-title (a /rename from before the record, even an empty one) is the user's: no none name.
function candidateFor(target, rec, d, cwd, now, sid, transcriptPath) {
  if (target.kind === "none") {
    if (rec.last_emitted !== null) return null;
    if (transcriptPath && latestCustomTitle(transcriptPath) !== null) return null;
    const repo = repoFor(cwd, d.spawnSync);
    return repo ? SN.composeSessionName({ kind: "none", repo, sessionId: sid }) : null;
  }
  const title = titleFor(target.refs[0], rec, d, cwd, now);
  if (!title) return null;
  return SN.composeSessionName({ kind: target.kind, refs: target.refs, title: target.objective || title, sessionId: sid });
}

function run(input, deps) {
  try {
    const { readState, SESSION_ID_VALID_RE } = require("../workflow-state");
    const { toWindowsPath } = require("../lib/branch-diff");
    const d = deps || {};
    const sid = input && input.session_id;
    if (typeof sid !== "string" || !SESSION_ID_VALID_RE.test(sid)) return null;
    const state = readState(sid);
    // No state: no chain to follow, so the record lives in this session's own control dir.
    const recSid = state ? recordSid(sid, state) : sid;
    if (!recSid) return null;
    const resumed = SN.takeResumeMark(sid);
    const target = targetFor(sid, state, input.prompt);
    const rec = readRecord(recSid);
    const before = JSON.stringify(rec);
    const now = typeof d.now === "function" ? d.now() : Date.now();
    const cwd = toWindowsPath(typeof input.cwd === "string" && input.cwd ? input.cwd : process.cwd());
    const ctx = state && state.session_start_context;
    const rawT = typeof input.transcript_path === "string" && input.transcript_path ? input.transcript_path : ctx && ctx.transcript_path;
    const transcriptPath = typeof rawT === "string" && rawT ? toWindowsPath(rawT) : null;
    let name = candidateFor(target, rec, d, cwd, now, sid, transcriptPath);
    if (name === rec.last_emitted) name = null;
    if (!name && resumed) name = resumeName(sid, state, input, rec, toWindowsPath);
    if (!name) {
      if (JSON.stringify(rec) !== before) writeRecord(recSid, rec);
      return null;
    }
    rec.last_emitted = name;
    return writeRecord(recSid, rec) ? name : null;
  } catch (_) {
    return null;
  }
}

module.exports = { run, titleFor, repoFor, ORIGIN_TIMEOUT_MS, TRACKER_TIMEOUT_MS, MAX_ATTEMPTS, COOLDOWN_MS, TITLE_MAX };
