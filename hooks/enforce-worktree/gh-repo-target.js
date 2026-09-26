"use strict";
// hooks/enforce-worktree/gh-repo-target.js
// #1246: resolve the repo a `gh issue create` targets via --repo / -R / GH_REPO, so
// the #713 main-worktree skill gate can tell a create aimed at ANOTHER managed
// session repo (allowed) from one aimed at the CWD repo (gated). Every value is read
// from IR argv, never raw text — a `--repo` inside a quoted body is just a value.

const { spawnSync } = require("child_process");
const { stripQuotedArgs } = require("../lib/strip-quoted-args");
const { resolveGhSegmentArgv, resolveGhSubArgv } = require("../lib/bash-write-patterns/patterns");
const { commandBasename } = require("../lib/bash-write-patterns/segment-utils");
const { normalizeForCompare } = require("./git-repo-detection");

const RAW_ISSUE_CREATE_RE = /\bgh\s+issue\s+create\b/;
// `gh issue create` flags that take no value; every other flag consumes one.
const GH_ISSUE_CREATE_BOOLEAN_FLAGS = new Set(["-w", "--web", "-e", "--editor", "-h", "--help"]);

// `owner/name` (lowercase) from a --repo value or an origin URL; null when unparseable.
// A `HOST/OWNER/REPO` value keeps only the last two components.
function toSlug(value) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim().replace(/\/+$/, "").replace(/\.git$/i, "");
  const parts = trimmed.split(/[/:]/).filter(Boolean);
  if (parts.length < 2) return null;
  const owner = parts[parts.length - 2];
  const name = parts[parts.length - 1];
  if (!/^[A-Za-z0-9_.-]+$/.test(owner) || !/^[A-Za-z0-9_.-]+$/.test(name)) return null;
  return (owner + "/" + name).toLowerCase();
}

const _originSlugCache = new Map();
function originSlugOf(root) {
  if (_originSlugCache.has(root)) return _originSlugCache.get(root);
  let slug = null;
  try {
    const r = spawnSync("git", ["-C", root, "remote", "get-url", "origin"], { encoding: "utf8", timeout: 2000 });
    if (!r.error && r.status === 0) slug = toSlug((r.stdout || "").trim());
  } catch (_) { slug = null; }
  _originSlugCache.set(root, slug);
  return slug;
}

function isIssueCreateArgv(ghArgv) {
  const sub = resolveGhSubArgv(ghArgv);
  return sub[0] === "issue" && sub[1] === "create";
}

// Distinct --repo / -R values in one gh argv (excluding `gh`).
function repoFlagValues(ghArgv) {
  const values = [];
  for (let i = 0; i < ghArgv.length; i++) {
    const tok = ghArgv[i];
    if (typeof tok !== "string" || tok[0] !== "-") continue;
    if (tok === "--") break;
    if (tok === "--repo" || tok === "-R") { values.push(ghArgv[i + 1]); i++; continue; }
    if (tok.startsWith("--repo=")) { values.push(tok.slice(7)); continue; }
    if (/^-R./.test(tok)) { values.push(tok.slice(2)); continue; }
    if (tok.includes("=") || GH_ISSUE_CREATE_BOOLEAN_FLAGS.has(tok)) continue;
    i++; // value-taking flag: its value is never parsed as a flag
  }
  return values;
}

// GH_REPO=… assignments that precede the gh token in the segment.
function ghRepoEnvValues(seg) {
  const tokens = [seg.cmd0].concat(Array.isArray(seg.argv) ? seg.argv : []);
  const values = [];
  for (const tok of tokens) {
    if (typeof tok !== "string") break;
    if (commandBasename(tok) === "gh") break;
    if (tok.startsWith("GH_REPO=")) values.push(tok.slice(8));
  }
  return values;
}

// Target slug of one issue-create segment: --repo wins over GH_REPO (gh's own
// precedence); conflicting or missing values → null.
function segmentTargetSlug(seg, ghArgv) {
  const flagVals = repoFlagValues(ghArgv);
  const chosen = flagVals.length > 0 ? flagVals : ghRepoEnvValues(seg);
  const slugs = new Set(chosen.map(toSlug));
  if (slugs.size !== 1 || slugs.has(null)) return null;
  return [...slugs][0];
}

// True when any segment is (or textually looks like) a `gh issue create`.
function hasGhIssueCreate(ir, cmd) {
  if (RAW_ISSUE_CREATE_RE.test(stripQuotedArgs(cmd))) return true;
  if (!ir || ir.parseFailure === true || !Array.isArray(ir.segments)) return false;
  return ir.segments.some((seg) => {
    const ghArgv = resolveGhSegmentArgv(seg);
    return Array.isArray(ghArgv) && isIssueCreateArgv(ghArgv);
  });
}

// Session root that EVERY issue-create segment targets, when that root is a
// session repo other than the CWD repo; otherwise null (the #713 gate applies).
function resolveCrossRepoIssueCreateRoot(ir, sessionRoots, cwdRepoRoot) {
  if (!ir || ir.parseFailure === true || !Array.isArray(ir.segments)) return null;
  const targets = new Set();
  for (const seg of ir.segments) {
    const ghArgv = resolveGhSegmentArgv(seg);
    const isCreate = Array.isArray(ghArgv) && isIssueCreateArgv(ghArgv);
    if (!isCreate) {
      // A create the IR could not resolve (e.g. an ambiguous wrapper) cannot be vouched for.
      if (RAW_ISSUE_CREATE_RE.test(stripQuotedArgs(seg.rawText || ""))) return null;
      continue;
    }
    const slug = segmentTargetSlug(seg, ghArgv);
    if (slug === null) return null;
    targets.add(slug);
  }
  if (targets.size !== 1) return null;
  const slug = [...targets][0];
  const cwdNorm = cwdRepoRoot ? normalizeForCompare(cwdRepoRoot) : null;
  if (cwdNorm !== null && originSlugOf(cwdNorm) === slug) return null;
  for (const root of sessionRoots || []) {
    if (root === cwdNorm) continue;
    if (originSlugOf(root) === slug) return root;
  }
  return null;
}

module.exports = { hasGhIssueCreate, resolveCrossRepoIssueCreateRoot, toSlug };
