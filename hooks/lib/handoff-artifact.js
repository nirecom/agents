"use strict";
// The handoff artifact: <PLANS_DIR>/<sid>-handoff.md.
//
// One canonical writer (appendHandoffEntry) for every producer — step ends,
// blocked gates, emergency flushes — so "what did this session learn that the
// state file cannot hold" survives a compaction or a session boundary.
//
// The in/out vocabulary is deliberately asymmetric: callers pass `cls` (the
// writer's argument name), read-back exposes `.class` (the document's own
// field name). Pinned by review; do not "fix" it into symmetry.

const fs = require("fs");
const path = require("path");
const { getWorkflowPlansDir } = require("./workflow-plans-dir");
const { SESSION_ID_VALID_RE, VALID_STEPS } = require("../workflow-state/state-io/core");
const { collapseControl, redactSecrets, sanitizeLine } = require("./output-sanitize");

// Collapse FIRST: SECRET_OPTION_RE is space-anchored, so a secret split across
// a literal newline is only reassembled into one matchable line by collapsing.
// Same composition as hooks/workflow-run-tests.js sanitizeTrigger().
function sanitizeField(value) {
  return sanitizeLine(redactSecrets(collapseControl(String(value === undefined || value === null ? "" : value))));
}

const HANDOFF_SCHEMA_VERSION = "1";
const HANDOFF_CLASSES = Object.freeze(["A", "B", "C", "D", "E", "F", "G"]);
const HANDOFF_ORIGINS = Object.freeze(["step-end", "gate-block", "flush"]);
// commit_push is a skill step the workflow does not track, and "-" is the
// stepless entry; both are legitimate producers of handoff micro-state.
const HANDOFF_STEPS = Object.freeze(VALID_STEPS.concat(["commit_push", "-"]));
const KEY_VALID_RE = /^[A-Za-z0-9_.:-]+$/;

const MAX_ENTRY_LINES = 400;
const MAX_BYTES = 64 * 1024;
const OVERFLOW_MARKER = "## Overflow";

function isValidSid(sid) {
  return typeof sid === "string" && SESSION_ID_VALID_RE.test(sid);
}

function getHandoffPath(sid) {
  if (!isValidSid(sid)) throw new Error(`Invalid sessionId: ${JSON.stringify(sid)}`);
  return path.join(getWorkflowPlansDir(), sid + "-handoff.md");
}

function esc(value) {
  return String(value === undefined || value === null ? "" : value)
    .replace(/\\/g, "\\\\")
    .replace(/\|/g, "\\|")
    .replace(/\n/g, "\\n")
    .replace(/\r/g, "\\r");
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
  const doc = { schemaVersion: null, sections: {}, overflow: false };
  let cls = null;
  for (const line of String(raw).split(/\r?\n/)) {
    const heading = /^##\s+(\S+)\s*$/.exec(line);
    if (heading) {
      if (heading[1] === "Overflow") {
        doc.overflow = true;
        cls = null;
      } else {
        cls = HANDOFF_CLASSES.indexOf(heading[1]) === -1 ? null : heading[1];
        if (cls && !doc.sections[cls]) doc.sections[cls] = [];
      }
      continue;
    }
    const version = /^handoff_schema_version:\s*(\S+)\s*$/.exec(line);
    if (version) {
      doc.schemaVersion = version[1];
      continue;
    }
    if (cls && line.startsWith("- ")) doc.sections[cls].push(line);
  }
  return doc;
}

function parseEntryLine(line, cls) {
  const fields = splitUnescaped(line.slice(2));
  if (fields.length !== 6) return null;
  return {
    class: cls,
    at: fields[0],
    origin: fields[1],
    step: fields[2],
    key: fields[3],
    summary: unesc(fields[4]),
    pointer: unesc(fields[5]),
  };
}

function serializeDocument(sid, doc) {
  const out = [`# Handoff — ${sid}`, "", `handoff_schema_version: ${HANDOFF_SCHEMA_VERSION}`, ""];
  for (const cls of HANDOFF_CLASSES) {
    const lines = doc.sections[cls];
    if (!lines || lines.length === 0) continue;
    out.push(`## ${cls}`);
    for (const line of lines) out.push(line);
    out.push("");
  }
  if (doc.overflow) {
    out.push(OVERFLOW_MARKER);
    out.push("");
  }
  return out.join("\n");
}

function readDocumentFile(handoffPath) {
  try {
    return fs.readFileSync(handoffPath, "utf8");
  } catch (e) {
    return null;
  }
}

function writeDocumentFile(handoffPath, text) {
  const tmpPath = `${handoffPath}.${process.pid}.tmp`;
  try {
    fs.mkdirSync(path.dirname(handoffPath), { recursive: true });
    fs.writeFileSync(tmpPath, text, "utf8");
    fs.renameSync(tmpPath, handoffPath);
    return true;
  } catch (e) {
    try {
      fs.unlinkSync(tmpPath);
    } catch (e2) {
      /* nothing to clean up */
    }
    return false;
  }
}

function validateEntry(entry) {
  if (!entry || typeof entry !== "object") return false;
  if (HANDOFF_CLASSES.indexOf(entry.cls) === -1) return false;
  if (HANDOFF_STEPS.indexOf(entry.step) === -1) return false;
  if (typeof entry.key !== "string" || !KEY_VALID_RE.test(entry.key)) return false;
  if (HANDOFF_ORIGINS.indexOf(entry.origin) === -1) return false;
  if (entry.summary !== undefined && entry.summary !== null && typeof entry.summary !== "string") return false;
  if (entry.pointer !== undefined && entry.pointer !== null && typeof entry.pointer !== "string") return false;
  return true;
}

function countEntryLines(doc) {
  let n = 0;
  for (const cls of HANDOFF_CLASSES) {
    const lines = doc.sections[cls];
    if (lines) n += lines.length;
  }
  return n;
}

// Returns {written, reason}. NEVER throws: every caller is a side-effect writer
// whose primary job must survive a lost breadcrumb.
function appendHandoffEntry(sid, entry) {
  try {
    if (!isValidSid(sid) || !validateEntry(entry)) return { written: false, reason: "invalid" };
    const handoffPath = getHandoffPath(sid);
    const raw = readDocumentFile(handoffPath);
    const doc = raw === null ? { schemaVersion: HANDOFF_SCHEMA_VERSION, sections: {}, overflow: false } : parseDocument(raw);
    if (doc.schemaVersion !== null && doc.schemaVersion !== HANDOFF_SCHEMA_VERSION) {
      return { written: false, reason: "schema-unknown" };
    }
    const cls = entry.cls;
    if (!doc.sections[cls]) doc.sections[cls] = [];
    const section = doc.sections[cls];

    // Free-text fields reach here straight from producers (a blocked gate passes
    // the raw shell command), and this file is durable and copied by session
    // sync — so credentials and sentinels are stripped before they are stored.
    // The key is charset-validated, not shape-checked: a vendor token is a legal
    // key, so it takes the same redaction pass as the free-text fields.
    const summary = sanitizeField(entry.summary);
    const pointer = sanitizeField(entry.pointer);
    const key = sanitizeField(entry.key);

    const tail = [entry.origin, entry.step, key, esc(summary), esc(pointer)].join(" | ");
    const line = `- ${new Date().toISOString()} | ${tail}`;

    const previous = section.length ? section[section.length - 1] : null;
    if (previous !== null && previous.slice(previous.indexOf(" | ") + 3) === tail) {
      return { written: false, reason: "noop-identical" };
    }

    if (countEntryLines(doc) >= MAX_ENTRY_LINES) {
      if (!doc.overflow) {
        doc.overflow = true;
        writeDocumentFile(handoffPath, serializeDocument(sid, doc));
      }
      return { written: false, reason: "overflow" };
    }

    section.push(line);
    const text = serializeDocument(sid, doc);
    if (Buffer.byteLength(text, "utf8") > MAX_BYTES) {
      section.pop();
      if (!doc.overflow) {
        doc.overflow = true;
        writeDocumentFile(handoffPath, serializeDocument(sid, doc));
      }
      return { written: false, reason: "overflow" };
    }
    if (!writeDocumentFile(handoffPath, text)) return { written: false, reason: "io" };
    return { written: true, reason: "ok" };
  } catch (e) {
    return { written: false, reason: "io" };
  }
}

// Read-back preserves the FULL append-only history; collapsing to latest-wins
// happens only at render time, so the artifact stays an audit trail.
function readHandoff(sid) {
  const absent = { exists: false, schemaVersion: null, raw: null, entriesByClass: {}, overflow: false, sid };
  if (!isValidSid(sid)) return absent;
  let handoffPath;
  try {
    handoffPath = getHandoffPath(sid);
  } catch (e) {
    return absent;
  }
  const raw = readDocumentFile(handoffPath);
  if (raw === null) return absent;
  const doc = parseDocument(raw);
  const entriesByClass = {};
  for (const cls of HANDOFF_CLASSES) {
    const lines = doc.sections[cls];
    if (!lines || lines.length === 0) continue;
    const entries = [];
    for (const line of lines) {
      const parsed = parseEntryLine(line, cls);
      if (parsed) entries.push(parsed);
    }
    if (entries.length) entriesByClass[cls] = entries;
  }
  return {
    exists: true,
    schemaVersion: doc.schemaVersion,
    raw,
    entriesByClass,
    overflow: doc.overflow,
    sid,
  };
}

function renderHandoffForResume(parsed, opts) {
  if (!parsed || parsed.exists !== true) return "";
  const options = opts && typeof opts === "object" ? opts : {};
  const maxEntries = Number.isInteger(options.maxEntries) && options.maxEntries > 0 ? options.maxEntries : 40;

  if (String(parsed.schemaVersion) !== HANDOFF_SCHEMA_VERSION) {
    const body = String(parsed.raw || "")
      .split(/\r?\n/)
      .filter((l) => l.toLowerCase().indexOf("schema") === -1)
      .map(sanitizeField);
    return [
      `handoff artifact declares an unknown schema version ${String(parsed.schemaVersion)}; showing the document verbatim.`,
    ].concat(body).join("\n");
  }

  const out = [];
  let shown = 0;
  for (const cls of HANDOFF_CLASSES) {
    const entries = (parsed.entriesByClass || {})[cls] || [];
    if (!entries.length) continue;
    const latest = new Map();
    for (const e of entries) {
      const id = `${e.step}\u0000${e.key}`;
      const prev = latest.get(id);
      if (!prev || String(e.at) >= String(prev.at)) latest.set(id, e);
    }
    const rows = Array.from(latest.values());
    if (!rows.length) continue;
    out.push(`### ${cls}`);
    for (const e of rows) {
      if (shown >= maxEntries) break;
      // The key is the dedup identity, not reading matter: writers whose key
      // also names the event put it at the head of the summary instead, so the
      // rendered view never says the same word twice.
      // unesc() turns escaped `\n`/`\r` back into real control bytes, and
      // entries written before the write-side pass existed were never redacted,
      // so the read side re-sanitizes rather than trusting the stored text.
      out.push(`- ${e.step} | ${sanitizeField(e.summary)} | ${sanitizeField(e.pointer)}`);
      shown += 1;
    }
  }
  if (parsed.overflow) out.push("(handoff artifact reached its cap — later entries were not recorded)");
  return out.join("\n");
}

module.exports = {
  HANDOFF_SCHEMA_VERSION,
  HANDOFF_CLASSES,
  HANDOFF_ORIGINS,
  HANDOFF_STEPS,
  MAX_ENTRY_LINES,
  MAX_BYTES,
  getHandoffPath,
  appendHandoffEntry,
  readHandoff,
  renderHandoffForResume,
};
