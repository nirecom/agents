"use strict";
// `bin/pm-state owner --issue <ref>` (#2941, #2942): issue -> the PM that owns it, read from the
// Projects v2 PM field: the issue's own value, else its nearest ancestor's. The tag maps to its
// current generation with scan.generationOfTag (a retired or pending-rename tag included).
// Contract: {ok:true, owner:{tag, session_id}|null, fieldAbsent?, chain?} or {ok:false, reason}; the CLI prints the owner or
// {pm:null} and exits non-zero when undecidable. An ended PM is {pm:null}; a tag no local state holds
// is undecidable (tag-not-local). The local PM state lists no longer decide ownership.

const { readPmChains } = require("../pm-field/read");
const { refKey } = require("../forge-issue-links");

const DEFAULT_TIMEOUT_MS = 15000;

// A null owner also carries the chain refs (issue first) and, when a chain entry sits on a board without the
// pm field (#3135), fieldAbsent:true: the notification layer's gate (pm-notify/common.js) then refuses to
// trust that null.
function ownerOfChain(c, ctx) {
  if (!c || !c.ok) return { ok: false, reason: c ? c.reason : "parse_failed" };
  const hit = c.chain.find((n) => n.pm !== null);
  if (!hit) {
    const absent = c.chain.some((e) => e.fieldAbsent === true) ? { fieldAbsent: true } : {};
    return Object.assign({ ok: true, owner: null }, absent, { chain: c.chain.map(({ repo, number }) => ({ repo, number })) });
  }
  const g = ctx.scan.generationOfTag(hit.pm, ctx.entries);
  if (!g) return { ok: false, reason: `tag-not-local: ${hit.pm}` };
  if (g.pm.archived_at) return { ok: true, owner: null };
  return { ok: true, owner: { tag: g.pm.tag, session_id: g.session_id } };
}

// resolveOwners(refs, ctx) -> [resolveOwner's answer per ref, in input order], from one batched chain read.
function resolveOwners(refs, ctx) {
  const read = ctx.readPmChains || readPmChains;
  const timeoutMs = Number.isFinite(ctx.timeoutMs) ? ctx.timeoutMs : DEFAULT_TIMEOUT_MS;
  const r = read(refs, { deadlineAt: Date.now() + timeoutMs, spawnSync: ctx.spawnSync });
  if (!r.ok) return refs.map(() => ({ ok: false, reason: r.reason }));
  return refs.map((ref) => ownerOfChain(r.results[refKey(ref.repo, ref.number)], ctx));
}

// resolveOwner(ref, ctx) — ctx: {scan, entries, timeoutMs?, readPmChains?}; ref is repo-resolved.
const resolveOwner = (ref, ctx) => resolveOwners([ref], ctx)[0];

module.exports = { resolveOwner, resolveOwners };
