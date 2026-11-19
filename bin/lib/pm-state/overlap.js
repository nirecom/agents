"use strict";
// The range-overlap check of /pm-init and /pm-add (#2941): the only place that builds the reason an
// assignment is refused. Upward: an issue being added is in another PM's range (direct or via a held
// meta ancestor). Downward: an issue another PM holds is under a meta issue being added. Descendants
// are never enumerated: a held issue x settles both (a meta x has its descendants under it, a plain
// x leaves them in nobody's range). Ranges come from ancestry.holdersOf only.

// findOverlap(adds, myTag, others, ancestry) -> {ok:true}
//   | {ok:false, kind:"overlap", ref, tag, session_id, direction:"up"|"down", via, held?}
//   | {ok:false, kind:"unresolvable"|"unverified", ref, reason}.
// others: [{tag, session_id, issues}] (the other active PMs, current generation); refs repo-resolved.
// Priority: any overlap, else any non-retryable failure, else any retryable one.
function findOverlap(adds, myTag, others, ancestry) {
  const mine = Array.isArray(adds) ? adds : [];
  const rest = Array.isArray(others) ? others : [];
  ancestry.prefetch(mine.concat(...rest.map((o) => (Array.isArray(o.issues) ? o.issues : []))));
  let unresolvable = null;
  let unverified = null;
  const noteFail = (ref, r) => {
    if (!r.retryable && !unresolvable) unresolvable = { ok: false, kind: "unresolvable", ref, reason: r.reason, ancestor: r.ancestor || null };
    if (r.retryable && !unverified) unverified = { ok: false, kind: "unverified", ref, reason: r.reason };
  };
  for (const a of mine) {
    const r = ancestry.holdersOf(a, rest);
    if (!r.ok) { noteFail(a, r); continue; }
    if (r.direct.length > 0) {
      const h = r.direct[0];
      return { ok: false, kind: "overlap", ref: a, tag: h.tag, session_id: h.session_id, direction: "up", via: a };
    }
    if (r.viaMeta.length > 0) {
      const v = r.viaMeta[0];
      return { ok: false, kind: "overlap", ref: a, tag: v.holder.tag, session_id: v.holder.session_id, direction: "up", via: v.ancestor };
    }
  }
  const me = [{ tag: myTag, session_id: null, issues: mine }];
  for (const o of rest) {
    for (const x of Array.isArray(o.issues) ? o.issues : []) {
      const r = ancestry.holdersOf(x, me);
      if (!r.ok) { noteFail(x, r); continue; }
      if (r.viaMeta.length > 0) {
        const v = r.viaMeta[0];
        return { ok: false, kind: "overlap", ref: v.ancestor, tag: o.tag, session_id: o.session_id, direction: "down", via: v.ancestor, held: x };
      }
    }
  }
  return unresolvable || unverified || { ok: true };
}

const label = (ref) => (ref && typeof ref === "object" ? `${ref.repo ? ref.repo : ""}#${ref.number}` : String(ref));

// unresolvableExit(reason, ancestor?) -> the way out of a range that cannot be checked (shared with set-sequence).
function unresolvableExit(reason, ancestor) {
  if (reason === "label-overflow") {
    const who = ancestor ? ` ${label(ancestor)}` : "";
    return `reduce the labels of ancestor${who} to 100 or fewer and retry, or drop that issue and retry (until its labels are 100 or fewer, that issue cannot be used for the scope check)`;
  }
  return "drop that issue and retry";
}

// refusalText(r) -> the user-facing sentence for a findOverlap failure.
function refusalText(r) {
  if (r.kind === "overlap") {
    const dir = r.direction === "down" ? "down" : "up";
    return `${label(r.ref)} overlaps the scope of ${r.tag} (session ${r.session_id}) (${dir}: ${label(r.via)}). Run \`/pm-remove\` in that PM, then retry`;
  }
  if (r.kind === "unresolvable") {
    return `cannot verify the scope of ${label(r.ref)} (${r.reason}); retrying will not fix it. ${unresolvableExit(r.reason, r.ancestor)}`;
  }
  return `could not verify the overlap on the forge (${r.reason}). Retry, or while the forge is unavailable start with \`/pm-init\` without issues`;
}

module.exports = { findOverlap, refusalText, unresolvableExit, refLabelOf: label };
