"use strict";
// Issue links read from the forge (#2087, #2941): the repo identity of the origin, the repo of a
// REST repository_url, and the ancestor chains of issues (GitHub GraphQL `parent` and `labels`, one
// batched query). Each fetch tells success, "none" and failure apart; a caller never reads a failure
// as "no link".

const { spawnSync } = require("child_process");
const { buildGhSpawn, buildGitSpawn } = require("../workflow/lib/workflow-init/spawn-env");
const { parseOriginOwnerRepo } = require("../../hooks/lib/parse-remote-url");

const GH_TIMEOUT_MS = 15000;
const OWNER_REPO_RE = /^([A-Za-z0-9._-]+)\/([A-Za-z0-9._-]+)$/;

// Identity comes from the origin remote alone — no fallback (#1899).
function resolveOwnerRepoFromOrigin() {
  const [cmd, args, spawnOpts] = buildGitSpawn(["remote", "get-url", "origin"]);
  const result = spawnSync(cmd, args, spawnOpts);
  if (result.status !== 0 || !result.stdout) {
    return { ok: false, message: "no 'origin' remote is configured" };
  }
  const url = String(result.stdout).split(/\r?\n/)[0].trim();
  const parsed = parseOriginOwnerRepo(url);
  if (!parsed.ok) return { ok: false, message: parsed.message };
  return { ok: true, ownerRepo: parsed.ownerRepo };
}

// Parses "https://api.github.com/repos/OWNER/REPO" -> "OWNER/REPO", or null.
const API_REPOS_PREFIX = "https://api.github.com/repos/";

function parseOwnerRepoFromApiUrl(repositoryUrl) {
  if (typeof repositoryUrl !== "string") return null;
  if (!repositoryUrl.startsWith(API_REPOS_PREFIX)) return null;
  const rest = repositoryUrl.slice(API_REPOS_PREFIX.length).replace(/\/+$/, "");
  return OWNER_REPO_RE.test(rest) ? rest : null;
}

// The label that makes an issue a meta issue (its sub-issues fall in the range of whoever holds it).
const META_LABEL = "meta";
const MAX_ANCESTOR_DEPTH = 10;
const CHUNK_SIZE = 50;

const refKey = (repo, n) => `${String(repo).toLowerCase()}#${n}`;

// The issue node, its MAX_ANCESTOR_DEPTH ancestors nested under parent, and parent{number} below
// the last one so a deeper chain shows up instead of reading as "no parent".
function nodeFields(depth) {
  const own = "number repository{nameWithOwner} labels(first:100){nodes{name} pageInfo{hasNextPage}}";
  return depth < MAX_ANCESTOR_DEPTH ? `${own} parent{${nodeFields(depth + 1)}}` : `${own} parent{number}`;
}

// buildQuery(refs, fields?) -> {query, slots: [{key, path: [repoAlias, issueAlias]}]}; refs are validated
// already; fields is the issue selection (default: the ancestor chain).
function buildQuery(refs, fieldsArg) {
  const byRepo = new Map();
  for (const r of refs) {
    if (!byRepo.has(r.repoKey)) byRepo.set(r.repoKey, { owner: r.owner, name: r.name, refs: [] });
    byRepo.get(r.repoKey).refs.push(r);
  }
  const slots = [];
  const fields = fieldsArg || nodeFields(0);
  let k = 0;
  const parts = [...byRepo.values()].map((g, ri) => {
    const issues = g.refs.map((r) => {
      const ia = `i${k++}`;
      slots.push({ key: r.key, path: [`r${ri}`, ia] });
      return `${ia}: issue(number: ${r.number}) { ${fields} }`;
    });
    return `r${ri}: repository(owner: "${g.owner}", name: "${g.name}") { ${issues.join(" ")} }`;
  });
  return { query: `query { ${parts.join(" ")} }`, slots };
}

const metaOf = (labels) => {
  const nodes = labels && Array.isArray(labels.nodes) ? labels.nodes : [];
  if (nodes.some((l) => l && l.name === META_LABEL)) return true;
  return labels && labels.pageInfo && labels.pageInfo.hasNextPage ? null : false;
};

// chainOf(node, selfKey) -> {ok:true, chain:[{number, repo, meta}]} (ancestors, nearest first) or
// {ok:false, reason: "cycle"|"depth-cap"|"parse_failed"}. A repeated issue is a cycle before it is a cap.
function chainOf(node, selfKey) {
  const seen = new Set([selfKey]);
  const chain = [];
  let cur = node.parent;
  for (let depth = 1; cur; depth++) {
    const repo = cur.repository && typeof cur.repository.nameWithOwner === "string" ? cur.repository.nameWithOwner : null;
    if (!Number.isInteger(cur.number)) return { ok: false, reason: "parse_failed" };
    if (repo !== null && seen.has(refKey(repo, cur.number))) return { ok: false, reason: "cycle" };
    if (depth > MAX_ANCESTOR_DEPTH) return { ok: false, reason: "depth-cap" };
    if (repo === null) return { ok: false, reason: "parse_failed" };
    seen.add(refKey(repo, cur.number));
    chain.push({ number: cur.number, repo, meta: metaOf(cur.labels) });
    cur = cur.parent;
  }
  return { ok: true, chain };
}

const nodeAt = (data, p) => p.reduce((o, k) => (o && typeof o === "object" ? o[k] : null), data);
const covers = (errPath, slotPath) => Array.isArray(errPath) && errPath.length > 0 && errPath.length <= slotPath.length
  && errPath.every((k, i) => k === slotPath[i]);
const inside = (errPath, slotPath) => Array.isArray(errPath) && errPath.length > slotPath.length
  && slotPath.every((k, i) => errPath[i] === k);

// classifyGraphqlResult(spawnResult, slots, readNode) -> {ok:true, results: {[key]: readNode(node, key) |
// {ok:false, reason}}} | {ok:false, reason: "timeout"|"gh_exec_failed"|"parse_failed"} (#2942).
// gh exits 1 when one aliased node of a batch is missing yet still prints `data`; only a slot an
// errors[].type NOT_FOUND covers is issue_not_found, a slot another error covers is gh_exec_failed, and
// every other slot is read. No data on a non-zero exit is a whole-call gh_exec_failed (network, auth).
// A slot with any error inside its node (a partial node) is gh_exec_failed, never read.
function classifyGraphqlResult(r, slots, readNode) {
  if (r.error || r.signal) return { ok: false, reason: "timeout" };
  let body;
  try { body = JSON.parse(String(r.stdout || "").trim()); } catch { body = null; }
  const data = body && body.data && typeof body.data === "object" ? body.data : null;
  if (!data) return { ok: false, reason: r.status === 0 ? "parse_failed" : "gh_exec_failed" };
  const errors = Array.isArray(body.errors) ? body.errors.filter((e) => e && typeof e === "object") : [];
  const results = {};
  for (const s of slots) {
    const node = nodeAt(data, s.path);
    if (node && typeof node === "object") {
      results[s.key] = errors.some((e) => inside(e.path, s.path)) ? { ok: false, reason: "gh_exec_failed" } : readNode(node, s.key);
      continue;
    }
    const errs = errors.filter((e) => covers(e.path, s.path));
    const notFound = errs.length > 0 ? errs.every((e) => e.type === "NOT_FOUND") : r.status === 0;
    results[s.key] = { ok: false, reason: notFound ? "issue_not_found" : "gh_exec_failed" };
  }
  return { ok: true, results };
}

// batchedGraphql(refs, {fields, readNode, keyOf?}, {deadlineAt?, timeoutMs?}) -> {ok:true, results: {[key]:
// readNode(node, key) | {ok:false, reason}}} or a whole-call {ok:false, reason: "gh_exec_failed"|"timeout"|
// "parse_failed"}. key is keyOf(repo, N) (default refKey). Refs go 50 per gh call; one deadlineAt covers
// every call (none left -> timeout without calling gh); without it each call gets timeoutMs (15 s).
function batchedGraphql(refs, spec, opts) {
  const o = opts || {};
  const keyOf = spec.keyOf || refKey;
  const results = {};
  const valid = new Map();
  for (const ref of Array.isArray(refs) ? refs : []) {
    const repo = ref && typeof ref.repo === "string" ? ref.repo : "";
    const m = repo.match(OWNER_REPO_RE);
    const key = keyOf(repo, ref && ref.number);
    if (!m) { results[key] = { ok: false, reason: "repo-unknown" }; continue; }
    if (!Number.isInteger(ref.number) || ref.number <= 0) { results[key] = { ok: false, reason: "issue_not_found" }; continue; }
    if (!valid.has(key)) valid.set(key, { key, number: ref.number, owner: m[1], name: m[2], repoKey: repo.toLowerCase() });
  }
  const list = [...valid.values()];
  for (let i = 0; i < list.length; i += CHUNK_SIZE) {
    let timeoutMs = Number.isFinite(o.timeoutMs) ? o.timeoutMs : GH_TIMEOUT_MS;
    if (Number.isFinite(o.deadlineAt)) timeoutMs = Math.min(timeoutMs, o.deadlineAt - Date.now());
    if (timeoutMs <= 0) return { ok: false, reason: "timeout" };
    const { query, slots } = buildQuery(list.slice(i, i + CHUNK_SIZE), spec.fields);
    const [cmd, args, spawnOpts] = buildGhSpawn(["api", "graphql", "--input", "-"]);
    const r = spawnSync(cmd, args, Object.assign({}, spawnOpts, { input: JSON.stringify({ query }), timeout: timeoutMs }));
    const c = classifyGraphqlResult(r, slots, spec.readNode);
    if (!c.ok) return c;
    Object.assign(results, c.results);
  }
  return { ok: true, results };
}

// fetchAncestorChains(refs, {deadlineAt?, timeoutMs?}) -> {ok:true, results: {[refKey]: {ok:true, chain} |
// {ok:false, reason}}} or a whole-call {ok:false, reason}; see batchedGraphql.
const fetchAncestorChains = (refs, opts) => batchedGraphql(refs, { fields: nodeFields(0), readNode: chainOf }, opts);

module.exports = {
  resolveOwnerRepoFromOrigin, parseOwnerRepoFromApiUrl, fetchAncestorChains, classifyGraphqlResult, batchedGraphql, refKey, META_LABEL,
  MAX_ANCESTOR_DEPTH, OWNER_REPO_RE,
};
// fetchSubIssueTree lives in ./sub-issue-tree.js (it reads the PM field, which needs this module first).
module.exports.fetchSubIssueTree = (refs, opts) => require("./sub-issue-tree").fetchSubIssueTree(refs, opts);
