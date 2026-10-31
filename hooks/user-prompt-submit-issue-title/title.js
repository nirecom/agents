"use strict";
// run(input, deps) -> the session title to emit, or null. Names the session after the issues
// it works on; the chain record makes each title emit once, so a later /rename stays.
// deps: {fetchTitle?(ref), now?(), spawnSync?} — test seams; fail-open, never throws.

const { refsFor, refKey, refLabel } = require("./target");
const { recordSid, readRecord, writeRecord, setNewest } = require("./record");

const ORIGIN_TIMEOUT_MS = 1000;
const TRACKER_TIMEOUT_MS = 3000;
const MAX_ATTEMPTS = 3;
const COOLDOWN_MS = 10 * 60 * 1000;
const TITLE_MAX = 200;

function fetchViaForge(ref, cwd, spawnSync) {
  const { originUrl } = require("../workflow-gate/gh-detect");
  const fr = require("../lib/forge-router");
  const url = originUrl(cwd, { timeoutMs: ORIGIN_TIMEOUT_MS, spawnSync });
  if (!url) return null;
  const { type } = fr.resolveCodehostDescriptor(url, cwd);
  const tracker = fr.resolveTrackerDescriptor({ FORGE_TRACKER: fr.readTrackerConfig(cwd) }, type);
  return tracker.issueTitle(url, ref, { timeoutMs: TRACKER_TIMEOUT_MS, projectRoot: cwd, spawnSync });
}

function cleanTitle(raw) {
  if (typeof raw !== "string") return null;
  // eslint-disable-next-line no-control-regex
  const t = raw.replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim().slice(0, TITLE_MAX);
  return t || null;
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

function run(input, deps) {
  try {
    const { readState, SESSION_ID_VALID_RE } = require("../workflow-state");
    const { toWindowsPath } = require("../lib/branch-diff");
    const d = deps || {};
    const sid = input && input.session_id;
    if (typeof sid !== "string" || !SESSION_ID_VALID_RE.test(sid)) return null;
    const state = readState(sid);
    if (!state) return null;
    const recSid = recordSid(sid, state);
    if (!recSid) return null;
    const refs = refsFor(sid, state, input.prompt);
    if (!Array.isArray(refs) || refs.length === 0) return null;
    const rec = readRecord(recSid);
    const before = JSON.stringify(rec);
    const now = typeof d.now === "function" ? d.now() : Date.now();
    const cwd = toWindowsPath(typeof input.cwd === "string" && input.cwd ? input.cwd : process.cwd());
    const title = titleFor(refs[0], rec, d, cwd, now);
    const candidate = title ? `${refs.map(refLabel).join(" ")} ${title}` : null;
    if (!candidate || candidate === rec.last_emitted) {
      if (JSON.stringify(rec) !== before) writeRecord(recSid, rec);
      return null;
    }
    rec.last_emitted = candidate;
    return writeRecord(recSid, rec) ? candidate : null;
  } catch (_) {
    return null;
  }
}

module.exports = { run, ORIGIN_TIMEOUT_MS, TRACKER_TIMEOUT_MS, MAX_ATTEMPTS, COOLDOWN_MS, TITLE_MAX };
