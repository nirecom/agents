"use strict";
// `bin/pm-state owner --issue <ref>` (#2941): issue -> the current generation of the active PM
// whose range holds it. Contract: {ok:true, owner:{tag, session_id}|null} or {ok:false, reason};
// the CLI prints the owner or {pm:null}, and exits non-zero when the range cannot be decided.
// A direct holder wins without a forge call. Among several candidates the one that was given the
// issue (or the hit meta) first wins; a tie goes to the code-point-first tag.

const atMs = (at) => {
  const t = Date.parse(at);
  return Number.isNaN(t) ? Infinity : t;
};

// earliest([{tag, session_id, assigned_at}]) -> the winner.
function earliest(cands) {
  return cands.slice().sort((a, b) => (atMs(a.assigned_at) - atMs(b.assigned_at)) || (a.tag < b.tag ? -1 : a.tag > b.tag ? 1 : 0))[0];
}

const pick = (c) => ({ tag: c.tag, session_id: c.session_id });

// resolveOwner(ref, ctx) — ctx: {scan, entries, homeRepo, ancestry}; ref is repo-resolved.
function resolveOwner(ref, ctx) {
  const direct = ctx.scan.directHoldersOf(ref, { homeRepo: ctx.homeRepo, entries: ctx.entries });
  if (direct.length > 0) return { ok: true, owner: pick(earliest(direct)) };
  const active = ctx.scan.listActivePms(ctx.entries);
  if (active.length === 0) return { ok: true, owner: null };
  const holders = active.map((p) => ({ tag: p.tag, session_id: p.session_id, pm: p.pm, issues: p.issues.map(ctx.resolve).filter(Boolean) }));
  const r = ctx.ancestry.holdersOf(ref, holders);
  if (!r.ok) return { ok: false, reason: r.reason };
  if (r.viaMeta.length === 0) return { ok: true, owner: null };
  const cands = r.viaMeta.map((v) => ({ tag: v.holder.tag, session_id: v.holder.session_id, assigned_at: ctx.scan.assignedAt(v.holder.pm, v.ancestor, ctx.homeRepo) }));
  return { ok: true, owner: pick(earliest(cands)) };
}

module.exports = { resolveOwner };
