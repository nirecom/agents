"use strict";
// `bin/pm-notify check-header --tag <t> --pm-issues <#A,#B> [--closes <#C[,#D]>]` (#2942 S11, CP-1b): compares
// the whole pm-issues set of a received `role=pm` header with the assigned issue list of the tag's current
// generation (refs normalized with normalizeRef), and reports the owner of closes_issues.
// Prints RESULT=ok|mismatch|undecidable, EXTRA= (in the header, not assigned), MISSING= (assigned, not in the
// header), OWNER_TAG= (the owner of closes_issues; empty when none) and REASON= when not ok.
// An empty --pm-issues (no recorded header) skips the EXTRA/MISSING comparison.
// A tag retired by /pm-rename is refused: REASON=pm-tag-renamed NEW_TAG=<t>, exit 1.

const C = require("./common");
const W = require("../../../hooks/pm-session/writer-common");

function refsOf(list) {
  return String(list || "").split(",").map((s) => s.trim()).filter(Boolean).map(C.refOf);
}

function labelOf(ref) {
  const home = C.homeRepo();
  return home && home.toLowerCase() === ref.repo.toLowerCase() ? `#${ref.number}` : `${ref.repo}#${ref.number}`;
}

// ownersOf(refs, entries) -> {ok:true, tags:[tag]} | {ok:false, reason}.
function ownersOf(refs, entries) {
  const tags = [];
  for (const ref of refs) {
    const r = C.ownerOf(ref, C.OWNER_TIMEOUT_MS, entries);
    if (!r.ok) return { ok: false, reason: r.reason };
    if (r.owner && !tags.some((t) => C.S.sameTag(t, r.owner.tag))) tags.push(r.owner.tag);
  }
  return { ok: true, tags };
}

function checkHeader(argv) {
  const o = C.parseFlags(argv, ["tag", "pm-issues", "closes"]);
  if (!o.tag || o["pm-issues"] === undefined) C.fail(2, "usage: check-header --tag <t> --pm-issues <#A,#B> [--closes <#C>]", ["REASON=usage"]);
  const entries = C.scan.listPmFiles();
  C.refuseRenamed(o.tag, entries);
  const header = refsOf(o["pm-issues"]);
  const closes = refsOf(o.closes);
  const g = C.scan.generationOfTag(o.tag, entries);
  if (!g) return ["RESULT=undecidable", `REASON=tag-not-local: ${o.tag}`];
  const assigned = (Array.isArray(g.pm.issues) ? g.pm.issues : []).map((i) => W.normalizeStoredRef(i, C.homeRepo())).filter((r) => r.repo);
  const has = (list, ref) => list.some((x) => C.keyOf(x) === C.keyOf(ref));
  // An empty --pm-issues means no header was recorded: only the owner of closes_issues is judged.
  const noHeader = header.length === 0;
  const extra = noHeader ? [] : header.filter((r) => !has(assigned, r)).map(labelOf);
  const missing = noHeader ? [] : assigned.filter((r) => !has(header, r)).map(labelOf);
  const own = ownersOf(closes, entries);
  const ownerTag = own.ok ? own.tags.join(",") : "";
  const tail = [`EXTRA=${extra.join(",")}`, `MISSING=${missing.join(",")}`, `OWNER_TAG=${ownerTag}`];
  if (!own.ok) return ["RESULT=undecidable", `REASON=${own.reason}`].concat(tail);
  if (g.pm.archived_at) return ["RESULT=mismatch", "REASON=pm-ended"].concat(tail);
  if (extra.length > 0 || missing.length > 0) return ["RESULT=mismatch", "REASON=pm-issues-differ"].concat(tail);
  if (own.tags.some((t) => !C.S.sameTag(t, g.pm.tag))) return ["RESULT=mismatch", "REASON=owner-differs"].concat(tail);
  return ["RESULT=ok"].concat(tail);
}

module.exports = { checkHeader };
