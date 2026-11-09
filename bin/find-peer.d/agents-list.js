"use strict";
// The ListAgents dump given through --agents-file, and the destination it maps a session id to.
// Observed real row (verification (b), 2026-11-09): "  <name> [<ref6hex>]  ·  <kind>  ·  <state>  ·  ..."
// — no session id is listed, so a session id resolves only through the " [xxxxxxxx]" name suffix.
// The older placeholder "- [<ref>] <name>[ session=<id>]" is still accepted (test fixtures).

const path = require("path");
const { SESSION_NAME_SUFFIX_RE } = require(path.join(__dirname, "..", "..", "hooks", "lib", "session-name"));

const LEGACY_ENTRY_RE = /^- \[([^\]\s]+)\] (.+?)(?: session=([A-Za-z0-9_-]+))?$/;
const LISTING_ENTRY_RE = /^\s+(\S.*?) \[([0-9a-f]{6})\]\s+·\s+.+$/;
// eslint-disable-next-line no-control-regex
const CONTROL_RE = /[\u0000-\u001f\u007f]/;

// parseAgentsList(text) -> [{ref, name, sessionId|null}], or null when any non-blank line is not an entry.
function parseAgentsList(text) {
  const entries = [];
  for (const raw of String(text).split("\n")) {
    const line = raw.replace(/\r$/, "");
    if (line.trim() === "") continue;
    if (CONTROL_RE.test(line)) return null;
    const legacy = line.match(LEGACY_ENTRY_RE);
    if (legacy) {
      entries.push({ ref: legacy[1], name: legacy[2], sessionId: legacy[3] || null });
      continue;
    }
    const real = line.match(LISTING_ENTRY_RE);
    if (!real) {
      if (/^(This session is|Peer sessions \()/.test(line)) continue; // ListAgents header lines
      return null;
    }
    entries.push({ ref: real[2], name: real[1], sessionId: null });
  }
  return entries;
}

// nameMatches(name, sid) — the name ends in " [xxxxxxxx]" carrying the first 8 hex digits of sid.
function nameMatches(name, sid) {
  const m = SESSION_NAME_SUFFIX_RE.exec(name);
  return Boolean(m) && m[1] === sid.slice(0, 8).toLowerCase();
}

// resolveFromList(entries, kind, sid) -> {destination} | {code, reason}. Only "ref" and "name" read a list.
function resolveFromList(entries, kind, sid) {
  const hits = kind === "ref"
    ? entries.filter((e) => e.sessionId === sid).map((e) => e.ref)
    : entries.filter((e) => nameMatches(e.name, sid)).map((e) => e.name);
  if (hits.length === 0) return { code: 5, reason: "not-in-list" };
  if (hits.length > 1) return { code: 6, reason: "ambiguous" };
  return { destination: hits[0] };
}

module.exports = { parseAgentsList, resolveFromList, nameMatches };
