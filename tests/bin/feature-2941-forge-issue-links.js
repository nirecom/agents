"use strict";
// tests/bin/feature-2941-forge-issue-links.js
// Tests: bin/lib/forge-issue-links.js
// Tags: TL1, scope:issue-specific, pm-session, forge, gh, issue-3135
// #2941 fetchAncestorChains(refs, {deadlineAt, timeoutMs}) batches refs (50 per gh call, aliases per
// owner/repo), shares one deadline across the chunks and tells whole-call failures apart; per-ref
// chains are read through ancestry (feature-2941-pm-state-ancestry.js). resolveOwnerRepoFromOrigin /
// parseOwnerRepoFromApiUrl keep their contract.
// TL3 gap: the real GitHub GraphQL `parent` / `labels` fields are not queried; a fake gh answers their shape.

const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");
const assert = require("node:assert");
const { test, after } = require("node:test");
const cp = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const P = require("../lib/pm-state-fixture");
const { ghEnv } = require("./feature-2941-pm-state-cli/gh-env");

const restore = isolate();
const G = ghEnv("forge-links-");
const cwd0 = process.cwd();
const repo = path.join(G.tmp, "repo");
fs.mkdirSync(repo);
gitInit(repo);
cp.spawnSync("git", ["-C", repo, "remote", "add", "origin", "https://github.com/o/r.git"], { timeout: 30000 });
after(() => { process.chdir(cwd0); G.restore(); restore(); });

const L = () => P.load("bin/lib/forge-issue-links.js");
const refs = (n, base, r) => Array.from({ length: n }, (_, i) => ({ number: base + i, repo: r || "o/r" }));
function fetch(rs, opts) {
  const f = L().fetchAncestorChains;
  assert.strictEqual(typeof f, "function", "fetchAncestorChains is missing");
  const before = G.calls();
  const t0 = Date.now();
  const r = f(rs, opts || {});
  return { r, calls: G.calls() - before, ms: Date.now() - t0, queries: G.queries().slice(before) };
}
const wholeFail = (r, reason) => {
  assert.strictEqual(r.ok, false, JSON.stringify(r).slice(0, 400));
  assert.strictEqual(r.reason, reason, JSON.stringify(r).slice(0, 400));
};

caseBegin("fetch-ancestor-chains-batching", "bin/lib/forge-issue-links.js");
test("META_LABEL is meta", () => {
  assert.strictEqual(L().META_LABEL, "meta");
});
test("50 refs are one gh call, 51 are two", () => {
  assert.strictEqual(fetch(refs(50, 3000)).calls, 1);
  assert.strictEqual(fetch(refs(51, 3100)).calls, 2);
});
test("refs of two repos share one call, each repo aliased", () => {
  const f = fetch(refs(2, 3300).concat(refs(2, 3300, "x/y")));
  assert.strictEqual(f.calls, 1);
  assert.match(f.queries[0], /owner\s*:\s*"o"/);
  assert.match(f.queries[0], /owner\s*:\s*"x"/);
});
test("only a validated owner/repo and integer numbers reach the query", () => {
  const f = fetch([{ number: 3400, repo: "o/r" }, { number: 3401, repo: 'ev"il/r){x}' }, { number: "3402) { y }", repo: "o/r" }]);
  for (const q of f.queries) {
    assert.ok(!q.includes("ev\"il") && !q.includes("{x}") && !q.includes("{ y }"), q);
  }
});
caseEnd();

caseBegin("fetch-ancestor-chains-whole-failures-and-deadline", "bin/lib/forge-issue-links.js");
test("a gh failure is gh_exec_failed and a non-JSON body parse_failed, never 'no parent'", () => {
  try {
    G.mode("fail");
    wholeFail(fetch(refs(1, 3500)).r, "gh_exec_failed");
    G.mode("garbage");
    wholeFail(fetch(refs(1, 3500)).r, "parse_failed");
  } finally { G.mode(null); }
});
test("a deadline already passed calls no gh and the whole result is timeout", () => {
  const f = fetch(refs(3, 3600), { deadlineAt: Date.now() - 1 });
  assert.strictEqual(f.calls, 0);
  wholeFail(f.r, "timeout");
});
test("51 refs: the first chunk uses up the shared deadline, the second gh is never called", () => {
  const budget = 1500;
  try {
    G.sleep(budget + 1500);
    const f = fetch(refs(51, 3700), { deadlineAt: Date.now() + budget });
    assert.strictEqual(f.calls, 1, "the second chunk was queried after the deadline");
    wholeFail(f.r, "timeout");
    assert.ok(f.ms < budget + 2500, `took ${f.ms} ms for a ${budget} ms deadline`);
  } finally { G.sleep(null); }
});
caseEnd();

caseBegin("forge-issue-links-moved-helpers", "bin/lib/forge-issue-links.js");
test("parseOwnerRepoFromApiUrl keeps its contract", () => {
  const f = L().parseOwnerRepoFromApiUrl;
  assert.strictEqual(f("https://api.github.com/repos/o/r"), "o/r");
  assert.strictEqual(f("https://api.github.com/repos/o/r/"), "o/r");
  assert.strictEqual(f("https://example.com/repos/o/r"), null);
  assert.strictEqual(f(42), null);
});
test("resolveOwnerRepoFromOrigin reads the origin of the cwd", () => {
  process.chdir(repo);
  try {
    assert.deepStrictEqual(L().resolveOwnerRepoFromOrigin(), { ok: true, ownerRepo: "o/r" });
  } finally {
    process.chdir(cwd0);
  }
});
test("meta-classify.js still loads after the move", () => {
  assert.strictEqual(typeof require(path.join(P.ROOT, "bin/workflow/lib/workflow-init/phases/meta-classify.js")).metaClassify, "function");
});
caseEnd();

// #2942: an errors[] entry whose path lies strictly inside a slot's node fails that slot (gh_exec_failed) even
// when the node is an object — the node is partial, so readNode never sees it. Other slots read normally.
caseBegin("classify-graphql-error-inside-node", "bin/lib/forge-issue-links.js");
const SLOTS = [{ key: "a", path: ["r0", "i0"] }, { key: "b", path: ["r0", "i1"] }];
const issue = (n) => ({ number: n, parent: null });
const gh = (data, errors, status = 1) => ({ status, stdout: JSON.stringify(errors ? { data, errors } : { data }) });
function classify(r) {
  const seen = [];
  const c = L().classifyGraphqlResult(r, SLOTS, (node, key) => { seen.push(key); return { ok: true, n: node.number }; });
  assert.strictEqual(c.ok, true, JSON.stringify(c));
  return { res: c.results, seen };
}
const both = { r0: { i0: issue(1), i1: issue(2) } };
test("E1 a non-NOT_FOUND error inside an object node -> gh_exec_failed, readNode not called", () => {
  const { res, seen } = classify(gh(both, [{ type: "FORBIDDEN", path: ["r0", "i0", "projectItems", "nodes", 0, "project"] }]));
  assert.deepStrictEqual(res.a, { ok: false, reason: "gh_exec_failed" });
  assert.ok(!seen.includes("a"), `readNode read the partial node: ${seen}`);
});
test("E2 a NOT_FOUND inside an object node is gh_exec_failed, not issue_not_found", () => {
  const { res, seen } = classify(gh(both, [{ type: "NOT_FOUND", path: ["r0", "i0", "parent"] }]));
  assert.deepStrictEqual(res.a, { ok: false, reason: "gh_exec_failed" });
  assert.ok(!seen.includes("a"), `readNode read the partial node: ${seen}`);
});
test("E3 an error inside i0 only leaves i1 read normally", () => {
  const { res, seen } = classify(gh(both, [{ type: "FORBIDDEN", path: ["r0", "i0", "parent"] }]));
  assert.deepStrictEqual(res.b, { ok: true, n: 2 });
  assert.deepStrictEqual(seen, ["b"]);
});
test("E4 errors under another alias, a sibling slot or with no path do not touch an object node", () => {
  for (const e of [{ type: "FORBIDDEN", path: ["r1", "i0", "parent"] }, { type: "FORBIDDEN", path: ["r0", "i1", "parent"] }, { type: "FORBIDDEN", path: ["r0", "i10", "parent"] }, { type: "FORBIDDEN" }]) {
    const { res } = classify(gh(both, [e]));
    assert.deepStrictEqual(res.a, { ok: true, n: 1 }, JSON.stringify(e));
  }
});
test("E5 regression: a null node with NOT_FOUND is issue_not_found; with another type gh_exec_failed", () => {
  const nf = classify(gh({ r0: { i0: null, i1: issue(2) } }, [{ type: "NOT_FOUND", path: ["r0", "i0"] }]));
  assert.deepStrictEqual(nf.res.a, { ok: false, reason: "issue_not_found" });
  assert.deepStrictEqual(nf.res.b, { ok: true, n: 2 });
  const other = classify(gh({ r0: { i0: null, i1: issue(2) } }, [{ type: "FORBIDDEN", path: ["r0", "i0"] }]));
  assert.deepStrictEqual(other.res.a, { ok: false, reason: "gh_exec_failed" });
});
caseEnd();

// #3135: the caller may pass a predicate (4th argument of classifyGraphqlResult, spec.tolerate of
// batchedGraphql) naming the in-node errors it accepts; the classifier itself holds no pm knowledge.
caseBegin("classify-graphql-tolerated-inside-error", "bin/lib/forge-issue-links.js");
const FIELD_PATH = ["r0", "i0", "projectItems", "nodes", 0, "project", "field"];
const pmFieldAbsent = (e) => e.type === "NOT_FOUND" && Array.isArray(e.path) && e.path.slice(-2).join(".") === "project.field";
function classifyWith(r, tolerate) {
  const seen = [];
  const c = L().classifyGraphqlResult(r, SLOTS, (node, key) => { seen.push(key); return { ok: true, n: node.number }; }, tolerate);
  assert.strictEqual(c.ok, true, JSON.stringify(c));
  return { res: c.results, seen };
}
test("P1 a tolerated NOT_FOUND at the card's project.field leaves the node readable", () => {
  const { res, seen } = classifyWith(gh(both, [{ type: "NOT_FOUND", path: FIELD_PATH }]), pmFieldAbsent);
  assert.deepStrictEqual(res.a, { ok: true, n: 1 });
  assert.deepStrictEqual(seen.sort(), ["a", "b"]);
});
test("P2 the predicate gets the error object; one it refuses stays gh_exec_failed", () => {
  const got = [];
  const { res } = classifyWith(gh(both, [{ type: "NOT_FOUND", path: FIELD_PATH }]), (e) => { got.push(e); return false; });
  assert.deepStrictEqual(res.a, { ok: false, reason: "gh_exec_failed" });
  assert.ok(got.some((e) => e && e.type === "NOT_FOUND" && Array.isArray(e.path)), `the predicate never saw the error: ${JSON.stringify(got)}`);
});
test("P3 non-regression: without a predicate a project.field NOT_FOUND is still gh_exec_failed", () => {
  const { res, seen } = classifyWith(gh(both, [{ type: "NOT_FOUND", path: FIELD_PATH }]));
  assert.deepStrictEqual(res.a, { ok: false, reason: "gh_exec_failed" });
  assert.ok(!seen.includes("a"));
});
test("P4 non-regression: other errors the predicate does not name keep the node failed", () => {
  for (const e of [{ type: "FORBIDDEN", path: FIELD_PATH }, { type: "NOT_FOUND", path: ["r0", "i0", "parent"] },
    { type: "NOT_FOUND", path: ["r0", "i0", "projectItems", "nodes", 0, "project"] }]) {
    const { res, seen } = classifyWith(gh(both, [e]), pmFieldAbsent);
    assert.deepStrictEqual(res.a, { ok: false, reason: "gh_exec_failed" }, JSON.stringify(e));
    assert.ok(!seen.includes("a"), JSON.stringify(e));
  }
});
test("P5 partial node: a tolerated error next to an untolerated one in the same node still fails it", () => {
  const { res, seen } = classifyWith(gh(both, [{ type: "NOT_FOUND", path: FIELD_PATH }, { type: "FORBIDDEN", path: ["r0", "i0", "parent"] }]), pmFieldAbsent);
  assert.deepStrictEqual(res.a, { ok: false, reason: "gh_exec_failed" });
  assert.ok(!seen.includes("a"));
  assert.deepStrictEqual(res.b, { ok: true, n: 2 });
});
test("P6 non-regression: a predicate does not touch a null node (NOT_FOUND -> issue_not_found, other -> gh_exec_failed)", () => {
  const nf = classifyWith(gh({ r0: { i0: null, i1: issue(2) } }, [{ type: "NOT_FOUND", path: ["r0", "i0"] }]), () => true);
  assert.deepStrictEqual(nf.res.a, { ok: false, reason: "issue_not_found" });
  const other = classifyWith(gh({ r0: { i0: null, i1: issue(2) } }, [{ type: "FORBIDDEN", path: ["r0", "i0"] }]), () => true);
  assert.deepStrictEqual(other.res.a, { ok: false, reason: "gh_exec_failed" });
});
test("P7 batchedGraphql passes spec.tolerate to the classifier (fake gh answering a board without pm)", () => {
  G.setMap({ "o/r#3801": { noPmFieldBoard: true } });
  try {
    const fields = 'number projectItems(first:20){nodes{id project{id field(name:"pm"){... on ProjectV2FieldCommon{id}}}} pageInfo{hasNextPage}}';
    const spec = (tolerate) => ({ fields, readNode: (node) => ({ ok: true, n: node.number }), tolerate });
    const plain = L().batchedGraphql([{ number: 3801, repo: "o/r" }], spec(undefined));
    assert.deepStrictEqual(plain.results["o/r#3801"], { ok: false, reason: "gh_exec_failed" }, JSON.stringify(plain));
    const tol = L().batchedGraphql([{ number: 3801, repo: "o/r" }], spec(pmFieldAbsent));
    assert.deepStrictEqual(tol.results["o/r#3801"], { ok: true, n: 3801 }, JSON.stringify(tol));
  } finally { G.setMap({}); }
});
caseEnd();
