"use strict";
// PLANS_DIR-wide reverse lookup: "which session was that?" — answered from the
// plan artifacts alone, with no cwd, no transcript and no state file.
//
// Deliberately NOT merged with inheritance/candidates.js's
// listRecentContextCandidates: that generator answers a different question
// ("can I adopt this here?") and owns the adoptable claim. A record produced
// here is always adoptable:false, so a search hit can never invite the user to
// adopt state the workflow would then refuse (CPR-E2E).

const fs = require("fs");
const path = require("path");
const { getWorkflowPlansDir } = require("../lib/workflow-plans-dir");
const { listRecentContextCandidates, lastActivityOf } = require("./inheritance/candidates");

const ARTIFACT_KINDS = Object.freeze(["intent", "outline", "detail", "handoff"]);
// Without a query the reachable-only section is an appendix, not a dump of
// every session that ever ran on this machine.
const SEARCH_ONLY_CAP = 10;
const SEARCH_ONLY_REASON = "search-result-only: no lineage or context evidence that this session may be adopted here";
const ARTIFACT_RE = /^(.+?)-(intent|outline|detail|handoff)\.md$/;
const ISSUE_RE = /#(\d{1,7})/g;
const TITLE_RE = /^\*\*Title:\*\*\s*(.+?)\s*$/m;

function listPlansFiles(plansDir) {
  try {
    return fs.readdirSync(plansDir);
  } catch (e) {
    return [];
  }
}

function readTextOrNull(p) {
  try {
    return fs.readFileSync(p, "utf8");
  } catch (e) {
    return null;
  }
}

function mtimeIsoOrNull(p) {
  try {
    return new Date(fs.statSync(p).mtimeMs).toISOString();
  } catch (e) {
    return null;
  }
}

// sid → { artifacts: {kind: absolutePath}, lastActivity, body }
function indexPlansDir(plansDir) {
  const index = new Map();
  for (const name of listPlansFiles(plansDir)) {
    const m = ARTIFACT_RE.exec(name);
    if (!m) continue;
    const sid = m[1];
    const kind = m[2];
    const full = path.join(plansDir, name);
    let rec = index.get(sid);
    if (!rec) {
      rec = { sid, artifacts: {}, lastActivity: null, body: "" };
      index.set(sid, rec);
    }
    rec.artifacts[kind] = full;
    const at = mtimeIsoOrNull(full);
    if (at !== null && (rec.lastActivity === null || at > rec.lastActivity)) rec.lastActivity = at;
    if (kind === "intent" || kind === "outline" || kind === "detail") {
      const text = readTextOrNull(full);
      if (text !== null) rec.body += text + "\n";
    }
  }
  return index;
}

function issuesOf(body) {
  const out = [];
  let m;
  ISSUE_RE.lastIndex = 0;
  while ((m = ISSUE_RE.exec(body)) !== null) {
    if (out.indexOf(m[1]) === -1) out.push(m[1]);
  }
  return out;
}

// Only 108 of 667 real intent.md files carry a `**Title:**` line, so its
// absence is normal and never removes a session from the search.
function titleOf(body) {
  const m = TITLE_RE.exec(body);
  return m ? m[1] : null;
}

function normalizeQuery(query) {
  return typeof query === "string" ? query.trim() : "";
}

function matchKeys(rec, query) {
  const keys = [];
  const q = query.toLowerCase();
  if (q.length === 0) return keys;
  if (rec.sid.toLowerCase().indexOf(q) !== -1) keys.push("sid");
  const bare = /^#?(\d{1,7})$/.exec(q);
  if (bare && rec.issues.indexOf(bare[1]) !== -1) keys.push("issue");
  if (!bare && rec.body.toLowerCase().indexOf(q) !== -1) keys.push("text");
  if (bare && keys.indexOf("issue") === -1 && rec.body.toLowerCase().indexOf(q) !== -1) keys.push("text");
  return keys;
}

function toSearchRecord(rec, matchedOn) {
  const artifacts = {};
  for (const kind of ARTIFACT_KINDS) artifacts[kind] = rec.artifacts[kind] || null;
  return {
    sid: rec.sid,
    adoptable: false,
    adoptable_reason: SEARCH_ONLY_REASON,
    git_branch: null,
    cwd: null,
    last_activity: rec.lastActivity,
    last_activity_source: "artifact-mtime",
    matched_on: matchedOn,
    issues: rec.issues,
    title: rec.title,
    artifacts,
    sources: ["search"],
  };
}

function buildIndex(opts) {
  const plansDir = (opts && opts.plansDir) || getWorkflowPlansDir();
  const index = indexPlansDir(plansDir);
  for (const rec of index.values()) {
    rec.issues = issuesOf(rec.body);
    rec.title = titleOf(rec.body);
  }
  return index;
}

function byLastActivityDesc(a, b) {
  return String(b.last_activity || "").localeCompare(String(a.last_activity || ""));
}

// searchUpstreamSessions(query, opts) → [record, ...]
// An empty query returns every indexed session, newest first; the caller caps it.
function searchUpstreamSessions(query, opts) {
  const q = normalizeQuery(query);
  const out = [];
  for (const rec of buildIndex(opts).values()) {
    const matchedOn = matchKeys(rec, q);
    if (q.length > 0 && matchedOn.length === 0) continue;
    out.push(toSearchRecord(rec, matchedOn));
  }
  out.sort(byLastActivityDesc);
  const limit = opts && Number.isInteger(opts.limit) && opts.limit > 0 ? opts.limit : null;
  return limit === null ? out : out.slice(0, limit);
}

function contextRecord(candidate, searchRec) {
  const state = candidate.state || {};
  const base = searchRec || {
    matched_on: [], issues: [], title: null,
    artifacts: { intent: null, outline: null, detail: null, handoff: null },
  };
  return {
    sid: candidate.sessionId,
    adoptable: true,
    adoptable_reason: "context-match: lineage and resumability guards both pass for this cwd",
    git_branch: candidate.git_branch || null,
    cwd: state.cwd || null,
    last_activity: candidate.last_activity || lastActivityOf(state),
    last_activity_source: "state-events",
    matched_on: base.matched_on,
    issues: base.issues,
    title: base.title,
    artifacts: base.artifacts,
    sources: searchRec ? ["context", "search"] : ["context"],
  };
}

// listUpstreamCandidates({heirSid, ctx, query, limit}) → [record, ...]
// The presentation layer for /resume-session --list: it merges the two
// generators and re-implements neither.
function listUpstreamCandidates(input) {
  const opts = input || {};
  const q = normalizeQuery(opts.query);
  const searchRecords = searchUpstreamSessions(q, opts);
  const searchBySid = new Map(searchRecords.map((r) => [r.sid, r]));

  let contextCandidates = [];
  try {
    contextCandidates = listRecentContextCandidates(opts.ctx, {}) || [];
  } catch (e) {
    contextCandidates = [];
  }

  const out = [];
  const claimed = new Set();
  for (const c of contextCandidates) {
    if (claimed.has(c.sessionId)) continue;
    claimed.add(c.sessionId);
    out.push(contextRecord(c, searchBySid.get(c.sessionId) || null));
  }

  const searchOnly = searchRecords.filter((r) => !claimed.has(r.sid)).slice(0, SEARCH_ONLY_CAP);
  out.push(...searchOnly);

  const limit = Number.isInteger(opts.limit) && opts.limit > 0 ? opts.limit : null;
  return limit === null ? out : out.slice(0, limit);
}

module.exports = {
  ARTIFACT_KINDS,
  SEARCH_ONLY_CAP,
  searchUpstreamSessions,
  listUpstreamCandidates,
};
