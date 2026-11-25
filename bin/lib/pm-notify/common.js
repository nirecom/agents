"use strict";
// Shared parts of bin/pm-notify (#2942): flags, the calling session, issue refs, the owner lookup, and the
// notifications kept in the workflow state: pm_notifications [{id, point, issue, at, from_session, result,
// reason?, to_tag?, tag?, session?, box?}] and pm_owner_records {refKey: {tag|null, at}} (the first owner
// answer of each issue, which detach and next compare with the current one).
// result: pending | sending (handed out by next) | ack | mailbox | unassigned | undelivered | dropped.

const crypto = require("crypto");
const path = require("path");
const HOOKS = path.join(__dirname, "..", "..", "..", "hooks");
const io = require(path.join(HOOKS, "workflow-state", "state-io"));
const S = require(path.join(HOOKS, "pm-session", "schema"));
const scan = require(path.join(HOOKS, "pm-session", "scan"));
const W = require(path.join(HOOKS, "pm-session", "writer-common"));
const { parseIssueToken, parseIssueFlagValue } = require(path.join(HOOKS, "lib", "parse-closes-issues"));
const links = require("../forge-issue-links");
const { resolveOwner } = require("../pm-state/owner");

const OWNER_TIMEOUT_MS = 2000;
const OPEN_RESULTS = ["pending", "undelivered", "sending"];

class Exit extends Error {
  constructor(code, msg, lines) { super(msg); this.code = code; this.lines = lines || []; }
}
const fail = (code, msg, lines) => { throw new Exit(code, msg, lines); };
const isObj = (v) => Boolean(v) && typeof v === "object" && !Array.isArray(v);

// parseFlags(argv, valued, bare?) -> {name: value | true}; anything else is a usage error (exit 2).
function parseFlags(argv, valued, bare) {
  const flags = bare || [];
  const o = {};
  for (let i = 0; i < argv.length; i++) {
    const a = String(argv[i]);
    const name = a.replace(/^--/, "");
    if (a.startsWith("--") && flags.includes(name)) { o[name] = true; continue; }
    if (!a.startsWith("--") || !valued.includes(name) || argv[i + 1] === undefined) fail(2, `unexpected argument: ${a}`, ["REASON=usage"]);
    o[name] = String(argv[++i]);
  }
  return o;
}

function sessionOf() {
  const { resolveSessionId } = require(path.join(HOOKS, "workflow-state", "session-id"));
  const sid = resolveSessionId();
  if (typeof sid !== "string" || !io.SESSION_ID_VALID_RE.test(sid)) fail(2, "the calling session id is unknown (CLAUDE_CODE_SESSION_ID)", ["REASON=no-session"]);
  return sid;
}

let home;
function homeRepo() {
  if (home === undefined) {
    try { const r = links.resolveOwnerRepoFromOrigin(); home = r && r.ok ? r.ownerRepo : null; } catch (_) { home = null; }
  }
  return home;
}

// refOf(token) -> {number, repo:"owner/repo"} of a ref given on the command line (W.normalizeRef).
function refOf(token) {
  const ref = parseIssueFlagValue(String(token || ""));
  if (!ref) fail(2, `not an issue ref: ${token}`, ["REASON=usage"]);
  try { return W.normalizeRef(ref, homeRepo()); } catch (e) {
    if (e instanceof W.Refusal) fail(1, e.message, ["REASON=repo-unresolved"]);
    throw e;
  }
}

// refOfIssue(issue) -> the ref of a stored "owner/repo#N", or null.
function refOfIssue(issue) {
  const r = parseIssueToken(String(issue || ""));
  return r && r.repo && r.repo.includes("/") ? r : null;
}
const issueOf = (ref) => `${ref.repo}#${ref.number}`;
const keyOf = (ref) => links.refKey(ref.repo, ref.number);

// ownerOf(ref, timeoutMs?, entries?, {spawnSync?}?) -> resolveOwner's answer; a throw is an undecidable answer.
function ownerOf(ref, timeoutMs, entries, opts) {
  const spawnSync = opts && typeof opts.spawnSync === "function" ? opts.spawnSync : undefined;
  try {
    return resolveOwner(ref, { scan, entries: entries || scan.listPmFiles(), timeoutMs: Number.isFinite(timeoutMs) ? timeoutMs : OWNER_TIMEOUT_MS, spawnSync });
  } catch (e) {
    return { ok: false, reason: `owner-error: ${e.message}` };
  }
}

// decidedOwnerOf(ref, timeoutMs?, entries?, opts?) -> ownerOf's answer, except that a null owner it cannot trust is
// undecidable {ok:false, reason} (#3135): the board has no pm field (fieldAbsent), or a local active PM state
// holds the issue or an ancestor while the field is empty. Every verb that discards on no-owner uses this gate.
function decidedOwnerOf(ref, timeoutMs, entries, opts) {
  const es = entries || scan.listPmFiles();
  const r = module.exports.ownerOf(ref, timeoutMs, es, opts); // via exports: callers stub ownerOf there
  if (!r || !r.ok || r.owner) return r;
  if (r.fieldAbsent) return { ok: false, reason: "pm-field-absent" };
  const chain = Array.isArray(r.chain) && r.chain.length > 0 ? r.chain : [ref];
  const tags = [];
  for (const c of chain) {
    for (const h of scan.directHoldersOf(c, { entries: es, homeRepo: homeRepo() })) {
      if (!tags.some((t) => S.sameTag(t, h.tag))) tags.push(h.tag);
    }
  }
  return tags.length > 0 ? { ok: false, reason: `pm-field-unset-held: ${tags.join(",")}` } : r;
}

// renamedTo(tag, entries?) -> the current tag of the PM when tag is one of its retired tags, else null.
function renamedTo(tag, entries) {
  const g = scan.generationOfTag(tag, entries);
  if (!g || S.sameTag(g.pm.tag, tag)) return null;
  const retired = Array.isArray(g.pm.retired_tags) ? g.pm.retired_tags : [];
  return retired.some((t) => S.sameTag(t, tag)) ? g.pm.tag : null;
}

function refuseRenamed(tag, entries) {
  const t = renamedTo(tag, entries);
  if (t) fail(1, `PM tag ${tag} was renamed to ${t}; use the new tag`, ["REASON=pm-tag-renamed", `NEW_TAG=${t}`]);
}

function readNotes(sid) {
  const st = io.readRawState(sid);
  return {
    notes: st && Array.isArray(st.pm_notifications) ? st.pm_notifications : [],
    records: st && isObj(st.pm_owner_records) ? st.pm_owner_records : {},
  };
}

// updateNotes(sid, fn(notes, records)) -> fn's value; fn edits the two in place under the state lock.
function updateNotes(sid, fn) {
  let out;
  io.updateTopLevel(sid, (rec) => {
    const notes = Array.isArray(rec.pm_notifications) ? rec.pm_notifications.slice() : [];
    const records = isObj(rec.pm_owner_records) ? Object.assign({}, rec.pm_owner_records) : {};
    out = fn(notes, records);
    if (notes.length > 0) rec.pm_notifications = notes; else delete rec.pm_notifications;
    if (Object.keys(records).length > 0) rec.pm_owner_records = records; else delete rec.pm_owner_records;
  });
  return out;
}

// patchNote(notes, id, patch) — merges patch into the note with id (no-op when it is gone).
function patchNote(notes, id, patch) {
  const i = notes.findIndex((n) => n && n.id === id);
  if (i >= 0) notes[i] = Object.assign({}, notes[i], patch);
}

function newNote(point, issue, sid, extra) {
  return Object.assign({ id: crypto.randomUUID(), point, issue, at: new Date().toISOString(), from_session: sid, result: "pending" }, extra || {});
}

// boxEntry(note, reason?) -> the mailbox form of a notification.
function boxEntry(note, reason) {
  const e = { id: note.id, point: note.point, issue: note.issue, from_session: note.from_session || null, at: note.at || null };
  if (reason) e.reason = reason;
  return e;
}

module.exports = {
  S, W, HOOKS, scan, io, OWNER_TIMEOUT_MS, OPEN_RESULTS, Exit, fail, isObj, parseFlags, sessionOf, homeRepo, refOf, refOfIssue,
  issueOf, keyOf, ownerOf, decidedOwnerOf, renamedTo, refuseRenamed, readNotes, updateNotes, patchNote, newNote, boxEntry,
};
