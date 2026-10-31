"use strict";
// readStateHandoff — the state handoff reader (#2652). Every reader (--from, --list, the
// supervisor codex input) passes the target sid here and never resolves a state file or a legacy
// handoff.md itself. Formatting belongs to each reader; this returns every entry, unfolded.

const fs = require("fs");
const path = require("path");
const STATE_IO = path.join(__dirname, "..", "..", "workflow-state", "state-io");
const core = require(path.join(STATE_IO, "core"));
const { assertStreamIntegrity } = require(path.join(STATE_IO, "projection"));
// The read-side bound is the whole event's budget, not the writer's 300-char field cap: the writer
// already enforces that, and each reader applies its own size cap when it formats.
const { EVENT_MAX_BYTES } = require(path.join(STATE_IO, "state-handoff-record-schema"));
const READ_FIELD_MAX_CHARS = EVENT_MAX_BYTES;
const { sanitizeUntrustedField } = require("../output-sanitize");
// --- BEGIN temporary: handoff.md -> state handoff record migration added 2026-10-29 ---
// deletion-condition: remove once 30 days (the control dir lifetime) have passed since merge and neither a control dir holding a legacy handoff.md nor a plans-dir <sid>-handoff.md remains
const { mergeLegacyEntries } = require("./legacy-handoff-md");
// --- END temporary: handoff.md -> state handoff record migration ---

const RESET_KEY = "reset-from";

// { state, error }: state is null when there is no file; error when a file exists but cannot be read.
function readOwnState(sid) {
  let raw;
  try {
    raw = core.readRawState(sid);
  } catch (_e) {
    return { state: null, error: true };
  }
  if (raw === null) {
    // readRawState answers null for an unreadable file too; only a missing file is "no state".
    let present;
    try { present = fs.existsSync(core.getStatePath(sid)); } catch (_e) { present = false; }
    return { state: null, error: present };
  }
  if (typeof raw !== "object" || Array.isArray(raw)) return { state: null, error: true };
  // A pre-events (v1) file has no `events` key and holds no record. A v2+ file always has the
  // stream, so a missing or non-array `events` there is damage, and reading it as "no record"
  // would hide that from every reader.
  const hasEvents = Object.prototype.hasOwnProperty.call(raw, "events");
  const streamVersion = typeof raw.version === "number" && raw.version >= 2;
  if ((hasEvents || streamVersion) && !Array.isArray(raw.events)) return { state: null, error: true };
  // A stream readState would refuse (seq gap or duplicate, malformed event) is damage too.
  if (Array.isArray(raw.events)) {
    try { assertStreamIntegrity(raw.events); } catch (_e) { return { state: null, error: true }; }
  }
  return { state: raw, error: false };
}

function stateEntries(state) {
  const events = Array.isArray(state.events) ? state.events : [];
  const boundary = Number.isInteger(state.upstream_copy_seq) ? state.upstream_copy_seq : 0;
  const out = [];
  for (const e of events) {
    if (!e || typeof e !== "object" || (Number.isInteger(e.seq) && e.seq <= boundary)) continue;
    if (e.kind === "state_handoff_record") {
      out.push({ at: e.at, cls: e.cls, origin: e.origin, at_step: e.at_step, record_key: e.record_key, summary: e.summary, pointer: e.pointer });
    } else if (e.kind === "reset") {
      // The reset event is the SSOT of a RESET; the entry is derived here for display only.
      out.push({ at: e.at, cls: "E", origin: e.origin, at_step: e.from_step, record_key: RESET_KEY, summary: `${e.from_step}: ${e.reason}`, pointer: "-" });
    }
  }
  return out;
}

function cleanField(value) {
  return sanitizeUntrustedField(value, READ_FIELD_MAX_CHARS);
}

function clean(entry) {
  const out = {};
  for (const f of ["at", "cls", "origin", "at_step", "record_key", "summary", "pointer"]) {
    out[f] = cleanField(entry[f]);
  }
  return out;
}

// readStateHandoff(sid) -> { entries, errors }. errors names the unreadable sources ("state",
// "legacy-handoff-md"); a missing file is not an error. Never throws.
function readStateHandoff(sid) {
  const entries = [];
  const errors = [];
  if (typeof sid !== "string" || !core.SESSION_ID_VALID_RE.test(sid)) return { entries, errors };
  const own = readOwnState(sid);
  if (own.error) errors.push("state");
  if (own.state) entries.push(...stateEntries(own.state));
  // --- BEGIN temporary: handoff.md -> state handoff record migration added 2026-10-29 ---
  // deletion-condition: remove once 30 days (the control dir lifetime) have passed since merge and neither a control dir holding a legacy handoff.md nor a plans-dir <sid>-handoff.md remains
  mergeLegacyEntries(sid, entries, errors, RESET_KEY, cleanField);
  // --- END temporary: handoff.md -> state handoff record migration ---

  const ordered = entries.map(clean).map((e, i) => ({ e, i }));
  ordered.sort((a, b) => (a.e.at < b.e.at ? -1 : a.e.at > b.e.at ? 1 : a.i - b.i));
  return { entries: ordered.map((x) => x.e), errors };
}

module.exports = { readStateHandoff };
