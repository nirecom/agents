"use strict";
// `bin/pm-notify detach --issue <ref> --phase before|after` (#2942): brackets a dispatch that may take a child
// off its meta parent (issue-create-dispatch.sh make-parent --children). before stores the owner answer as the
// issue's owner record; after compares the current answer with it and, when the PM differs, records a detach
// notification addressed to the former PM (to_tag). An undecidable answer keeps the record. Fail-open: exit 0.

const C = require("./common");

function detach(argv) {
  const o = C.parseFlags(argv, ["issue", "phase"]);
  if (!o.issue || (o.phase !== "before" && o.phase !== "after")) C.fail(2, "usage: detach --issue <ref> --phase before|after", ["REASON=usage"]);
  const sid = C.sessionOf();
  const ref = C.refOf(o.issue);
  const key = C.keyOf(ref);
  const r = C.ownerOf(ref);
  if (!r.ok) return ["RESULT=undecidable", `REASON=${r.reason}`];
  const tag = r.owner ? r.owner.tag : null;
  const at = new Date().toISOString();
  return C.updateNotes(sid, (notes, records) => {
    const first = records[key];
    records[key] = { tag, at };
    if (o.phase === "before" || !first || !first.tag || C.S.sameTag(first.tag, tag)) return ["RESULT=recorded", `OWNER_TAG=${tag || ""}`];
    const note = C.newNote("detach", C.issueOf(ref), sid, { to_tag: first.tag });
    notes.push(note);
    return ["RESULT=detach", `ID=${note.id}`, `TO_TAG=${first.tag}`];
  });
}

module.exports = { detach };
