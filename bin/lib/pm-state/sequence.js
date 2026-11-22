"use strict";
// The sequence table of a PM (#2941): its shape, its range check and its one write path. Shared by
// `bin/pm-state set-sequence` (--file / --revalidate) and the `--from` inherit of the hook writer.
// Payload: {tables: [{title, meta?, waves: [{issues: [{number, repo?, reason, blocked_by, conflicts}]}]}]}.
// The range rule is ancestry.holdersOf against the owning PM only; other PMs are not looked at.

const path = require("path");
const S = require(path.join(__dirname, "..", "..", "..", "hooks", "pm-session", "schema"));
const W = require(path.join(__dirname, "..", "..", "..", "hooks", "pm-session", "writer-common"));

const RETRY = "check `gh auth status` and run set-sequence again";

class SeqRefusal extends Error {}
const refuse = (msg) => { throw new SeqRefusal(msg); };

const missing = (at, field) => refuse(`${at} is missing ${field} (reason is a non-empty string; blocked_by and conflicts are arrays and may be empty)`);

// checkRef(ref, at) — an issue reference {number, repo?}: a table issue and each blocked_by / conflicts element.
function checkRef(ref, at) {
  if (!ref || typeof ref !== "object" || !Number.isInteger(ref.number) || ref.number <= 0) refuse(`${at} needs a positive integer number`);
  if (ref.repo !== undefined && (typeof ref.repo !== "string" || !ref.repo)) refuse(`${at}.repo must be a non-empty string`);
}

// validatePayload(obj) -> the tables array; throws SeqRefusal on a malformed shape or a missing field.
function validatePayload(obj) {
  if (!obj || typeof obj !== "object" || !Array.isArray(obj.tables)) refuse("the file must hold {tables: [...]}");
  obj.tables.forEach((t, ti) => {
    if (!t || typeof t !== "object" || !Array.isArray(t.waves)) refuse(`tables[${ti}] needs a waves array`);
    t.waves.forEach((w, wi) => {
      if (!w || typeof w !== "object" || !Array.isArray(w.issues)) refuse(`tables[${ti}].waves[${wi}] needs an issues array`);
      w.issues.forEach((i, ii) => {
        const at = `tables[${ti}].waves[${wi}].issues[${ii}]`;
        checkRef(i, at);
        if (typeof i.reason !== "string" || i.reason.trim() === "") missing(at, "reason");
        for (const field of ["blocked_by", "conflicts"]) {
          if (!Array.isArray(i[field])) missing(at, field);
          i[field].forEach((ref, ri) => checkRef(ref, `${at}.${field}[${ri}]`));
        }
      });
    });
  });
  return obj.tables;
}

function issuesOf(tables) {
  const out = [];
  for (const t of tables) for (const w of t.waves) for (const i of w.issues) out.push(i.repo ? { number: i.number, repo: i.repo } : { number: i.number });
  return out;
}

// resolved(ref, homeRepo) -> the normalized ref (writer-common.normalizeRef, #2942), or null when its
// repo cannot be resolved (checkSequence reports it as unresolvable instead of throwing).
const resolved = (ref, homeRepo) => {
  const r = W.normalizeStoredRef(ref, homeRepo);
  return typeof r.repo === "string" && r.repo.includes("/") ? r : null;
};

// checkSequence(tables, owner, ctx) -> {ok:true}
//   | {ok:false, kind:"structure"|"out-of-range"|"unresolvable"|"unverified", issues:[ref], reason, ancestor?}.
// owner: {tag, session_id?, issues}; ctx: {ancestry, homeRepo}. Never throws on a bad table; every
// issue is looked at before deciding. Priority: structure (a duplicate issue refuses before any forge
// call), then out-of-range, then unresolvable, then unverified.
function checkSequence(tables, owner, ctx) {
  try { validatePayload({ tables }); } catch (e) {
    if (e instanceof SeqRefusal) return { ok: false, kind: "structure", issues: [], reason: e.message };
    throw e;
  }
  const holder = {
    tag: owner.tag,
    session_id: owner.session_id || null,
    issues: (Array.isArray(owner.issues) ? owner.issues : []).map((i) => resolved(i, ctx.homeRepo)).filter(Boolean),
  };
  const seen = new Set();
  const refs = [];
  const unknown = [];
  const dupKeys = new Set();
  const dups = [];
  for (const raw of issuesOf(tables)) {
    const ref = resolved(raw, ctx.homeRepo);
    if (!ref) { unknown.push(raw); continue; }
    const key = `${ref.repo.toLowerCase()}#${ref.number}`;
    if (!seen.has(key)) { seen.add(key); refs.push(ref); }
    else if (!dupKeys.has(key)) { dupKeys.add(key); dups.push(ref); }
  }
  if (dups.length > 0) {
    return { ok: false, kind: "structure", issues: dups, reason: `duplicate issue in the sequence: ${dups.map(S.refLabel).join(" ")}` };
  }
  ctx.ancestry.prefetch(refs);
  const out = [];
  const bad = unknown.map((ref) => ({ ref, reason: "repo-unknown", ancestor: null }));
  const retry = [];
  for (const ref of refs) {
    const r = ctx.ancestry.holdersOf(ref, [holder]);
    if (!r.ok) (r.retryable ? retry : bad).push({ ref, reason: r.reason, ancestor: r.ancestor || null });
    else if (r.direct.length === 0 && r.viaMeta.length === 0) out.push(ref);
  }
  if (out.length > 0) return { ok: false, kind: "out-of-range", issues: out, reason: "out-of-range" };
  const reasons = (list) => [...new Set(list.map((b) => b.reason))].join(",");
  if (bad.length > 0) {
    const lo = bad.find((b) => b.reason === "label-overflow");
    return { ok: false, kind: "unresolvable", issues: bad.map((b) => b.ref), reason: reasons(bad), ancestor: lo ? lo.ancestor : null };
  }
  if (retry.length > 0) return { ok: false, kind: "unverified", issues: retry.map((b) => b.ref), reason: retry[0].reason };
  return { ok: true };
}

const sameIssueSet = (a, b, S, homeRepo) =>
  a.every((x) => b.some((y) => S.sameIssue(x, y, homeRepo))) && b.every((y) => a.some((x) => S.sameIssue(x, y, homeRepo)));

// writeSequence(sid, tables, ctx) — ctx: {io, S, now, checkedIssues, homeRepo}. Re-checks inside the
// lock that the PM is still active and its assignment (pm.issues, order-insensitive) is still the
// checkedIssues the range check used; a write that passed the check always clears the unverified mark.
function writeSequence(sid, tables, ctx) {
  const checked = Array.isArray(ctx.checkedIssues) ? ctx.checkedIssues : [];
  ctx.io.updateTopLevel(sid, (rec) => {
    if (!ctx.S.isActivePm(rec)) refuse("the PM changed while set-sequence ran; retry");
    const current = Array.isArray(rec.pm.issues) ? rec.pm.issues : [];
    if (!sameIssueSet(current, checked, ctx.S, ctx.homeRepo)) refuse("the assignment changed while set-sequence ran; retry");
    rec.pm = Object.assign({}, rec.pm, { sequence: { updated_at: ctx.now, tables, unverified: null } });
  });
}

// removeFromSequence(sequence, refs, {homeRepo?, at?}) -> {tables, unverified} (#2942 PMR-3): the rows of
// refs dropped (an emptied wave is dropped too); a remaining row whose blocked_by names a removed issue sets
// unverified {reason:"removed", at}. Idempotent; the caller writes it in the /pm-remove state write.
function removeFromSequence(seq, refs, opts) {
  const o = opts || {};
  const gone = (r) => (refs || []).some((x) => S.sameIssue(x, r, o.homeRepo));
  const tables = Array.isArray(seq && seq.tables) ? seq.tables : [];
  let orphaned = false;
  const next = tables.map((t) => {
    const waves = (Array.isArray(t.waves) ? t.waves : []).map((w) => {
      const issues = (Array.isArray(w.issues) ? w.issues : []).filter((i) => !gone(i));
      if (issues.some((i) => (Array.isArray(i.blocked_by) ? i.blocked_by : []).some(gone))) orphaned = true;
      return Object.assign({}, w, { issues });
    }).filter((w) => w.issues.length > 0);
    return Object.assign({}, t, { waves });
  });
  const unverified = orphaned ? { reason: "removed", at: o.at || new Date().toISOString() } : (seq && seq.unverified) || null;
  return Object.assign({}, seq, { tables: next, unverified });
}

module.exports = { RETRY, SeqRefusal, validatePayload, issuesOf, checkSequence, writeSequence, removeFromSequence };
