"use strict";
// #2962 part of tests/hooks/feat-2529-glossary-accept.js: the batch grant
// `term=* batch=definition-only [cat=<category>]` covers, in one sentinel, every provenance block
// that is a redefine with fields_changed === false, each grant carrying basis "definition-only".
// Holds no case markers; the entrypoint wraps each run function in one.

const REASON = "user accepted the reworded definitions";
const BATCH = "batch=definition-only";

// A session at write_code with one injected glossary_provenance record holding `blocked`.
function seeded(F, tag, blocked) {
  const repo = F.mkRepo(tag);
  const sid = F.newSid(tag);
  F.writeIntent(sid);
  F.seedAt(sid, "write_code", repo);
  F.inject(sid, "review_docs", "glossary_provenance", F.provenanceRecord(F.FP("c"), blocked));
  return { repo, sid };
}
const grantsOf = (F, sid) => {
  const p = F.ann(sid, "review_docs", "glossary_provenance");
  return (p && Array.isArray(p.grants)) ? p.grants : [];
};
const blk = (term, operation, category, fieldsChanged) => Object.assign({ term, operation, category, reason: "unmatched" },
  fieldsChanged === undefined ? {} : { fields_changed: fieldsChanged });

const MIXED = [
  blk("alpha term", "redefine", "user", false),
  blk("beta term", "redefine", "internal", false),
  blk("gamma term", "redefine", "user", true),
  blk("delta term", "add", "user", false),
  blk("epsilon term", "delete", "internal", false),
  blk("old term", "redefine", "user"),
];

function covers(F) {
  const s = seeded(F, "batch-all", MIXED);
  const r = F.mark(s.sid, F.accepted("*", BATCH, REASON), s.repo);
  const g = grantsOf(F, s.sid);
  const norms = g.map((x) => x.norm).sort();
  F.check("batch: one sentinel grants every redefine with fields_changed false, and nothing else",
    JSON.stringify(norms) === JSON.stringify(["alpha term", "beta term"]), `${JSON.stringify(g)} ${r.all}`);
  F.check("batch: each grant is { norm, operation: redefine, category, basis: definition-only, reason, fingerprint }",
    g.length === 2 && g.every((x) => x.operation === "redefine" && x.basis === "definition-only" &&
      x.reason === REASON && x.fingerprint === F.FP("c") && typeof x.category === "string"), JSON.stringify(g));
  F.check("batch: a redefine with fields_changed true, an add, a delete and an old entry stay ungranted",
    !g.some((x) => ["gamma term", "delta term", "epsilon term", "old term"].includes(x.norm)), JSON.stringify(g));
}

// replyMessage(all) — the hook's pushed message (systemMessage of its JSON output line).
function replyMessage(all) {
  for (const line of String(all).split(/\r?\n/)) {
    try {
      const o = JSON.parse(line);
      if (o && typeof o.systemMessage === "string") return o.systemMessage;
    } catch (_e) { /* not the JSON output line */ }
  }
  return "";
}
// grantedPart(all) — the grant list of the reply: the text after `grant recorded for "<term>" — `.
function grantedPart(all) {
  const s = replyMessage(all);
  const i = s.indexOf("grant recorded for");
  const j = i < 0 ? -1 : s.indexOf(" — ", i);
  return j < 0 ? "" : s.slice(j + 3);
}

function replyNames(F) {
  const s = seeded(F, "batch-reply", MIXED);
  const r = F.mark(s.sid, F.accepted("*", BATCH, REASON), s.repo);
  const part = grantedPart(r.all);
  F.check("batch reply: the grant list names every covered definition-only redefine term",
    part.includes("alpha term") && part.includes("beta term"), r.all);
  const msg = replyMessage(r.all);
  F.check("batch reply: names no uncovered term (fields redefine, add, delete, old entry)",
    /grant recorded/.test(msg) && !["gamma term", "delta term", "epsilon term", "old term"].some((t) => msg.includes(t)), r.all);
}

function singleReplyNames(F) {
  const s = seeded(F, "single-reply", [blk("alpha term", "redefine", "user", false)]);
  const r = F.mark(s.sid, F.accepted("alpha term", "", REASON), s.repo);
  F.check("single-term provenance grant reply: the grant list names that term",
    /provenance/.test(grantedPart(r.all)) && grantedPart(r.all).includes("alpha term"), r.all);
}

function byCategory(F) {
  const s = seeded(F, "batch-cat", MIXED);
  const r = F.mark(s.sid, F.accepted("*", `${BATCH} cat=internal`, REASON), s.repo);
  const g = grantsOf(F, s.sid);
  F.check("batch cat=internal: only the internal definition-only redefine is granted",
    g.length === 1 && g[0].norm === "beta term" && g[0].category === "internal" && g[0].basis === "definition-only",
    `${JSON.stringify(g)} ${r.all}`);
}

function none(F) {
  const s = seeded(F, "batch-none", [blk("gamma term", "redefine", "user", true), blk("delta term", "add", "user", false)]);
  const before = F.rawState(s.sid);
  const r = F.mark(s.sid, F.accepted("*", BATCH, REASON), s.repo);
  F.check("batch with no definition-only redefine: the reply says GLOSSARY_ACCEPTED matched nothing",
    /GLOSSARY_ACCEPTED/.test(r.all) && /definition-only|batch/.test(r.all), r.all);
  F.check("batch with no definition-only redefine: state unchanged", F.rawState(s.sid) === before, r.all);
}

function refused(F) {
  const s = seeded(F, "batch-bad", MIXED);
  F.expectRejected("batch without term=*", s.sid, F.accepted("alpha term", BATCH, REASON), s.repo);
  F.expectRejected("batch combined with step=", s.sid, F.accepted("*", `${BATCH} step=review_docs`, REASON), s.repo);
  F.expectRejected("batch combined with op=", s.sid, F.accepted("*", `${BATCH} op=redefine`, REASON), s.repo);
  F.expectRejected("batch with an unknown value", s.sid, F.accepted("*", "batch=all", REASON), s.repo);
}

// term=* names no term, so without batch= it is refused rather than read as a literal term.
function starNeedsBatch(F) {
  const s = seeded(F, "batch-star", MIXED);
  F.expectRejected("term=* without batch=", s.sid, F.accepted("*", "", REASON), s.repo, /batch=/);
  F.expectRejected("term=* with only cat=", s.sid, F.accepted("*", "cat=user", REASON), s.repo, /batch=/);
}

// A second identical batch grant adds no grant: it is rejected as nothing pending, state unchanged.
function idempotent(F) {
  const s = seeded(F, "batch-twice", MIXED);
  F.mark(s.sid, F.accepted("*", BATCH, REASON), s.repo);
  const first = grantsOf(F, s.sid);
  F.check("batch twice: the first grant records the two definition-only redefines", first.length === 2, JSON.stringify(first));
  F.expectRejected("batch twice: the second identical grant", s.sid, F.accepted("*", BATCH, REASON), s.repo, /nothing pending/);
  const second = grantsOf(F, s.sid);
  F.check("batch twice: no duplicate grant after the second sentinel",
    JSON.stringify(second) === JSON.stringify(first), `${JSON.stringify(first)} -> ${JSON.stringify(second)}`);
}

function run(F) {
  covers(F);
  byCategory(F);
  none(F);
  refused(F);
}

function reply(F) {
  replyNames(F);
  singleReplyNames(F);
}

module.exports = { run, reply, starNeedsBatch, idempotent };
