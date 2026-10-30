"use strict";
// hooks/lib/plan-sync/turn-trailer.js
// The commit message of one turn's plan-sync commit: a subject, a list of the rels, and a
// trailer paragraph naming the session, the turn, the turn's base commit and every rel.
// parseTurnMessage reads the last paragraph only, so a hand-edited message never matches.

const TRAILER_KEYS = Object.freeze({
  session: "Plan-Sync-Session",
  turn: "Plan-Sync-Turn",
  base: "Plan-Sync-Turn-Base",
  rel: "Plan-Sync-Rel",
});

const SHA_RE = /^[0-9a-f]{40}$/;
// The Turn-Base of a turn whose start could not be read from history: such a turn gets no link.
const UNKNOWN_BASE = "unknown";
const isBase = (b) => b === UNKNOWN_BASE || SHA_RE.test(b);

// cleanRels(rels) -> rels without line breaks, deduplicated in first-seen order.
function cleanRels(rels) {
  const seen = new Set();
  const out = [];
  for (const r of Array.isArray(rels) ? rels : []) {
    if (typeof r !== "string" || r === "" || /[\r\n]/.test(r) || seen.has(r)) continue;
    seen.add(r);
    out.push(r);
  }
  return out;
}

function formatTurnMessage({ sid, turnId, base, rels }) {
  const list = cleanRels(rels);
  const more = list.length > 1 ? ` (+${list.length - 1} more)` : "";
  const subject = `plan-sync: ${list[0] || ""}${more}`;
  const body = list.map((r) => `- ${r}`).join("\n");
  const trailer = [
    `${TRAILER_KEYS.session}: ${sid}`,
    `${TRAILER_KEYS.turn}: ${turnId}`,
    `${TRAILER_KEYS.base}: ${base}`,
    ...list.map((r) => `${TRAILER_KEYS.rel}: ${r}`),
  ].join("\n");
  return `${subject}\n\n${body}\n\n${trailer}\n`;
}

const LINE_RE = /^(Plan-Sync-Session|Plan-Sync-Turn|Plan-Sync-Turn-Base|Plan-Sync-Rel): (.*)$/;

// parseTurnMessage(text) -> {sid, turnId, base, rels} | null
function parseTurnMessage(text) {
  if (typeof text !== "string" || text === "") return null;
  const paras = text.replace(/\r/g, "").trim().split(/\n\s*\n/);
  if (paras.length < 2) return null;
  const found = { session: [], turn: [], base: [], rel: [] };
  const keyOf = {
    [TRAILER_KEYS.session]: "session", [TRAILER_KEYS.turn]: "turn",
    [TRAILER_KEYS.base]: "base", [TRAILER_KEYS.rel]: "rel",
  };
  for (const line of paras[paras.length - 1].split("\n")) {
    const m = line.match(LINE_RE);
    if (!m) return null;
    found[keyOf[m[1]]].push(m[2]);
  }
  if (found.session.length !== 1 || found.turn.length !== 1 || found.base.length !== 1) return null;
  if (found.rel.length === 0 || !isBase(found.base[0])) return null;
  if (!found.session[0] || !found.turn[0]) return null;
  return { sid: found.session[0], turnId: found.turn[0], base: found.base[0], rels: found.rel };
}

module.exports = { TRAILER_KEYS, UNKNOWN_BASE, formatTurnMessage, parseTurnMessage };
