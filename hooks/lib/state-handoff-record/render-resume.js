"use strict";
// renderStateHandoffForResume — the /resume-session --from view of state handoff reader entries
// (#2652): the latest entry per (cls, at_step, record_key), the newest maxEntries of them, grouped by
// class. cls is in the identity because the pre-#2652 view folded within one class only, so two
// classes sharing a key both stay visible.

const path = require("path");
const { sanitizeUntrustedField } = require("../output-sanitize");
const { OVERFLOW_KEY } = require(path.join(__dirname, "..", "..", "workflow-state", "state-io", "state-handoff-record-schema"));

const DEFAULT_MAX_ENTRIES = 40;
const OVERFLOW_KEYS = new Set([OVERFLOW_KEY]);
// --- BEGIN temporary: handoff.md -> state handoff record migration added 2026-10-29 ---
// deletion-condition: remove once 30 days (the control dir lifetime) have passed since merge and neither a control dir holding a legacy handoff.md nor a plans-dir <sid>-handoff.md remains
OVERFLOW_KEYS.add("legacy:overflow");
// --- END temporary: handoff.md -> state handoff record migration ---

// Returns the rendered text, or null when there is no entry.
function renderStateHandoffForResume(entries, opts) {
  const list = Array.isArray(entries) ? entries.filter((e) => e && typeof e === "object") : [];
  if (list.length === 0) return null;
  const options = opts && typeof opts === "object" ? opts : {};
  const maxEntries = Number.isInteger(options.maxEntries) && options.maxEntries > 0 ? options.maxEntries : DEFAULT_MAX_ENTRIES;

  const latest = new Map();
  for (const e of list) {
    const id = `${e.cls}\u0000${e.at_step}\u0000${e.record_key}`;
    const prev = latest.get(id);
    if (!prev || String(e.at) >= String(prev.at)) latest.set(id, e);
  }
  // An overflow mark says records are missing, so the entry cap never drops it.
  const isMark = (e) => OVERFLOW_KEYS.has(e.record_key);
  const byAt = (a, b) => (String(a.at) < String(b.at) ? -1 : String(a.at) > String(b.at) ? 1 : 0);
  const all = Array.from(latest.values());
  const shown = all.filter(isMark).concat(all.filter((e) => !isMark(e)).sort(byAt).slice(-maxEntries));

  const out = [];
  for (const cls of Array.from(new Set(shown.map((e) => String(e.cls)))).sort()) {
    out.push(`### ${sanitizeUntrustedField(cls)}`);
    for (const e of shown.filter((x) => String(x.cls) === cls)) {
      // The key is the dedup identity, not reading matter, so the line shows step, summary, pointer.
      out.push(`- ${sanitizeUntrustedField(e.at_step)} | ${sanitizeUntrustedField(e.summary)} | ${sanitizeUntrustedField(e.pointer)}`);
    }
  }
  return out.join("\n");
}

module.exports = { renderStateHandoffForResume, DEFAULT_MAX_ENTRIES };
