"use strict";
// `bin/pm-notify settle --id <id> --result ack|timeout|offline` (#2942): ack records the delivery; timeout and
// offline file the notification into the PM's mailbox under the PM lock (the PM reads it with `inbox --pm`).
// A tag retired by /pm-rename is never written to: the owner is looked up again (a detach note goes to the
// renamed PM itself), and a note whose PM cannot be found goes to unassigned.jsonl with the reason.

const C = require("./common");
const box = require("./mailbox");
const { withPmLock, PmLockBusy } = require("../../../hooks/pm-session/pm-lock");

const RESULTS = ["ack", "timeout", "offline"];

// boxOf(note, entries) -> {name, reason?}: the mailbox a not-acknowledged note goes to.
function boxOf(note, entries) {
  const tag = note.tag || note.to_tag;
  const g = tag ? C.scan.generationOfTag(tag, entries) : null;
  if (g && C.S.sameTag(g.pm.tag, tag)) return { name: g.pm.tag };
  if (g && note.to_tag) return { name: g.pm.tag };
  const ref = C.refOfIssue(note.issue);
  const r = ref ? C.ownerOf(ref, C.OWNER_TIMEOUT_MS, entries) : { ok: false, reason: "issue-unreadable" };
  if (r.ok && r.owner) return { name: r.owner.tag };
  return { name: "unassigned", reason: r.ok ? `no-owner (was ${tag || "none"})` : r.reason };
}

// file(note) -> the box name; the caller handles PmLockBusy. The PM states are read inside the lock, so a
// /pm-rename that ran meanwhile has already moved the mailbox this note must follow.
function file(note) {
  return withPmLock(() => {
    const to = boxOf(note, C.scan.listPmFiles());
    box.deliver(to.name, C.boxEntry(note, to.reason));
    return to.name;
  });
}

function settle(argv) {
  const o = C.parseFlags(argv, ["id", "result"]);
  if (!o.id || !RESULTS.includes(o.result)) C.fail(2, "usage: settle --id <id> --result ack|timeout|offline", ["REASON=usage"]);
  const sid = C.sessionOf();
  const note = C.readNotes(sid).notes.find((n) => n && n.id === o.id);
  if (!note) C.fail(1, `no notification ${o.id} in session ${sid}`, ["REASON=unknown-id"]);
  if (o.result === "ack") {
    C.updateNotes(sid, (ns) => C.patchNote(ns, o.id, { result: "ack", reason: undefined }));
    return ["RESULT=ack"];
  }
  let name;
  try { name = file(note); } catch (e) {
    if (e instanceof PmLockBusy) C.fail(1, e.message, ["REASON=pm-lock-busy"]);
    throw e;
  }
  C.updateNotes(sid, (ns) => C.patchNote(ns, o.id, { result: name === "unassigned" ? "unassigned" : "mailbox", box: name, reason: o.result }));
  return [`RESULT=${name === "unassigned" ? "unassigned" : "mailbox"}`, `BOX=${name}`];
}

module.exports = { settle, file, boxOf };
