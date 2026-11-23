"use strict";
// `bin/pm-notify inbox --pm` (#2942): the PM side of the notification layer, run under the PM lock after every
// PM command and at PM session start. Advisory and fail-open within one budget (default 2000 ms):
//   1. the own mailbox <tag>.jsonl: ids already in seen_notifications are dropped, the rest is shown, remembered
//      (last SEEN_NOTIFICATIONS_MAX) and removed;
//   2. unassigned.jsonl: own entries are taken and shown, trusted-ownerless ones dropped, the rest left and counted;
//   3. drift (opts.drift only): an assigned issue whose PM field names another PM or none (field absent: one line);
//   4. meta_children: a child gone from its meta parent's sub-issues is shown as a detach once per issue.
// runInbox(sid, {budgetMs?, drift?, origin?}) -> the text to show ("" when there is nothing). Steps 2-4 read
// the forge only when the home origin (opts.origin when given, else the cwd's) is GitHub; otherwise
// unassigned.jsonl is left as is and no gh call is made.

const C = require("./common");
const box = require("./mailbox");
const { batchedGraphql, refKey } = require("../forge-issue-links");
const { readPmFields } = require("../pm-field/read");
const { forgeKindOf } = require("../pm-field/forge-kind");
const { withPmLock, PmLockBusy, PM_LOCK_WAIT_MS } = require("../../../hooks/pm-session/pm-lock");

const DEFAULT_BUDGET_MS = 2000;
const P = "[pm-inbox]";
const CHILDREN = "number subIssues(first:50){nodes{number repository{nameWithOwner}} pageInfo{hasNextPage}}";

const lineOf = (e) => `${P} ${e.point || "?"} ${e.issue || "?"} from=${e.from_session || "-"} at=${e.at || "-"}${e.reason ? ` (${e.reason})` : ""}`;
const lc = (s) => String(s).toLowerCase();

// takeOwn and takeUnassigned only collect: they push a mailbox rewrite onto `after`, run once seen_notifications
// is saved, so a crash in between shows a note twice (dropped by id) and never loses one.
function takeOwn(tag, seen, shown, lines, after) {
  const entries = box.readBox(tag);
  if (entries.length === 0) return;
  for (const e of entries) {
    if (!e || typeof e.id !== "string" || seen.has(e.id)) continue;
    seen.add(e.id);
    shown.add(lc(e.issue));
    lines.push(lineOf(e));
  }
  after.push(() => box.writeBox(tag, []));
}

function takeUnassigned(tag, seen, shown, lines, left, after, forge) {
  const entries = box.readBox("unassigned");
  if (entries.length === 0) return;
  const keep = [];
  for (const e of entries) {
    if (seen.has(e.id)) continue;
    const ref = C.refOfIssue(e.issue);
    const r = forge && ref && left() > 0 ? C.decidedOwnerOf(ref, Math.min(C.OWNER_TIMEOUT_MS, left())) : { ok: false };
    if (r.ok && r.owner && C.S.sameTag(r.owner.tag, tag)) { seen.add(e.id); shown.add(lc(e.issue)); lines.push(lineOf(e)); continue; }
    if (r.ok && !r.owner) continue;
    keep.push(e);
  }
  after.push(() => box.writeBox("unassigned", keep));
  if (keep.length > 0) lines.push(`${P} unassigned.jsonl still holds ${keep.length} notification(s) whose PM is not decided`);
}

function checkDrift(pm, lines, deadlineAt) {
  const refs = (Array.isArray(pm.issues) ? pm.issues : []).map((i) => C.refOfIssue(`${C.S.resolveRepo(i, C.homeRepo())}#${i.number}`)).filter(Boolean);
  if (refs.length === 0) return;
  const r = readPmFields(refs, { deadlineAt });
  if (!r.ok) { lines.push(`${P} drift check skipped (${r.reason}); it runs at the next PM command`); return; }
  const absent = [];
  for (const ref of refs) {
    const key = `${ref.repo}#${ref.number}`;
    const v = r.values[key];
    if (r.fieldAbsent && r.fieldAbsent[key]) { absent.push(key); continue; }
    if (!C.S.sameTag(v, pm.tag)) lines.push(`${P} drift: ${ref.repo}#${ref.number} is in this PM state but its PM field is ${v || "(empty)"}; rerun the PM command or fix the field`);
  }
  // A board without the pm field is one cause, reported once instead of a drift per issue (#3135).
  if (absent.length > 0) lines.push(`${P} drift check skipped for ${absent.join(", ")}: the board has no \`pm\` field (field absent); run /migrate-tracker to add it`);
}

// checkMeta(meta, assigned, shown, lines, deadlineAt) -> the updated meta_children, or null when unchanged/unread.
// An assigned issue not in meta yet is read once: its children (when it has any) become the baseline, so no
// detach is reported on the first sight; later reads compare against it.
function checkMeta(meta, assigned, shown, lines, deadlineAt) {
  const known = Object.keys(meta);
  const keys = known.concat(assigned.filter((a) => !known.some((k) => lc(k) === lc(a))));
  const refs = keys.map(C.refOfIssue).filter(Boolean);
  if (refs.length === 0) return null;
  const read = (node) => {
    const s = node.subIssues;
    if (!s || !Array.isArray(s.nodes) || (s.pageInfo && s.pageInfo.hasNextPage)) return { ok: false, reason: "sub-issues-unread" };
    return { ok: true, kids: s.nodes.filter((c) => c && c.repository).map((c) => `${c.repository.nameWithOwner}#${c.number}`) };
  };
  const r = batchedGraphql(refs, { fields: CHILDREN, readNode: read }, { deadlineAt });
  if (!r.ok) {
    if (known.length > 0) lines.push(`${P} meta detach check skipped (${r.reason}); it runs at the next PM command`);
    return null;
  }
  const out = Object.assign({}, meta);
  let changed = false;
  for (const key of keys) {
    const ref = C.refOfIssue(key);
    const got = ref ? r.results[refKey(ref.repo, ref.number)] : null;
    if (!got || !got.ok) continue;
    if (!known.includes(key)) {
      if (got.kids.length > 0) { out[key] = got.kids; changed = true; }
      continue;
    }
    const now = new Set(got.kids.map(lc));
    const old = Array.isArray(meta[key]) ? meta[key] : [];
    for (const c of old.filter((x) => !now.has(lc(x)))) {
      if (!shown.has(lc(c))) lines.push(`${P} detach: ${c} is no longer a sub-issue of ${key}`);
      shown.add(lc(c));
    }
    const kept = old.filter((x) => now.has(lc(x)));
    const added = got.kids.filter((k) => !old.some((x) => lc(x) === lc(k)));
    const next = kept.concat(added);
    if (next.length !== old.length || added.length > 0) { out[key] = next; changed = true; }
  }
  return changed ? out : null;
}

// isGithubHome(o) -> true only for a GitHub home origin; a given but absent (null) origin is not GitHub.
function isGithubHome(o) {
  if (!Object.prototype.hasOwnProperty.call(o, "origin")) return forgeKindOf({}) === "github";
  return typeof o.origin === "string" && forgeKindOf({ origin: o.origin }) === "github";
}

function runInbox(sid, opts) {
  const o = opts || {};
  const budget = Number.isFinite(o.budgetMs) ? o.budgetMs : DEFAULT_BUDGET_MS;
  const deadlineAt = Date.now() + budget;
  const left = () => deadlineAt - Date.now();
  let st;
  try { st = C.io.readRawState(sid); } catch (_) { return ""; }
  if (!C.S.hasPmMark(st) || typeof st.pm.tag !== "string") return "";
  const tag = st.pm.tag;
  const forge = isGithubHome(o);
  const lines = [];
  try {
    withPmLock(() => {
      const pm = (C.io.readRawState(sid) || {}).pm || st.pm;
      const seen = new Set(Array.isArray(pm.seen_notifications) ? pm.seen_notifications : []);
      const before = seen.size;
      const shown = new Set();
      const after = [];
      takeOwn(tag, seen, shown, lines, after);
      takeUnassigned(tag, seen, shown, lines, left, after, forge);
      if (forge && o.drift && !pm.archived_at && left() > 0) checkDrift(pm, lines, deadlineAt);
      const assigned = pm.archived_at ? [] : (Array.isArray(pm.issues) ? pm.issues : []).map((i) => `${C.S.resolveRepo(i, C.homeRepo())}#${i.number}`);
      const meta = forge && left() > 0 && (C.isObj(pm.meta_children) || assigned.length > 0)
        ? checkMeta(C.isObj(pm.meta_children) ? pm.meta_children : {}, assigned, shown, lines, deadlineAt) : null;
      if (seen.size !== before || meta) {
        C.io.updateTopLevel(sid, (rec) => {
          if (!C.S.hasPmMark(rec)) return;
          const patch = { seen_notifications: [...seen].slice(-C.S.SEEN_NOTIFICATIONS_MAX) };
          if (meta) patch.meta_children = meta;
          rec.pm = Object.assign({}, rec.pm, patch);
        });
      }
      for (const run of after) run();
    }, { waitMs: Math.max(1, Math.min(PM_LOCK_WAIT_MS, left())) });
  } catch (e) {
    const why = e instanceof PmLockBusy ? "the PM lock is busy" : e.message;
    lines.push(`${P} skipped (${why}); it runs at the next PM command`);
  }
  return lines.join("\n");
}

function inbox(argv) {
  const o = C.parseFlags(argv, ["budget-ms"], ["pm"]);
  if (!o.pm) C.fail(2, "usage: inbox --pm [--budget-ms <n>]", ["REASON=usage"]);
  const sid = C.sessionOf();
  const st = C.io.readRawState(sid);
  if (!C.S.hasPmMark(st)) C.fail(1, `session ${sid} is not a PM session`, ["REASON=no-pm-state"]);
  const budgetMs = o["budget-ms"] && /^[1-9][0-9]*$/.test(o["budget-ms"]) ? Number(o["budget-ms"]) : DEFAULT_BUDGET_MS;
  const text = runInbox(sid, { budgetMs, drift: true });
  return text ? text.split("\n") : [];
}

module.exports = { inbox, runInbox, DEFAULT_BUDGET_MS };
