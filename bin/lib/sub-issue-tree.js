"use strict";
// The sub-issue trees of issues with their PM field values (#2942), for the one-owner check of
// /pm-init and /pm-add: an issue whose descendant names another PM cannot be taken.
//   fetchSubIssueTree(refs, {deadlineAt?, timeoutMs?, maxCalls?}) -> {ok:true, results: {[refKey]:
//     {ok:true, descendants:[{repo, number, pm, state}]} | {ok:false, reason}}} | whole-call {ok:false, reason}
// Each call reads SUB_DEPTH levels; a node cut off below that (totalCount > 0, no nodes) is read again in
// the next call, up to maxCalls. A truncated page or a remaining frontier is {ok:false} (fail-closed);
// a descendant's failed PM read (pm-field-ambiguous, pm-field-truncated) fails its root the same way.
//   readChainsAndTrees(refs, opts) -> {ok:true, chains, trees, cards}: the one-owner check's whole read in one call.

const { batchedGraphql, refKey } = require("./forge-issue-links");
const { pmReadOf, itemsOf, pmFieldAbsentError, chainFields, chainOf, cardOf } = require("./pm-field/read");

const SUB_DEPTH = 3;
const SUB_PAGE = 20;
const DEFAULT_MAX_CALLS = 4;
const ITEMS = itemsOf(10);

function subFields(depth) {
  const own = `number state repository{nameWithOwner} ${ITEMS}`;
  const below = depth < SUB_DEPTH ? `subIssues(first:${SUB_PAGE}){nodes{${subFields(depth + 1)}} pageInfo{hasNextPage} totalCount}` : "subIssues{totalCount}";
  return `${own} ${below}`;
}

// walk(node, out, frontier, seen) -> null | reason; collects every descendant of node.
function walk(node, out, frontier, seen) {
  const subs = node.subIssues;
  if (!subs) return null;
  const nodes = Array.isArray(subs.nodes) ? subs.nodes : null;
  if (!nodes) {
    if (Number(subs.totalCount) > 0) frontier.push(node);
    return null;
  }
  if (subs.pageInfo && subs.pageInfo.hasNextPage) return "sub-issue-overflow";
  for (const c of nodes) {
    if (!c || !Number.isInteger(c.number)) return "parse_failed";
    const repo = c.repository && typeof c.repository.nameWithOwner === "string" ? c.repository.nameWithOwner : null;
    if (!repo) return "parse_failed";
    const k = refKey(repo, c.number);
    if (seen.has(k)) continue;
    seen.add(k);
    const p = pmReadOf(c);
    if (!p.ok) return p.reason;
    out.push({ repo, number: c.number, pm: p.pm, state: c.state || null });
    const r = walk(Object.assign({ repository: { nameWithOwner: repo } }, c), out, frontier, seen);
    if (r) return r;
  }
  return null;
}

const treeCall = (refs, o) => batchedGraphql(refs, { fields: subFields(0), readNode: (node) => ({ ok: true, node }), tolerate: pmFieldAbsentError }, o);

// treesOf(refs, o, firstCall?) -> fetchSubIssueTree's answer; firstCall(refs) stands in for the first call (the composite read).
function treesOf(refs, o, firstCall) {
  const maxCalls = Number.isInteger(o.maxCalls) && o.maxCalls > 0 ? o.maxCalls : DEFAULT_MAX_CALLS;
  const results = {};
  const state = new Map();
  let pending = [];
  for (const ref of Array.isArray(refs) ? refs : []) {
    const key = refKey(ref && ref.repo, ref && ref.number);
    if (state.has(key)) continue;
    const st = { out: [], seen: new Set([key]), failed: null };
    state.set(key, st);
    pending.push({ ref: { repo: ref.repo, number: ref.number }, owner: key });
  }
  for (let call = 0; pending.length > 0; call++) {
    if (call >= maxCalls) {
      for (const p of pending) state.get(p.owner).failed = state.get(p.owner).failed || "sub-issue-depth-cap";
      break;
    }
    const asked = pending.map((p) => p.ref);
    const r = call === 0 && firstCall ? firstCall(asked) : treeCall(asked, o);
    if (!r.ok) return r;
    const next = [];
    for (const p of pending) {
      const st = state.get(p.owner);
      const got = r.results[refKey(p.ref.repo, p.ref.number)];
      if (st.failed) continue;
      if (!got || !got.ok) { st.failed = (got && got.reason) || "parse_failed"; continue; }
      const frontier = [];
      const why = walk(got.node, st.out, frontier, st.seen);
      if (why) { st.failed = why; continue; }
      for (const f of frontier) next.push({ ref: { repo: f.repository.nameWithOwner, number: f.number }, owner: p.owner });
    }
    pending = next;
  }
  for (const [key, st] of state) results[key] = st.failed ? { ok: false, reason: st.failed } : { ok: true, descendants: st.out };
  return { ok: true, results };
}

const fetchSubIssueTree = (refs, opts) => treesOf(refs, opts || {});

// nodeCountOf(fields) -> GitHub's node count of one root selecting fields: each first:N connection counts N times
// the first: values around it.
function nodeCountOf(fields) {
  const stack = [1];
  let total = 0;
  let pend = 1;
  for (let i = 0; i < fields.length; i++) {
    const c = fields[i];
    if (c === "(") {
      const j = fields.indexOf(")", i);
      const m = /\bfirst:\s*(\d+)/.exec(fields.slice(i, j));
      pend = m ? Number(m[1]) : 1;
      i = j;
    } else if (c === "{") {
      const mult = stack[stack.length - 1] * pend;
      if (pend > 1) total += mult;
      stack.push(mult);
      pend = 1;
    } else if (c === "}") stack.pop();
    else if (/\w/.test(c)) pend = 1;
  }
  return total;
}

const NODE_LIMIT = 500000;
const COMPOSITE_FIELDS = `${chainFields(0)} state subIssues(first:${SUB_PAGE}){nodes{${subFields(1)}} pageInfo{hasNextPage} totalCount}`;
const COMPOSITE_CHUNK = Math.max(1, Math.floor(NODE_LIMIT / Math.max(1, nodeCountOf(COMPOSITE_FIELDS))));

// readChainsAndTrees(refs, {deadlineAt?, timeoutMs?, minCallMs?, spawnSync?, maxCalls?}) -> {ok:true, chains, trees,
// cards} (#3152): readPmChains', fetchSubIssueTree's and readCards' results from one call per COMPOSITE_CHUNK roots,
// plus fetchSubIssueTree's frontier calls; a whole-call failure is {ok:false, reason}.
function readChainsAndTrees(refs, opts) {
  const o = Object.assign({}, opts || {}, { chunkSize: COMPOSITE_CHUNK });
  const chains = {};
  const cards = {};
  const readNode = (node, key) => {
    chains[key] = chainOf(node, key);
    cards[key] = cardOf(node);
    return { ok: true, node };
  };
  const first = (asked) => {
    const r = batchedGraphql(asked, { fields: COMPOSITE_FIELDS, readNode, tolerate: pmFieldAbsentError }, o);
    if (!r.ok) return r;
    for (const [key, v] of Object.entries(r.results)) {
      if (!v.ok) { chains[key] = v; cards[key] = v; }
    }
    return r;
  };
  const t = treesOf(refs, o, first);
  if (!t.ok) return t;
  return { ok: true, chains, trees: t.results, cards };
}

module.exports = { fetchSubIssueTree, readChainsAndTrees, COMPOSITE_CHUNK };
