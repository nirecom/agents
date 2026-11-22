"use strict";
// Cross-session view of every PM state file (#2941): tags in use, issue owners, generations.
// Covers every listStateRoots root. The current generation of a tag is the file with the largest
// pm.current_since (never mtime); only the current generation of an active PM owns issues.

const fs = require("fs");
const path = require("path");
const { listStateRoots } = require("../workflow-state/state-io/state-root");
const { SESSION_ID_VALID_RE } = require("../workflow-state/state-io/core");
const S = require("./schema");

// listPmFiles() -> [{session_id, file, pm}], one per sid (the first root listing it wins).
function listPmFiles() {
  const seen = new Map();
  for (const root of listStateRoots()) {
    let names;
    try { names = fs.readdirSync(root); } catch (_) { continue; }
    for (const name of names) {
      if (!name.endsWith(".json")) continue;
      const sid = name.slice(0, -".json".length);
      if (!SESSION_ID_VALID_RE.test(sid) || seen.has(sid)) continue;
      const file = path.join(root, name);
      let state;
      try {
        const raw = fs.readFileSync(file, "utf8");
        if (!raw.includes('"pm"')) continue;
        state = JSON.parse(raw);
      } catch (_) { continue; }
      if (S.hasPmMark(state) && typeof state.pm.tag === "string") seen.set(sid, { session_id: sid, file, pm: state.pm });
    }
  }
  return [...seen.values()];
}

const sinceMs = (e) => {
  const t = Date.parse(e.pm.current_since);
  return Number.isNaN(t) ? -Infinity : t;
};

// currentGenerations(entries) -> Map<lower tag, entry>; a tie on current_since goes to the larger sid.
function currentGenerations(entries) {
  const out = new Map();
  for (const e of entries) {
    const k = e.pm.tag.toLowerCase();
    const cur = out.get(k);
    if (!cur || sinceMs(e) > sinceMs(cur) || (sinceMs(e) === sinceMs(cur) && e.session_id > cur.session_id)) out.set(k, e);
  }
  return out;
}

function currentOf(tag, entries) {
  if (typeof tag !== "string") return null;
  return currentGenerations(entries || listPmFiles()).get(tag.toLowerCase()) || null;
}

function isCurrentGeneration(sid, entries) {
  const all = entries || listPmFiles();
  const me = all.find((e) => e.session_id === sid);
  if (!me) return false;
  const cur = currentOf(me.pm.tag, all);
  return Boolean(cur) && cur.session_id === sid;
}

// tagsOf(pm) -> every tag that names this PM (#2942): its tag, its retired tags, a pending rename target.
function tagsOf(pm) {
  const out = [pm.tag];
  for (const t of Array.isArray(pm.retired_tags) ? pm.retired_tags : []) if (typeof t === "string") out.push(t);
  if (pm.rename_pending && typeof pm.rename_pending.to === "string") out.push(pm.rename_pending.to);
  return out;
}

const namesTag = (e, tag) => tagsOf(e.pm).some((t) => S.sameTag(t, tag));

function tagInUse(tag, entries) {
  return (entries || listPmFiles()).some((e) => namesTag(e, tag));
}

// generationOfTag(tag, entries?) -> the current generation's entry {session_id, file, pm} of the PM a tag
// names (its tag, a retired tag or a pending rename target; case-insensitive), or null (#2942).
function generationOfTag(tag, entries) {
  if (typeof tag !== "string" || tag === "") return null;
  const named = (entries || listPmFiles()).filter((e) => namesTag(e, tag));
  let best = null;
  for (const e of named) {
    if (!best || sinceMs(e) > sinceMs(best) || (sinceMs(e) === sinceMs(best) && e.session_id > best.session_id)) best = e;
  }
  return best;
}

function listPmTags(entries) {
  return [...new Set((entries || listPmFiles()).map((e) => e.pm.tag))];
}

// listActivePms() -> the current generation of every active PM: [{tag, session_id, issues, file}].
function listActivePms(entries) {
  return [...currentGenerations(entries || listPmFiles()).values()]
    .filter((e) => !e.pm.archived_at)
    .map((e) => ({ tag: e.pm.tag, session_id: e.session_id, issues: Array.isArray(e.pm.issues) ? e.pm.issues : [], file: e.file, pm: e.pm }));
}

// assignedAt(pm, ref, homeRepo) -> when ref was last given to pm: the at of the last init/add entry
// holding it, unless a later remove holding it reset it; inherit entries do not count. Falls back
// to pm.current_since when no such entry is left.
function assignedAt(pm, ref, homeRepo) {
  let at = null;
  for (const e of (pm && Array.isArray(pm.assignment_log) ? pm.assignment_log : [])) {
    if (!e || typeof e !== "object" || !Array.isArray(e.issues)) continue;
    if (!e.issues.some((i) => i && typeof i === "object" && S.sameIssue(i, ref, homeRepo))) continue;
    if (e.op === "init" || e.op === "add") at = typeof e.at === "string" ? e.at : at;
    else if (e.op === "remove") at = null;
  }
  return at || (pm && typeof pm.current_since === "string" ? pm.current_since : null);
}

// directHoldersOf(ref, opts) -> [{tag, session_id, assigned_at}] of every active PM (current
// generation) whose list holds ref, in no order the caller may rely on.
// opts.homeRepo resolves a ref without a repo; opts.entries reuses one listing.
function directHoldersOf(ref, opts) {
  const o = opts || {};
  return listActivePms(o.entries)
    .filter((p) => p.issues.some((i) => S.sameIssue(i, ref, o.homeRepo)))
    .map((p) => ({ tag: p.tag, session_id: p.session_id, assigned_at: assignedAt(p.pm, ref, o.homeRepo) }));
}

module.exports = {
  listPmFiles, currentGenerations, currentOf, isCurrentGeneration, tagInUse, generationOfTag, tagsOf, listPmTags, listActivePms, assignedAt, directHoldersOf,
};
