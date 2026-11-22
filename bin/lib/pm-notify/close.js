"use strict";
// `bin/pm-notify close` (#2942, session-close SC-6a): the last resync of the calling session. Every notification
// still open (pending, undelivered, or sending without a settle) is resolved once more: one with a PM goes to
// that PM's mailbox, one with no owner is dropped, and one still undecidable goes to unassigned.jsonl with its
// issue and reason. A state-bound note (reopen, merge) is dropped when its forge state no longer holds. Prints one line per notification it moved or dropped.

const C = require("./common");
const box = require("./mailbox");
const { targetOf } = require("./next");
const { withPmLock, PmLockBusy } = require("../../../hooks/pm-session/pm-lock");

function close(argv) {
  C.parseFlags(argv, []);
  const sid = C.sessionOf();
  const entries = C.scan.listPmFiles();
  const { notes, records } = C.readNotes(sid);
  const open = notes.filter((n) => n && C.OPEN_RESULTS.includes(n.result));
  const moves = open.map((note) => {
    const ref = C.refOfIssue(note.issue);
    const t = ref ? targetOf(note, ref, { entries, records, forgeState: true }) : { undecidable: "issue-unreadable" };
    if (t.drop) return { note, result: "dropped", reason: t.drop };
    if (t.send) return { note, result: "mailbox", box: t.send.tag };
    return { note, result: "unassigned", box: "unassigned", reason: t.undecidable };
  });
  try {
    withPmLock(() => {
      // The PM state is read again inside the lock: a /pm-rename that ran since moves a tag's mailbox.
      const fresh = C.scan.listPmFiles();
      for (const m of moves) {
        if (!m.box) continue;
        const g = m.box === "unassigned" ? null : C.scan.generationOfTag(m.box, fresh);
        if (g) m.box = g.pm.tag;
        box.deliver(m.box, C.boxEntry(m.note, m.reason));
      }
    });
  } catch (e) {
    if (e instanceof PmLockBusy) C.fail(1, e.message, ["REASON=pm-lock-busy"]);
    throw e;
  }
  C.updateNotes(sid, (ns) => { for (const m of moves) C.patchNote(ns, m.note.id, { result: m.result, box: m.box, reason: m.reason }); });
  const lines = moves.map((m) => `${m.result}: ${m.note.issue} (${m.note.point})${m.box ? ` -> ${m.box}` : ""}${m.reason ? ` ${m.reason}` : ""}`);
  return lines.concat([`CLOSED=${moves.length}`]);
}

module.exports = { close };
