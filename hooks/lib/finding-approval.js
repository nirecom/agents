// hooks/lib/finding-approval.js
// SSOT for the finding-filing approval record (#2019): `<state dir>/<sid>.finding-filing-approval`,
// JSON {version:1, session_id, pending:[], records:[]}. Only hooks write it (protected marker);
// bin/finding-filing-gate consumes one approval per filing. Write disciplines:
//  - writer 1 (UserPromptSubmit) resets the whole file: tmp + rename, or unlink.
//  - every read-modify-write (writer 2's pending / answer, consumeApproval's write-back) first claims
//    the exact bytes it read with consumeExactFile, then recreates the file with exclusive create (wx).
//    A writer that lost the claim, or hit EEXIST, never overwrites: hooks retry from a fresh read,
//    the consumer drops its remainder (fail-closed: the dropped approval reads as "no approval").
"use strict";

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { consumeExactFile } = require("./consume-exact-file");
const { promptInvokesSkill } = require("./prompt-invokes-skill");

const FINDING_APPROVAL_MARKER_KIND = "finding-filing-approval";
const APPROVAL_DIALOG_IDS = Object.freeze([
  "issue-create.confirm-gate",
  "notes-promotion.final-list",
  "mid-workflow-findings.blocking-file",
]);
const FINDING_APPROVAL_SKILL = "issue-create";
const APPROVAL_MAX_AGE_MS = 2 * 60 * 60 * 1000;
const APPROVAL_FUTURE_TOLERANCE_MS = 60 * 1000;
const KEY_RE = /^[0-9a-f]{8}$/;
const LABEL_KEY_RE = /\[k:([0-9a-f]{8})\]/g;
const MUTATE_ATTEMPTS = 5;

const sha8 = (text) => crypto.createHash("sha256").update(String(text), "utf8").digest("hex").slice(0, 8);

// findingKey(section, body): the key of a notes entry (body without markers; line numbers move).
function findingKey(section, body) {
  return sha8(`${section}\n${body}`);
}

// titleKey(title): the key of a direct proposal that never went through a list.
function titleKey(title) {
  return sha8(title);
}

function isApprovalDialog(dialogId) {
  return APPROVAL_DIALOG_IDS.includes(dialogId);
}

function approvalPathFor(sid) {
  const { getSessionStateDir } = require("../workflow-state/state-io/state-root");
  return path.join(getSessionStateDir(sid), `${sid}.${FINDING_APPROVAL_MARKER_KIND}`);
}

function promptInvokesFilingSkill(prompt) {
  return promptInvokesSkill(prompt, FINDING_APPROVAL_SKILL);
}

function emptyFile(sid) {
  return { version: 1, session_id: sid, pending: [], records: [] };
}

function parseApproval(raw, sid) {
  let j;
  try { j = JSON.parse(raw); } catch (_e) { return null; }
  if (!j || typeof j !== "object" || Array.isArray(j) || j.version !== 1 || j.session_id !== sid) return null;
  return {
    version: 1,
    session_id: sid,
    pending: Array.isArray(j.pending) ? j.pending : [],
    records: Array.isArray(j.records) ? j.records : [],
  };
}

function readRaw(file) {
  try { return fs.readFileSync(file, "utf8"); } catch (e) {
    if (e && e.code === "ENOENT") return null;
    throw e;
  }
}

// writer 1: replace the file with one typed-command record (tmp + rename).
function writeTypedCommand(sid, nowMs) {
  const file = approvalPathFor(sid);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const body = emptyFile(sid);
  body.records.push({ type: "typed-command", at: new Date(typeof nowMs === "number" ? nowMs : Date.now()).toISOString() });
  const tmp = `${file}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(body), { mode: 0o600 });
  fs.renameSync(tmp, file);
}

function removeApprovalFile(sid) {
  try { fs.unlinkSync(approvalPathFor(sid)); } catch (_e) { /* absent is the goal */ }
}

// mutateApproval(sid, fn, { create }): claim → fn(state) → recreate with wx. fn returns the new
// state, or null to leave the file as it is. Returns fn's last result, or null when nothing was written.
function mutateApproval(sid, fn, opts) {
  const file = approvalPathFor(sid);
  for (let i = 0; i < MUTATE_ATTEMPTS; i++) {
    const raw = readRaw(file);
    if (raw === null && !(opts && opts.create)) return null;
    const state = raw === null ? emptyFile(sid) : parseApproval(raw, sid);
    if (!state) return null;
    const next = fn(state);
    if (!next) return null;
    if (raw !== null && consumeExactFile(file, raw) !== "consumed") continue;
    if (raw === null) fs.mkdirSync(path.dirname(file), { recursive: true });
    try {
      fs.writeFileSync(file, JSON.stringify(next), { flag: "wx", mode: 0o600 });
      return next;
    } catch (e) {
      if (!e || e.code !== "EEXIST") throw e;
    }
  }
  return null;
}

// writer 2, first half (PreToolUse): one pending entry per approval dialog call.
function addPending(sid, entry) {
  return mutateApproval(sid, (s) => {
    s.pending = s.pending.filter((p) => p && p.tool_use_id !== entry.tool_use_id).concat([entry]);
    return s;
  }, { create: true });
}

// writer 2, second half (PostToolUse): take the pending entry out; append `record` when
// decide(pending) returns one. Returns the taken pending entry, or null.
function takePendingAndRecord(sid, toolUseId, decide) {
  let taken = null;
  mutateApproval(sid, (s) => {
    const p = s.pending.find((x) => x && x.tool_use_id === toolUseId);
    if (!p) return null;
    taken = p;
    s.pending = s.pending.filter((x) => x !== p);
    const rec = decide(p);
    if (rec) s.records.push(rec);
    return s;
  });
  return taken;
}

// labelKeys(value): the keys of the chosen labels — one key per label; a label holding 0 or 2+
// keys contributes nothing. Values may be a string, an array, or a comma-joined string.
function labelKeys(value) {
  const labels = [];
  const push = (v) => {
    if (typeof v !== "string") return;
    for (const part of v.split(/(?<=\[k:[0-9a-f]{8}\])\s*,\s*/)) labels.push(part);
  };
  if (Array.isArray(value)) value.forEach(push); else push(value);
  const keys = [];
  for (const label of labels) {
    const found = Array.from(label.matchAll(LABEL_KEY_RE), (m) => m[1]);
    if (found.length === 1 && !keys.includes(found[0])) keys.push(found[0]);
  }
  return keys;
}

function recordAlive(rec, nowMs) {
  if (!rec || typeof rec !== "object") return false;
  const at = typeof rec.at === "number" ? rec.at : Date.parse(rec.at);
  if (!Number.isFinite(at)) return false;
  return nowMs - at <= APPROVAL_MAX_AGE_MS && at - nowMs <= APPROVAL_FUTURE_TOLERANCE_MS;
}

function matchRecord(records, key, nowMs) {
  for (let i = 0; i < records.length; i++) {
    const r = records[i];
    if (!recordAlive(r, nowMs)) continue;
    if (r.type === "typed-command") return i;
    if (r.type === "askuser-answer" && Array.isArray(r.keys) && r.keys.includes(key)) return i;
  }
  return -1;
}

// consumeApproval(sid, key, nowMs) -> { approved, reason }. Reads only this session's file.
function consumeApproval(sid, key, nowMs) {
  const now = typeof nowMs === "number" ? nowMs : Date.now();
  let file;
  let raw;
  try {
    file = approvalPathFor(sid);
    raw = readRaw(file);
  } catch (_e) {
    return { approved: false, reason: "approval file unreadable" };
  }
  if (raw === null) return { approved: false, reason: "no approval record" };
  const state = parseApproval(raw, sid);
  if (!state) return { approved: false, reason: "approval file invalid or of another session" };
  const idx = matchRecord(state.records, String(key), now);
  if (idx < 0) return { approved: false, reason: "no matching approval" };
  if (consumeExactFile(file, raw) !== "consumed") return { approved: false, reason: "approval claim lost" };
  const rec = state.records[idx];
  if (rec.type === "askuser-answer") {
    const keys = rec.keys.filter((k) => k !== String(key));
    if (keys.length > 0) state.records[idx] = Object.assign({}, rec, { keys });
    else state.records.splice(idx, 1);
  } else {
    state.records.splice(idx, 1);
  }
  if (state.records.length > 0 || state.pending.length > 0) {
    try {
      fs.writeFileSync(file, JSON.stringify(state), { flag: "wx", mode: 0o600 });
    } catch (_e) { /* EEXIST: the hook's newer file wins; the remainder is dropped */ }
  }
  return { approved: true, reason: rec.type };
}

module.exports = {
  FINDING_APPROVAL_MARKER_KIND,
  FINDING_APPROVAL_SKILL,
  APPROVAL_DIALOG_IDS,
  APPROVAL_MAX_AGE_MS,
  APPROVAL_FUTURE_TOLERANCE_MS,
  KEY_RE,
  findingKey,
  titleKey,
  isApprovalDialog,
  approvalPathFor,
  promptInvokesFilingSkill,
  writeTypedCommand,
  removeApprovalFile,
  addPending,
  takePendingAndRecord,
  labelKeys,
  consumeApproval,
};
