"use strict";
// The chain record <WORKFLOW_STATE_DIR>/<first_sid>.control/issue-title.json:
// {v:1, last_emitted, titles:{<key>:{title}}, failures:{<key>:{attempts,last_failed_at}}}.
// Where it lives, whether this session may use it, and its read / atomic write.

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const RECORD_FILE = "issue-title.json";
const KEEP = 20;

const present = (v) => v != null && v !== "";

// recordSid(sid, state) -> the sid whose control dir holds the record, or null when this
// session is neither a chain downstream nor a confirmed root (SessionStart-created, no ancestry).
function recordSid(sid, state) {
  const { resolveFirstSid, isValidSid } = require("../workflow-state/state-ancestry");
  const first = resolveFirstSid(sid, state);
  if (first !== sid) return isValidSid(first) ? first : null;
  const prev = state.previous_session_ids;
  const hasAncestry = present(state.first_session_id) || (Array.isArray(prev) ? prev.length > 0 : prev != null);
  const ctx = state.session_start_context;
  if (hasAncestry || !ctx || typeof ctx.transcript_path !== "string") return null;
  return sid;
}

function emptyRecord() {
  return { v: 1, last_emitted: null, titles: {}, failures: {} };
}

const isMap = (v) => v && typeof v === "object" && !Array.isArray(v);

// readRecord(sid) -> the record (empty when absent or malformed); throws when the control dir is unusable.
function readRecord(sid) {
  const { controlPath } = require("../workflow-state/state-io/control-dir");
  const file = controlPath(sid, RECORD_FILE);
  let body;
  try {
    body = JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (_) {
    return emptyRecord();
  }
  if (!isMap(body)) return emptyRecord();
  return {
    v: 1,
    last_emitted: typeof body.last_emitted === "string" ? body.last_emitted : null,
    titles: isMap(body.titles) ? body.titles : {},
    failures: isMap(body.failures) ? body.failures : {},
  };
}

// setNewest(map, key, value) — re-inserts key as the newest entry and keeps the newest KEEP.
function setNewest(map, key, value) {
  delete map[key];
  map[key] = value;
  const keys = Object.keys(map);
  for (const k of keys.slice(0, Math.max(0, keys.length - KEEP))) delete map[k];
}

// writeRecord(sid, rec) -> true when the record was published (temp file + rename).
function writeRecord(sid, rec) {
  let tmp = null;
  try {
    const { controlPath } = require("../workflow-state/state-io/control-dir");
    const dst = controlPath(sid, RECORD_FILE, { forWrite: true });
    tmp = path.join(path.dirname(dst), `${RECORD_FILE}.${process.pid}.${crypto.randomBytes(4).toString("hex")}.tmp`);
    fs.writeFileSync(tmp, JSON.stringify(rec) + "\n", { flag: "wx" });
    fs.renameSync(tmp, dst);
    return true;
  } catch (_) {
    if (tmp) { try { fs.unlinkSync(tmp); } catch (_e) { /* best effort */ } }
    return false;
  }
}

module.exports = { RECORD_FILE, KEEP, recordSid, readRecord, writeRecord, setNewest };
