"use strict";
// --- BEGIN temporary: handoff.md -> state handoff record migration added 2026-10-29 ---
// deletion-condition: remove once 30 days (the control dir lifetime) have passed since merge and neither a control dir holding a legacy handoff.md nor a plans-dir <sid>-handoff.md remains
// The part of the state handoff reader that reads a pre-#2652 handoff.md (control dir, else — or
// when the control copy cannot be read — the unmigrated plans-dir copy). Read-only;
// read.js is its only caller and sanitizes every field it returns.

const fs = require("fs");
const path = require("path");
const STATE_IO = path.join(__dirname, "..", "..", "workflow-state", "state-io");
const { getSessionControlDir, assertRealControlDir } = require(path.join(STATE_IO, "control-dir"));
const { SESSION_ID_VALID_RE } = require(path.join(STATE_IO, "core"));
const { CLASSES } = require(path.join(STATE_IO, "state-handoff-record-schema"));
const { getWorkflowPlansDir } = require("../workflow-plans-dir");
const { legacyBasename } = require("../plans-artifact-registry");

const KNOWN_SCHEMA_VERSION = "1";
const NAME = "handoff.md";

function isRegularFile(file) {
  try {
    return fs.lstatSync(file, { throwIfNoEntry: false })?.isFile() === true;
  } catch (_e) {
    return false;
  }
}

// { files, error }: files lists, in read order, the regular files among <sid>.control/handoff.md
// and the not-yet-migrated plans-dir copy (legacyBasename). error is true only when the control dir
// cannot be resolved (or is a symlink / non-directory); the plans-dir copy is still tried then.
// Never throws, never writes or migrates (controlPath would); lstat, so a symlink is never followed.
function findLegacyHandoffPaths(sid) {
  if (typeof sid !== "string" || !SESSION_ID_VALID_RE.test(sid)) return { files: [], error: false };
  let controlFile = null;
  let controlError = false;
  try {
    const dir = getSessionControlDir(sid);
    assertRealControlDir(dir);
    controlFile = path.join(dir, NAME);
  } catch (e) {
    controlError = true;
    try {
      process.stderr.write(`legacy-handoff-md: ${String((e && e.message) || e).replace(/\s*[\r\n]+\s*/g, " ")}\n`);
    } catch (_) { /* the diagnostic never changes the reader's outcome */ }
  }
  const files = controlFile && isRegularFile(controlFile) ? [controlFile] : [];
  let plansFile;
  try {
    plansFile = path.join(getWorkflowPlansDir(), legacyBasename(sid, NAME));
  } catch (_e) {
    return { files, error: controlError };
  }
  if (isRegularFile(plansFile)) files.push(plansFile);
  return { files, error: controlError };
}

function unesc(value) {
  let out = "";
  for (let i = 0; i < value.length; i += 1) {
    const ch = value[i];
    if (ch !== "\\" || i === value.length - 1) {
      out += ch;
      continue;
    }
    const next = value[i + 1];
    i += 1;
    if (next === "n") out += "\n";
    else if (next === "r") out += "\r";
    else if (next === "\\" || next === "|") out += next;
    else out += "\\" + next;
  }
  return out;
}

function splitUnescaped(body) {
  const fields = [];
  let cur = "";
  for (let i = 0; i < body.length; i += 1) {
    const ch = body[i];
    if (ch === "\\" && i < body.length - 1) {
      cur += ch + body[i + 1];
      i += 1;
      continue;
    }
    if (ch === "|") {
      fields.push(cur);
      cur = "";
      continue;
    }
    cur += ch;
  }
  fields.push(cur);
  return fields.map((f) => f.trim());
}

function parseDocument(raw) {
  const doc = { schemaVersion: null, lines: [], overflow: false };
  let cls = null;
  for (const line of String(raw).split(/\r?\n/)) {
    const heading = /^##\s+(\S+)\s*$/.exec(line);
    if (heading) {
      doc.overflow = doc.overflow || heading[1] === "Overflow";
      cls = CLASSES.includes(heading[1]) ? heading[1] : null;
      continue;
    }
    const version = /^handoff_schema_version:\s*(\S+)\s*$/.exec(line);
    if (version) {
      doc.schemaVersion = version[1];
      continue;
    }
    if (cls && line.startsWith("- ")) doc.lines.push({ cls, line });
  }
  return doc;
}

function parseEntryLine(line, cls) {
  const fields = splitUnescaped(line.slice(2));
  if (fields.length !== 6) return null;
  return {
    at: fields[0], cls, origin: fields[1], at_step: fields[2], record_key: fields[3],
    summary: unesc(fields[4]), pointer: unesc(fields[5]),
  };
}

function fileTime(file) {
  try { return fs.statSync(file).mtime.toISOString(); } catch (_e) { return ""; }
}

// readLegacyHandoffMd(sid) -> { entries, error }. Reads the first candidate that can be read: a
// control-dir copy that fails to read falls back to the plans-dir copy. error is true when the
// control dir cannot be resolved or any candidate exists but cannot be read (the entries of a copy
// read after it still come back); an invalid sid or an absent file is not an error.
function readLegacyHandoffMd(sid) {
  const found = findLegacyHandoffPaths(sid);
  let readFailed = false;
  for (const file of found.files) {
    let raw;
    try {
      raw = fs.readFileSync(file, "utf8");
    } catch (_e) {
      readFailed = true;
      continue;
    }
    return { entries: parseLegacyFile(file, raw), error: found.error || readFailed };
  }
  return { entries: [], error: found.error || readFailed };
}

// Nothing the file says is dropped: the overflow mark and an unknown schema version each come back
// as one class B entry. A file with no version line is unknown too, as the pre-#2652
// renderHandoffForResume treated it, so a malformed or hand-edited file keeps its raw text.
function parseLegacyFile(file, raw) {
  const doc = parseDocument(raw);
  const at = fileTime(file);
  const marker = (key, summary, pointer) => ({ at, cls: "B", origin: "auto-record", at_step: "-", record_key: key, summary, pointer });
  if (doc.schemaVersion !== KNOWN_SCHEMA_VERSION) {
    const declared = doc.schemaVersion === null ? "no schema version" : `an unknown schema version ${doc.schemaVersion}`;
    return [marker("legacy:unknown-schema", `legacy handoff.md declares ${declared}; its raw text is in the pointer`, raw)];
  }
  const entries = doc.lines.map((l) => parseEntryLine(l.line, l.cls)).filter(Boolean);
  if (doc.overflow) entries.push(marker("legacy:overflow", "legacy handoff.md reached its cap; later entries were not recorded", "-"));
  return entries;
}

// Appends the legacy entries to `entries` (which already holds the state entries) and
// "legacy-handoff-md" to `errors` on failure. Before #2652 a RESET was written to both the reset
// event and handoff.md, so a legacy copy (cls E, resetKey) is dropped only when a state reset entry
// with the same step and reason already stands for it; a reset the state does not hold stays
// visible, and a near-miss shows twice rather than vanishing. `normalize` is the reader's own
// field sanitizer: both sides are compared as the reader will show them. Never throws.
const LEGACY_RESET_PREFIX = "RESET_FROM ";
function mergeLegacyEntries(sid, entries, errors, resetKey, normalize) {
  let legacy;
  try { legacy = readLegacyHandoffMd(sid); } catch (_e) { legacy = { entries: [], error: true }; }
  if (legacy.error) errors.push("legacy-handoff-md");
  // The state entry's summary is "<from_step>: <reason>"; the legacy one is that, prefixed.
  const id = (step, summary) => `${normalize(step)}\u0000${normalize(summary)}`;
  const stateResets = new Set(entries.filter((e) => e.record_key === resetKey).map((e) => id(e.at_step, e.summary)));
  const legacyId = (e) => {
    const s = String(e.summary);
    return id(e.at_step, s.startsWith(LEGACY_RESET_PREFIX) ? s.slice(LEGACY_RESET_PREFIX.length) : s);
  };
  for (const e of legacy.entries) {
    if (e.cls === "E" && e.record_key === resetKey && stateResets.has(legacyId(e))) continue;
    entries.push(e);
  }
}

module.exports = { readLegacyHandoffMd, mergeLegacyEntries };
// --- END temporary: handoff.md -> state handoff record migration ---
