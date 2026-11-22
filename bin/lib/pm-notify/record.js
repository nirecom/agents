"use strict";
// `bin/pm-notify record --point <p> --issue <ref>` (#2942): keeps a pending notification for the PM that owns
// the issue in the calling session's workflow state; the owner is looked up when it is sent (next). A pending
// or undelivered one with the same point, issue and addressee is reused, so a rerun of a point sends once.
// Prints ID=<id>. In-process callers (the workflow-init phases) use recordFor(sid, point, ref).

const path = require("path");
const C = require("./common");

const POINT_RE = /^[a-z][a-z0-9-]{0,39}$/;

// keep(notes, point, issue, sid, extra?) -> the id of the reused or appended notification.
function keep(notes, point, issue, sid, extra) {
  const x = extra || {};
  const same = notes.find((n) => n && (n.result === "pending" || n.result === "undelivered") && n.point === point
    && String(n.issue).toLowerCase() === issue.toLowerCase() && (n.to_tag || null) === (x.to_tag || null));
  if (same) {
    if (x.reason) C.patchNote(notes, same.id, { reason: x.reason });
    return same.id;
  }
  const note = C.newNote(point, issue, sid, x);
  notes.push(note);
  return note.id;
}

// recordFor(sid, point, ref) -> the id; ref is normalized ({number, repo:"owner/repo"}).
function recordFor(sid, point, ref) {
  const issue = C.issueOf(ref);
  return C.updateNotes(sid, (notes) => keep(notes, point, issue, sid));
}

// sessionIssues(sid) -> the refs a session-level point is about: closes_issues of its intent, else the issues
// whose first owner record names a PM (pm-scan at workflow-init).
function sessionIssues(sid) {
  let refs;
  try { refs = require(path.join(C.HOOKS, "workflow-state", "session-facts")).getClosesIssues(sid); } catch (_) { refs = []; }
  const out = [];
  const { records } = C.readNotes(sid);
  for (const r of refs) { try { out.push(C.W.normalizeRef(r, C.homeRepo())); } catch (_) { /* repo unknown */ } }
  // An issue pm-scan found ownerless needs no notification.
  if (out.length > 0) return out.filter((ref) => { const v = records[C.keyOf(ref)]; return !v || v.tag; });
  for (const [key, v] of Object.entries(records)) {
    const m = /^(.+)#([1-9][0-9]*)$/.exec(key);
    if (m && v && v.tag) out.push({ repo: m[1], number: Number(m[2]) });
  }
  return out;
}

// recordSessionIssues(sid, point): one notification per session issue (set-deliverable-type wf-meta,
// next-step --scope-change-approved). Fail-open: a failure never changes the caller's outcome.
function recordSessionIssues(sid, point) {
  try {
    const refs = sessionIssues(sid);
    if (refs.length > 0) C.updateNotes(sid, (notes) => { for (const ref of refs) keep(notes, point, C.issueOf(ref), sid); });
  } catch (_) { /* fail-open */ }
}

function record(argv) {
  const o = C.parseFlags(argv, ["point", "issue"]);
  if (!o.point || !POINT_RE.test(o.point) || !o.issue) C.fail(2, "usage: record --point <point> --issue <ref>", ["REASON=usage"]);
  const sid = C.sessionOf();
  return [`ID=${recordFor(sid, o.point, C.refOf(o.issue))}`];
}

module.exports = { record, recordFor, recordSessionIssues, keep };
