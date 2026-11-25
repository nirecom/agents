"use strict";
// One issue, one owning PM (#2942): the PM field checks and writes of the pm key writer. Used by
// ./writer.js and ./rename.js only, always inside the PM lock. Budget contract (#3152): docs/architecture/cross-session-messaging.md.
//   fieldIoOf(input, deps) -> createPmField's I/O | deps.pmField | null (the origin is not GitHub: no forge call).
//   assertOneOwner(adds, pm, entries, {deadlineAt, deps}) -> the cards read on the way; an ancestor's or a descendant's
//     field naming another live PM refuses, as does a tag no local PM holds or a forge failure (fail-closed).
//   readFields(io, refs) -> {ok, values} of the check stage (cards seeded when the I/O reads them in the same call).
//   writeFields(io, items, cards?) — seeds cards, prepares the missing ones, writes [{ref, value}] in one writeMany,
//     and reads back only the unknown ones. Every refusal ends with forge-failure.js nextActionOf(reason).

const path = require("path");
const scan = require("./scan");
const S = require("./schema");
const C = require("./writer-common");
const { budgetOf, GH_MIN_CALL_MS } = require("./budget");

const BIN = path.join(__dirname, "..", "..", "bin", "lib");
const { nextActionOf } = require(path.join(BIN, "forge-failure"));

const spawnOf = (deps) => (deps && typeof deps.spawnSync === "function" ? deps.spawnSync : undefined);
const cannot = (what, reason) => `${what} cannot be read (${reason}). ${nextActionOf(reason)}`;

function fieldIoOf(input, deps) {
  if (deps && deps.pmField) return deps.pmField;
  const { forgeKindOf } = require(path.join(BIN, "pm-field", "forge-kind"));
  const origin = C.homeOriginOf(input, deps);
  if (!origin) C.refuse("this checkout's origin cannot be determined, so the PM field cannot be read or written and the assignment would exist only locally. Run the command in a checkout with an origin remote.");
  if (forgeKindOf({ origin }) !== "github") return null;
  const { createPmField } = require(path.join(BIN, "pm-field", "write"));
  return createPmField({ budget: budgetOf(deps), spawnSync: spawnOf(deps), minCallMs: GH_MIN_CALL_MS });
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

function assertOneOwner(adds, pm, entries, opts) {
  if (adds.length === 0) return {};
  const o = opts || {};
  const deps = o.deps || {};
  const { refKey } = require(path.join(BIN, "forge-issue-links"));
  const read = typeof deps.readChainsAndTrees === "function" ? deps.readChainsAndTrees : require(path.join(BIN, "sub-issue-tree")).readChainsAndTrees;
  const deadlineAt = Number.isFinite(o.deadlineAt) ? o.deadlineAt : undefined;
  const r = read(adds, { deadlineAt, spawnSync: spawnOf(deps), minCallMs: GH_MIN_CALL_MS });
  if (!r || !r.ok) C.refuse(cannot(`the PM field and sub-issues of ${C.labels(adds)}`, (r && r.reason) || "failed"));
  for (const ref of adds) {
    const c = (r.chains || {})[refKey(ref.repo, ref.number)];
    if (!c || !c.ok) C.refuse(cannot(`the PM field chain of ${S.refLabel(ref)}`, c ? c.reason : "missing"));
    c.chain.forEach((n, i) => judge(n.pm, i === 0 ? S.refLabel(ref) : `${S.refLabel(ref)}'s ancestor ${n.repo}#${n.number}`, pm, entries));
  }
  for (const ref of adds) {
    const t = (r.trees || {})[refKey(ref.repo, ref.number)];
    if (!t || !t.ok) C.refuse(cannot(`the sub-issues of ${S.refLabel(ref)}`, t ? t.reason : "missing"));
    for (const d of t.descendants) judge(d.pm, `${S.refLabel(ref)}'s descendant ${d.repo}#${d.number}`, pm, entries);
  }
  return r.cards || {};
}

function readFields(io, refs) {
  if (typeof io.readFieldsAndCards === "function") return io.readFieldsAndCards(refs);
  return io.read(refs);
}

// ownedOnly(io, refs, pm) -> the refs whose PM field still names one of pm's tags or is empty; a field another PM took over
// (the user moved it in the Project UI) is left alone. An unreadable field refuses (fail-closed).
function ownedOnly(io, refs, pm) {
  if (!io || typeof io.read !== "function" || refs.length === 0) return refs;
  const r = readFields(io, refs);
  if (!r || !r.ok) C.refuse(`${cannot(`the PM field of ${C.labels(refs)}`, (r && r.reason) || "failed")} The PM state was not changed.`);
  return refs.filter((ref) => { const v = r.values[`${ref.repo}#${ref.number}`]; return v === undefined || v === null || ownTag(pm, v); });
}

function resultsOf(io, items) {
  if (typeof io.writeMany !== "function") return items.map((it) => Object.assign({ ref: it.ref, value: it.value }, io.write(it.ref, it.value) || {}));
  const r = io.writeMany(items);
  return Array.isArray(r) ? r : (r && Array.isArray(r.results) ? r.results : []);
}

function writeFields(io, items, cards) {
  if (!io || items.length === 0) return;
  if (cards && typeof io.seedCards === "function") io.seedCards(cards);
  if (typeof io.prepare === "function") {
    const p = io.prepare(items.map((i) => i.ref));
    if (p && p.ok === false) C.refuse(`${cannot(`the Project cards of ${C.labels(items.map((i) => i.ref))}`, p.reason || "failed")} Nothing was changed in the PM state.`);
  }
  const results = resultsOf(io, items);
  const unknown = [];
  items.forEach((it, i) => {
    const r = results[i] || {};
    if (r.result === "unknown") unknown.push(it);
    else if (r.result !== "ok") {
      const reason = r.reason || r.result || "failed";
      C.refuse(`pm-field write failed for ${S.refLabel(it.ref)} (${reason}); nothing was changed in the PM state. ${nextActionOf(reason)}`);
    }
  });
  if (unknown.length === 0) return;
  const back = typeof io.read === "function" ? io.read(unknown.map((i) => i.ref)) : { ok: false };
  if (!back || !back.ok) {
    const reason = (back && back.reason) || "timeout";
    C.refuse(`pm-field-write-unknown: the PM field write of ${C.labels(unknown.map((i) => i.ref))} timed out and cannot be read back (${reason}); the PM state was not changed. ${nextActionOf(reason)}`);
  }
  for (const it of unknown) {
    const got = back.values[`${it.ref.repo}#${it.ref.number}`];
    if ((got === undefined ? null : got) !== it.value) C.refuse(`pm-field: the write of ${S.refLabel(it.ref)} did not land; the PM state was not changed. ${nextActionOf("timeout")}`);
  }
}

module.exports = { fieldIoOf, assertOneOwner, readFields, writeFields, ownedOnly };
