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
  const [cmd, args, opts] = buildGitSpawn(["remote", "get-url", "origin"]);
  const result = spawnSync(cmd, args, opts);
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

// buildQuery(refs) -> {query, slots: [{key, repoAlias, issueAlias}]}; refs are validated already.
function buildQuery(refs) {
  const byRepo = new Map();
  for (const r of refs) {
    if (!byRepo.has(r.repoKey)) byRepo.set(r.repoKey, { owner: r.owner, name: r.name, refs: [] });
    byRepo.get(r.repoKey).refs.push(r);
  }
  const slots = [];
  const fields = nodeFields(0);
  let k = 0;
  const parts = [...byRepo.values()].map((g, ri) => {
    const issues = g.refs.map((r) => {
      const ia = `i${k++}`;
      slots.push({ key: r.key, repoAlias: `r${ri}`, issueAlias: ia });
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

// runChunk(refs, timeoutMs) -> {ok:true, results} | {ok:false, reason}; one gh call.
function runChunk(refs, timeoutMs) {
  const { query, slots } = buildQuery(refs);
  const [cmd, args, opts] = buildGhSpawn(["api", "graphql", "--input", "-"]);
  const r = spawnSync(cmd, args, Object.assign({}, opts, { input: JSON.stringify({ query }), timeout: timeoutMs }));
  if (r.error || r.signal) return { ok: false, reason: "timeout" };
  if (r.status !== 0) return { ok: false, reason: "gh_exec_failed" };
  let body;
  try { body = JSON.parse(String(r.stdout || "").trim()); } catch (_e) { return { ok: false, reason: "parse_failed" }; }
  const data = body && body.data;
  if (!data || typeof data !== "object") return { ok: false, reason: "parse_failed" };
  const results = {};
  for (const s of slots) {
    const node = data[s.repoAlias] ? data[s.repoAlias][s.issueAlias] : null;
    results[s.key] = node && typeof node === "object" ? chainOf(node, s.key) : { ok: false, reason: "issue_not_found" };
  }
  return { ok: true, results };
}

// fetchAncestorChains(refs, {deadlineAt?, timeoutMs?}) -> {ok:true, results: {[key]: {ok:true, chain} |
// {ok:false, reason}}} or a whole-call {ok:false, reason: "gh_exec_failed"|"timeout"|"parse_failed"}.
// key is "<owner/repo lower>#N" (refKey). Refs go 50 per gh call; one deadlineAt covers every call
// (none left -> timeout without calling gh); without it each call gets timeoutMs (15 s).
function fetchAncestorChains(refs, opts) {
  const o = opts || {};
  const results = {};
  const valid = new Map();
  for (const ref of Array.isArray(refs) ? refs : []) {
    const repo = ref && typeof ref.repo === "string" ? ref.repo : "";
    const m = repo.match(OWNER_REPO_RE);
    const key = refKey(repo, ref && ref.number);
    if (!m) { results[key] = { ok: false, reason: "repo-unknown" }; continue; }
    if (!Number.isInteger(ref.number) || ref.number <= 0) { results[key] = { ok: false, reason: "issue_not_found" }; continue; }
    if (!valid.has(key)) valid.set(key, { key, number: ref.number, owner: m[1], name: m[2], repoKey: repo.toLowerCase() });
  }
  const list = [...valid.values()];
  for (let i = 0; i < list.length; i += CHUNK_SIZE) {
    let timeoutMs = Number.isFinite(o.timeoutMs) ? o.timeoutMs : GH_TIMEOUT_MS;
    if (Number.isFinite(o.deadlineAt)) {
      timeoutMs = o.deadlineAt - Date.now();
      if (timeoutMs <= 0) return { ok: false, reason: "timeout" };
    }
    const r = runChunk(list.slice(i, i + CHUNK_SIZE), timeoutMs);
    if (!r.ok) return r;
    Object.assign(results, r.results);
  }
  return { ok: true, results };
}

module.exports = {
  resolveOwnerRepoFromOrigin, parseOwnerRepoFromApiUrl, fetchAncestorChains, refKey, META_LABEL, MAX_ANCESTOR_DEPTH,
};
