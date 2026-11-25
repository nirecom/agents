"use strict";
// `/pm-rename <new tag>` for the pm key writer (#2942), run inside the PM lock. Order: check the tag
// like /pm-init -> record rename_pending {from, to} -> write the new tag into every issue's PM field
// (only fields that carry the old tag or none) -> move the old tag's mailbox -> swap the tag, retire the old
// one, clear rename_pending. A failure midway keeps rename_pending; retyping the same command
// resumes it, and owner maps both tags to this PM meanwhile (scan.generationOfTag).

const path = require("path");
const io = require("../workflow-state/state-io");
const S = require("./schema");
const scan = require("./scan");
const C = require("./writer-common");
const O = require("./ownership");
const { nextActionOf } = require(path.join(__dirname, "..", "..", "bin", "lib", "forge-failure"));

const { refuse } = C;

// pendingWrites(io, refs, from) -> the refs whose field still carries `from` or is empty.
// A field that names a third PM (moved in the Project UI) is left alone, not overwritten. An unreadable field
// refuses (fail-closed, like ownership.ownedOnly); rename_pending stays, so retyping the command resumes.
function pendingWrites(fio, refs, from) {
  if (!fio || typeof fio.read !== "function" || refs.length === 0) return refs;
  const r = O.readFields(fio, refs);
  if (!r || !r.ok) {
    const reason = (r && r.reason) || "failed";
    refuse(`the PM field of ${C.labels(refs)} cannot be read (${reason}); no field was written, and the same /pm-rename resumes the rename. ${nextActionOf(reason)}`);
  }
  return refs.filter((ref) => {
    const v = r.values[`${ref.repo}#${ref.number}`];
    return v === undefined || v === null || S.sameTag(v, from);
  });
}

function rename(sid, args, now, ctx) {
  const to = String(args || "").trim().split(/\s+/)[0] || "";
  if (!S.isValidPmTag(to)) refuse("usage: /pm-rename <new tag>; the tag is 1 to 40 characters of letters, digits and - only");
  const own = C.rawOf(sid);
  if (!S.hasPmMark(own)) refuse("/pm-rename needs a PM session; start one with /pm-init.");
  if (!S.isActivePm(own)) refuse(`the PM ${own.pm.tag} has ended; an ended PM takes no change.`);
  const entries = scan.listPmFiles();
  if (!scan.isCurrentGeneration(sid, entries)) {
    const cur = scan.currentOf(own.pm.tag, entries);
    refuse(`this session is an old generation of ${own.pm.tag}; the current one is session ${cur ? cur.session_id : "(unknown)"}. Rename there.`);
  }
  const from = own.pm.tag;
  const pending = own.pm.rename_pending && typeof own.pm.rename_pending === "object" ? own.pm.rename_pending : null;
  if (pending && !S.sameTag(pending.to, to)) {
    refuse(`a rename of ${pending.from} to ${pending.to} is unfinished; finish it with \`/pm-rename ${pending.to}\` first.`);
  }
  if (!pending && scan.tagInUse(to, entries)) refuse(`the tag ${to} is already used (tags are never reused: ended PMs and renamed tags included); choose another.`);
  const target = pending ? pending.to : to;
  io.updateTopLevel(sid, (rec) => {
    if (!S.isActivePm(rec) || rec.pm.tag !== from) refuse("the PM changed while this command ran; retry.");
    rec.pm = Object.assign({}, rec.pm, { rename_pending: { from, to: target } });
  });
  const refs = (own.pm.issues || []).map((i) => C.normalizeStoredRef(i, ctx.home)).filter((r) => typeof r.repo === "string" && r.repo.includes("/"));
  const fio = refs.length > 0 ? ctx.io : null;
  O.writeFields(fio, pendingWrites(fio, refs, from).map((ref) => ({ ref, value: target })));
  // The mailbox moves before the tag is committed: a failed move keeps rename_pending, so the same /pm-rename resumes.
  require(path.join(__dirname, "..", "..", "bin", "lib", "pm-notify", "mailbox")).moveMailbox(from, target);
  let pm = null;
  io.updateTopLevel(sid, (rec) => {
    if (!S.isActivePm(rec) || rec.pm.tag !== from) refuse("the PM changed while this command ran; retry.");
    const retired = (Array.isArray(rec.pm.retired_tags) ? rec.pm.retired_tags : []).concat([from]);
    const next = Object.assign({}, rec.pm, { tag: target, retired_tags: retired });
    delete next.rename_pending;
    rec.pm = next;
    pm = next;
  });
  const notice = `[pm-session] /pm-rename ${from} -> ${target}`;
  return { context: C.note("rename", pm, [`renamed_from=${from}`]), notice };
}

module.exports = { rename };
