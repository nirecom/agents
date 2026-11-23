"use strict";
// `bin/pm-notify next` (#2942): hands out the next pending or undelivered notification of the calling session.
// The owner is looked up again on every try (owner, 2000 ms), so a resend reaches the current PM. A note tied to
// a forge state (reopen: OPEN, merge: CLOSED) is dropped once that state no longer holds; a note with no owner
// is dropped; an undecidable one (an untrusted null owner included, C.decidedOwnerOf) stays undelivered with its reason. When the owner differs from the first owner
// record (a detach done outside the workflow), a detach note for the first owner is added.
// Prints `SEND` with ID/TAG/SESSION/ISSUE/POINT and marks the note sending, or prints nothing when none is left.
// A note still `sending` (handed out, never settled: an interrupted send) is handed out again; the PM drops the
// repeat by id. A note whose issue cannot be read stays undelivered and reaches unassigned.jsonl at close.

const C = require("./common");
const { batchedGraphql, refKey } = require("../forge-issue-links");

const STATE_BOUND = { reopen: "OPEN", merge: "CLOSED" };

// forgeStateOf(ref) -> "OPEN" | "CLOSED" | null (unreadable).
function forgeStateOf(ref) {
  const r = batchedGraphql([ref], { fields: "number state", readNode: (n) => ({ ok: true, state: n.state || null }) }, { timeoutMs: C.OWNER_TIMEOUT_MS });
  const v = r.ok ? r.results[refKey(ref.repo, ref.number)] : null;
  return v && v.ok ? v.state : null;
}

// targetOf(note, ref, ctx) -> {send:{tag, session}} | {drop: reason} | {undecidable: reason}, plus
// record/detach when the owner answer is new or differs from the first owner record. ctx: {entries, records, forgeState}.
function targetOf(note, ref, ctx) {
  if (note.to_tag) {
    const g = C.scan.generationOfTag(note.to_tag, ctx.entries);
    if (!g) return { undecidable: `tag-not-local: ${note.to_tag}` };
    if (g.pm.archived_at) return { drop: "pm-ended" };
    return { send: { tag: g.pm.tag, session: g.session_id } };
  }
  const bound = STATE_BOUND[note.point];
  if (bound && ctx.forgeState) {
    const st = forgeStateOf(ref);
    if (!st) return { undecidable: "forge-state-unread" };
    if (st !== bound) return { drop: `forge-state-changed: ${st}` };
  }
  const r = C.decidedOwnerOf(ref, C.OWNER_TIMEOUT_MS, ctx.entries);
  if (!r.ok) return { undecidable: r.reason };
  const tag = r.owner ? r.owner.tag : null;
  const out = r.owner ? { send: { tag, session: r.owner.session_id } } : { drop: "no-owner" };
  const key = C.keyOf(ref);
  const first = Object.prototype.hasOwnProperty.call(ctx.records, key) ? ctx.records[key] : undefined;
  if (first === undefined || !sameOwner(first.tag, tag)) out.record = { tag, at: new Date().toISOString() };
  if (first && first.tag && !sameOwner(first.tag, tag)) out.detach = first.tag;
  return out;
}

const sameOwner = (a, b) => (a === null || a === undefined ? b === null || b === undefined : C.S.sameTag(a, b));

// apply(notes, records, note, t, sid) — writes targetOf's answer into the notes and records.
function apply(notes, records, note, t, sid) {
  const key = C.keyOf(C.refOfIssue(note.issue));
  if (t.record) records[key] = t.record;
  if (t.detach) notes.push(C.newNote("detach", note.issue, sid, { to_tag: t.detach }));
  if (t.drop) C.patchNote(notes, note.id, { result: "dropped", reason: t.drop });
  else if (t.undecidable) C.patchNote(notes, note.id, { result: "undelivered", reason: t.undecidable });
  else C.patchNote(notes, note.id, { result: "sending", tag: t.send.tag, session: t.send.session, reason: undefined });
}

function next(argv) {
  C.parseFlags(argv, []);
  const sid = C.sessionOf();
  const entries = C.scan.listPmFiles();
  const { notes, records } = C.readNotes(sid);
  for (const note of notes) {
    if (!note || !C.OPEN_RESULTS.includes(note.result)) continue;
    const ref = C.refOfIssue(note.issue);
    if (!ref) {
      if (note.result !== "undelivered" || note.reason !== "issue-unreadable") {
        C.updateNotes(sid, (ns) => C.patchNote(ns, note.id, { result: "undelivered", reason: "issue-unreadable" }));
      }
      continue;
    }
    const t = targetOf(note, ref, { entries, records, forgeState: true });
    C.updateNotes(sid, (ns, rs) => apply(ns, rs, note, t, sid));
    if (t.record) records[C.keyOf(ref)] = t.record;
    if (t.send) {
      return ["SEND", `ID=${note.id}`, `TAG=${t.send.tag}`, `SESSION=${t.send.session}`, `ISSUE=${note.issue}`, `POINT=${note.point}`];
    }
  }
  return [];
}

module.exports = { next, targetOf, apply };
