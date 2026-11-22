"use strict";
// The one implementation of a PM's range (#2941; the rule itself: the intent's Scope 4). An issue is
// in the range of a holder that lists it (direct) or that lists one of its ancestors carrying the
// meta label (viaMeta, every such ancestor up to the root, no nearest-wins). The ancestor chains
// come from deps.fetchAncestorChains in batches, memoized for one CLI call or one hook run. Every
// failure is fail-closed (ok:false), and its retryability is decided here only.

// The forge query nests MAX_ANCESTOR_DEPTH parents (GitHub allows 8 levels) and reads a deeper one as depth-cap.
const { MAX_ANCESTOR_DEPTH } = require("../forge-issue-links");
const MAX_FORGE_CALLS = 50;
// Network and auth failures only (#2942): a missing issue or a malformed answer does not heal on retry.
const RETRYABLE = new Set(["gh_exec_failed", "timeout"]);

const keyOf = (ref) => `${String(ref.repo).toLowerCase()}#${ref.number}`;
const hasRepo = (ref) => Boolean(ref) && typeof ref.repo === "string" && ref.repo.includes("/");
const fail = (reason) => ({ ok: false, reason, retryable: RETRYABLE.has(reason) });
const holds = (h, ref) => (Array.isArray(h.issues) ? h.issues : []).some((i) => i && hasRepo(i) && keyOf(i) === keyOf(ref));

// createAncestry({fetchAncestorChains(refs, {deadlineAt}), now?, deadlineAt?}) -> {prefetch, holdersOf, callCount}.
// A ref is {number, repo: "owner/repo"}; holders are [{tag, session_id, issues}] with repo-resolved issues.
function createAncestry(deps) {
  const memo = new Map();
  let calls = 0;

  // prefetch(refs) -> void: asks the forge once for every ref not memoized yet.
  function prefetch(refs) {
    const todo = new Map();
    for (const r of Array.isArray(refs) ? refs : []) {
      if (!hasRepo(r)) continue;
      const k = keyOf(r);
      if (!memo.has(k) && !todo.has(k)) todo.set(k, r);
    }
    if (todo.size === 0) return;
    if (calls >= MAX_FORGE_CALLS) {
      for (const k of todo.keys()) memo.set(k, fail("call-cap"));
      return;
    }
    calls++;
    let res;
    try { res = deps.fetchAncestorChains([...todo.values()], { deadlineAt: deps.deadlineAt }); } catch (_) { res = null; }
    for (const k of todo.keys()) {
      if (!res || !res.ok) memo.set(k, fail((res && res.reason) || "gh_exec_failed"));
      else memo.set(k, res.results && res.results[k] ? res.results[k] : fail("issue_not_found"));
    }
  }

  function chainOf(ref) {
    const k = keyOf(ref);
    if (!memo.has(k)) prefetch([ref]);
    return memo.get(k);
  }

  // holdersOf(ref, holders) -> {ok:true, direct:[holder], viaMeta:[{holder, ancestor}]} | {ok:false, reason, retryable}.
  function holdersOf(ref, holders) {
    if (!hasRepo(ref) || !Number.isInteger(Number(ref.number))) return fail("repo-unknown");
    const list = Array.isArray(holders) ? holders : [];
    const c = chainOf(ref);
    if (!c || !c.ok) return fail((c && c.reason) || "issue_not_found");
    const direct = list.filter((h) => holds(h, ref));
    const viaMeta = [];
    for (const step of c.chain) {
      const ancestor = { number: step.number, repo: step.repo };
      const held = list.filter((h) => holds(h, ancestor));
      if (held.length === 0) continue;
      if (step.meta === null) return Object.assign(fail("label-overflow"), { ancestor });
      if (step.meta === true) for (const holder of held) viaMeta.push({ holder, ancestor });
    }
    return { ok: true, direct, viaMeta };
  }

  return { prefetch, holdersOf, callCount: () => calls };
}

module.exports = { MAX_ANCESTOR_DEPTH, MAX_FORGE_CALLS, RETRYABLE, createAncestry };
