"use strict";
// bin/lib/review-threat-metrics/issue-source.js — where a filed issue and a rejected row belong
// (#2020): an issue is dated by its origin-session marker's session (else its own created_at), and
// a row meets the concern journal by (session, DISCRIM) across formats; the version set of every
// matching journal row decides its boundary version.
const { MARKER_RE } = require("../../find-peer.d/origin");
const C = require("./common");

// issueOrigin(body) — {sid} of the one origin-session marker, {sid: null} without one, or {excluded}.
function issueOrigin(body) {
  const ids = new Set([...String(body).matchAll(MARKER_RE)].map((m) => m[1]));
  if (ids.size > 1) return { excluded: "ambiguous-origin" };
  return { sid: ids.size ? [...ids][0] : null };
}

// issueTime(item) — {time, sid} (ms) of the issue's origin session, else of its filing; or {excluded}.
function issueTime(item) {
  const o = issueOrigin(item.body);
  if (o.excluded) return o;
  if (o.sid) {
    const t = C.sessionTime(o.sid);
    return t === null ? { excluded: "origin-no-state" } : { time: t, sid: o.sid };
  }
  const t = Date.parse(item.created_at);
  return Number.isNaN(t) ? { excluded: "no-created-at" } : { time: t, sid: null };
}

// splitIssues(items, inPeriod) — {kept: [{...item, sid}], excluded: {reason: count}}; an issue with
// no finding line is "no-findings", one outside the period "out-of-period".
function splitIssues(items, inPeriod) {
  const kept = [];
  const excluded = {};
  const out = (k) => { excluded[k] = (excluded[k] || 0) + 1; };
  for (const it of items) {
    if (it.findings.length === 0) {
      out("no-findings");
      continue;
    }
    const t = issueTime(it);
    if (t.excluded) out(t.excluded);
    else if (!inPeriod(t.time)) out("out-of-period");
    else kept.push({ ...it, sid: t.sid });
  }
  return { kept, excluded };
}

// journalIndex(rows) — Map of "sid\0discrim" to every journal row with that pair.
function journalIndex(rows) {
  const idx = new Map();
  for (const r of rows) {
    const k = `${r.sid}\0${r.discrim}`;
    if (!idx.has(k)) idx.set(k, []);
    idx.get(k).push(r);
  }
  return idx;
}

// attribute(idx, sid, discrim) — {version, rows} when every matching row agrees on one known
// version; otherwise {excluded: "unmatched" | "unknown" | "multi-version"}.
function attribute(idx, sid, discrim) {
  const rows = idx.get(`${sid}\0${discrim}`);
  if (!rows) return { excluded: "unmatched" };
  const versions = new Set(rows.map((r) => r.version));
  if (versions.size > 1) return { excluded: "multi-version" };
  const [version] = versions;
  return version === "unknown" ? { excluded: "unknown" } : { version, rows };
}

module.exports = { issueOrigin, issueTime, splitIssues, journalIndex, attribute };
