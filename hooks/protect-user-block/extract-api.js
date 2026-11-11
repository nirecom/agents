"use strict";
// gh api (REST issue endpoints and the six GraphQL issue mutations) -> operation descriptors.
// Returns { descs } or { unresolved, why }; a GraphQL input whose structure cannot be read
// returns { decide: "deny"|"ask" } directly, since no target can be handed to the CLI.
const { scanGhApiFlags, hasInputFlag, lastFieldValue } = require("../lib/gh-api-argv");
const sel = require("../lib/forge-repo-selectors");
const { repoOf, textValue, readBodyFile, isNonLiteral, unreadable, unresolved } = require("./extract");

const REST_RE = /^repos\/([^/]+)\/([^/]+)\/issues(?:\/(\d+)(\/comments)?|\/comments\/(\d+))?$/;
const MUTATION_RE = /\b(createIssue|addComment|updateIssue|updateIssueComment|deleteIssueComment|deleteIssue)\s*\(/g;
const PAIR_RE = /(\w+)\s*:\s*(\$\w+|"(?:[^"\\]|\\.)*"|[^,}\s]+)/g;

// A payload field as gh would send it; `@file` is the file content or unreadable.
function fieldValue(flags, name, cwd) {
  const f = lastFieldValue(flags, name);
  if (!f) return undefined;
  if (typeof f.value !== "string" || isNonLiteral(f.raw)) return unreadable();
  if (f.value[0] === "@") return readBodyFile(f.value.slice(1), null, cwd);
  return textValue(f.value, null);
}

function methodOf(flags) {
  let m = null;
  for (const f of flags) if (f && (f.flag === "-X" || f.flag === "--method")) m = f.value;
  if (typeof m === "string") return m.toUpperCase();
  const hasPayload = flags.some((f) => f && (["-f", "-F", "--field", "--raw-field", "--input"].indexOf(f.flag) !== -1));
  return hasPayload ? "POST" : "GET";
}

// The path gh sends: drop ?query / #fragment, the api.github.com host (only that host), and edge slashes.
function normalizeEndpoint(endpoint) {
  return endpoint.replace(/[?#][\s\S]*$/, "").replace(/^(?:https:\/\/)?api\.github\.com\//i, "").replace(/^\/+|\/+$/g, "");
}

function restDescs(scan, endpoint, method, repoBase, cwd) {
  const m = endpoint.match(REST_RE);
  if (!m) return { descs: [] };
  const placeholder = m[1] === "{owner}" && m[2] === "{repo}";
  let repo = null;
  if (!placeholder) {
    repo = sel.splitSelector(m[1] + "/" + m[2]);
    if (!repo) return unresolved("the gh api endpoint does not name a github.com repository");
  } else if (repoBase.repo) repo = repoBase.repo;
  const input = hasInputFlag(scan.flags);
  const body = input ? unreadable() : fieldValue(scan.flags, "body", cwd);
  const title = input ? unreadable() : fieldValue(scan.flags, "title", cwd);
  const d = (o) => (repo ? Object.assign(o, { repo }) : o);
  const [, , , issue, comments, commentId] = m;
  if (!issue && !commentId && method === "POST") return { descs: [d({ op: "create", title, body })] };
  if (issue && !comments && method === "PATCH") {
    if (!title && !body) return { descs: [] };
    return { descs: [d({ op: "edit", issue, title, body })] };
  }
  if (issue && comments && method === "POST") return body ? { descs: [d({ op: "comment-create", issue, body })] } : { descs: [] };
  if (commentId && method === "PATCH") return { descs: [d({ op: "comment-edit", commentId, body: body || unreadable() })] };
  if (commentId && method === "DELETE") return { descs: [d({ op: "comment-delete", commentId })] };
  return { descs: [] };
}

function gqlValue(token, flags, cwd) {
  if (token === undefined) return undefined;
  if (token[0] === "$") return fieldValue(flags, token.slice(1), cwd) || unreadable();
  if (token[0] === "\"") {
    try { return { value: JSON.parse(token) }; } catch (_e) { return unreadable(); }
  }
  return unreadable();
}

// Drops `# ...` line comments outside "string" literals, so a leading comment cannot hide an operation.
function stripGqlComments(src) {
  let out = "";
  let inStr = false;
  for (let i = 0; i < src.length; i++) {
    const c = src[i];
    if (inStr) {
      out += c;
      if (c === "\\" && i + 1 < src.length) out += src[++i];
      else if (c === "\"") inStr = false;
    } else if (c === "#") {
      while (i + 1 < src.length && src[i + 1] !== "\n" && src[i + 1] !== "\r") i++;
    } else {
      if (c === "\"") inStr = true;
      out += c;
    }
  }
  return out;
}

function graphqlDescs(scan, cwd) {
  const q = lastFieldValue(scan.flags, "query");
  if (!q) return { descs: [] };
  if (typeof q.value !== "string" || isNonLiteral(q.raw)) {
    return /\bupdateIssue\s*\(/.test(String(q.raw)) ? unresolved("the GraphQL query is not readable") : { descs: [] };
  }
  const text = stripGqlComments(q.value);
  if (!/(^|[\s}])mutation\b/.test(text)) return { descs: [] };
  const descs = [];
  for (const mm of text.matchAll(MUTATION_RE)) {
    const name = mm[1];
    const after = text.slice(mm.index + mm[0].length);
    const obj = after.match(/^\s*input\s*:\s*\{([^}]*)\}/);
    if (!obj) return { decide: name === "updateIssue" ? "deny" : "ask", why: "the " + name + " input cannot be read" };
    const args = {};
    for (const pm of obj[1].matchAll(PAIR_RE)) args[pm[1]] = pm[2];
    const v = (k) => gqlValue(args[k], scan.flags, cwd);
    const node = (k) => {
      const n = v(k);
      return n && typeof n.value === "string" ? n.value : null;
    };
    let d;
    if (name === "createIssue") d = { op: "create", title: v("title"), body: v("body") };
    else if (name === "addComment") d = { op: "comment-create", nodeId: node("subjectId"), body: v("body") || unreadable() };
    else if (name === "updateIssue") {
      const title = v("title");
      const body = v("body");
      if (!title && !body) continue;
      d = { op: "edit", nodeId: node("id"), title, body };
    } else if (name === "updateIssueComment") d = { op: "comment-edit", nodeId: node("id"), body: v("body") || unreadable() };
    else if (name === "deleteIssueComment") d = { op: "comment-delete", nodeId: node("id") };
    else d = { op: "issue-delete", nodeId: node("issueId") };
    if (d.op !== "create" && !d.nodeId) {
      return name === "updateIssue" && d.title ? { decide: "deny", why: "the updateIssue id cannot be read" } : unresolved("the " + name + " id cannot be read");
    }
    descs.push(d);
  }
  return { descs };
}

// argv/argvRaw follow the `gh` word and start with `api`.
function extractApi(argv, argvRaw, rawText, ghRepo, cwd) {
  const raws = Array.isArray(argvRaw) ? argvRaw : argv;
  const scan = scanGhApiFlags(argv.slice(1), raws.slice(1));
  if (scan.ambiguous) return unresolved("the gh api flags cannot be read unambiguously");
  if (typeof scan.endpoint !== "string") return { descs: [] };
  if (isNonLiteral(scan.endpointRaw)) return unresolved("the gh api endpoint is not a literal value");
  const repoBase = repoOf(argv, argvRaw, rawText, ghRepo);
  if (repoBase.unresolved) return repoBase;
  if (scan.endpoint === "graphql") return graphqlDescs(scan, cwd);
  return restDescs(scan, normalizeEndpoint(scan.endpoint), methodOf(scan.flags), repoBase, cwd);
}

module.exports = { extractApi };
