"use strict";
// One issue, one owning PM (#2942): the PM field checks and writes of the pm key writer. Used by
// ./writer.js and ./rename.js only, always inside the PM lock.
//   fieldIoOf(input, deps) -> {write, read?, prepare?} | null; null (no field I/O at all) when the
//     checkout's origin is not GitHub, so a GitLab or origin-less checkout makes no forge call.
//   assertOneOwner(adds, pm, entries, deadlineAt) — an ancestor's or a descendant's field naming another
//     live PM refuses, as does a tag no local state holds (tag-not-local); a forge failure refuses (fail-closed).
//   writeFields(io, items) — writes [{ref, value}]; an unknown result is read back once.

const path = require("path");
const scan = require("./scan");
const S = require("./schema");
const C = require("./writer-common");

const BIN = path.join(__dirname, "..", "..", "bin", "lib");
const REREAD_MS = 1500;

function fieldIoOf(input, deps) {
  if (deps && deps.pmField) return deps.pmField;
  const { forgeKindOf } = require(path.join(BIN, "pm-field", "forge-kind"));
  const origin = C.homeOriginOf(input, deps);
  if (!origin) C.refuse("this checkout's origin cannot be determined, so the PM field cannot be read or written and the assignment would exist only locally. Run the command in a checkout with an origin remote.");
  if (forgeKindOf({ origin }) !== "github") return null;
  const { createPmField } = require(path.join(BIN, "pm-field", "write"));
  return createPmField({ budgetMs: C.WRITER_WRITE_BUDGET_MS });
}

const ownTag = (pm, tag) => scan.tagsOf(pm).some((t) => S.sameTag(t, tag));

// judge(tag, where, pm, entries) — refuses when tag names a PM other than pm that is live, or no local PM.
function judge(tag, where, pm, entries) {
  if (tag === null || ownTag(pm, tag)) return;
  const g = scan.generationOfTag(tag, entries);
  if (!g) C.refuse(`tag-not-local: ${where} carries the PM ${tag}, which no PM state on this PC holds, so its owner cannot be decided. Ask that PM's user to remove it first.`);
  if (g.pm.archived_at) return;
  C.refuse(`${where} belongs to the PM ${g.pm.tag} (session ${g.session_id}); one issue has one PM. Remove it there with /pm-remove first.`);
}

function assertOneOwner(adds, pm, entries, deadlineAt) {
  if (adds.length === 0) return;
  const { readPmChains } = require(path.join(BIN, "pm-field", "read"));
  const { fetchSubIssueTree, refKey } = require(path.join(BIN, "forge-issue-links"));
  const chains = readPmChains(adds, { deadlineAt });
  if (!chains.ok) C.refuse(`the PM field of ${C.labels(adds)} cannot be read (${chains.reason}); retry when the forge is back.`);
  for (const ref of adds) {
    const c = chains.results[refKey(ref.repo, ref.number)];
    if (!c || !c.ok) C.refuse(`the PM field chain of ${S.refLabel(ref)} cannot be read (${c ? c.reason : "missing"}); retry when the forge is back.`);
    c.chain.forEach((n, i) => judge(n.pm, i === 0 ? S.refLabel(ref) : `${S.refLabel(ref)}'s ancestor ${n.repo}#${n.number}`, pm, entries));
  }
  const tree = fetchSubIssueTree(adds, { deadlineAt });
  if (!tree.ok) C.refuse(`the sub-issues of ${C.labels(adds)} cannot be read (${tree.reason}); retry when the forge is back.`);
  for (const ref of adds) {
    const t = tree.results[refKey(ref.repo, ref.number)];
    if (!t || !t.ok) C.refuse(`the sub-issues of ${S.refLabel(ref)} cannot be read (${t ? t.reason : "missing"}); retry when the forge is back.`);
    for (const d of t.descendants) judge(d.pm, `${S.refLabel(ref)}'s descendant ${d.repo}#${d.number}`, pm, entries);
  }
}

// ownedOnly(io, refs, pm) -> the refs whose PM field still names one of pm's tags or is empty; a field another PM took over
// (the user moved it in the Project UI) is left alone. An unreadable field refuses (fail-closed).
function ownedOnly(io, refs, pm) {
  if (!io || typeof io.read !== "function" || refs.length === 0) return refs;
  const r = io.read(refs, { timeoutMs: REREAD_MS });
  if (!r || !r.ok) C.refuse(`the PM field of ${C.labels(refs)} cannot be read (${(r && r.reason) || "failed"}); the PM state was not changed. Retry when the forge is back.`);
  return refs.filter((ref) => { const v = r.values[`${ref.repo}#${ref.number}`]; return v === undefined || v === null || ownTag(pm, v); });
}

function writeFields(io, items) {
  if (!io || items.length === 0) return;
  if (typeof io.prepare === "function") io.prepare(items.map((i) => i.ref));
  const unknown = [];
  for (const it of items) {
    const r = io.write(it.ref, it.value) || {};
    if (r.result === "unknown") unknown.push(it);
    else if (r.result !== "ok") C.refuse(`pm-field write failed for ${S.refLabel(it.ref)} (${r.reason || r.result || "failed"}); nothing was changed in the PM state. Retry.`);
  }
  if (unknown.length === 0) return;
  const back = typeof io.read === "function" ? io.read(unknown.map((i) => i.ref), { timeoutMs: REREAD_MS }) : { ok: false };
  if (!back || !back.ok) C.refuse(`pm-field-write-unknown: the PM field write of ${C.labels(unknown.map((i) => i.ref))} timed out and cannot be read back; the PM state was not changed. Retry.`);
  for (const it of unknown) {
    const got = back.values[`${it.ref.repo}#${it.ref.number}`];
    if ((got === undefined ? null : got) !== it.value) C.refuse(`pm-field: the write of ${S.refLabel(it.ref)} did not land; the PM state was not changed. Retry.`);
  }
}

module.exports = { fieldIoOf, assertOneOwner, writeFields, ownedOnly };
