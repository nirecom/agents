"use strict";
// bin/lib/prompt-extraction/targets.js
//
// Target file set SSOT for check-prompt-extraction.
// This is an intentional superset of rules/prompt.md:10.
// The rationale for the superset is documented in #1642 detail plan.
//
//   rules/**/*.md, skills/*/SKILL.md, skills/_shared/**/*.md,
//   skills/*/agents/**/*.md, agents/**/*.md
// Excluded anywhere in the path: _archived/, _archive/, node_modules/, .git/

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const TARGET_PATTERNS = [
  /^rules\/(?:[^/]+\/)*[^/]+\.md$/,
  /^skills\/[^/]+\/SKILL\.md$/,
  /^skills\/_shared\/(?:[^/]+\/)*[^/]+\.md$/,
  /^skills\/[^/]+\/agents\/(?:[^/]+\/)*[^/]+\.md$/,
  /^agents\/(?:[^/]+\/)*[^/]+\.md$/,
];
const EXCLUDE_RE = /(^|\/)(_archived|_archive|node_modules|\.git)(\/|$)/;
const ROOT_DIRS = ["rules", "skills", "agents"];
const ALLOWLIST_NAME = ".prompt-extraction-allowlist";

function normalize(p) {
  return String(p).replace(/\\/g, "/");
}

function isTargetPath(relPath) {
  const p = normalize(relPath);
  if (EXCLUDE_RE.test(p)) return false;
  return TARGET_PATTERNS.some((re) => re.test(p));
}

function git(root, args, opts) {
  return spawnSync("git", args, {
    cwd: root,
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
    ...(opts || {}),
  });
}

/** @returns {string|null} absolute repo root, or null when not a git repo. */
function resolveRepoRoot(cwd) {
  const r = spawnSync("git", ["rev-parse", "--show-toplevel"], {
    cwd,
    encoding: "utf8",
  });
  if (r.error || r.status !== 0) return null;
  const out = (r.stdout || "").trim();
  return out === "" ? null : normalize(out);
}

function walk(dir, root, acc) {
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch (_e) {
    return;
  }
  for (const ent of entries) {
    const abs = path.join(dir, ent.name);
    const rel = normalize(path.relative(root, abs));
    if (EXCLUDE_RE.test(rel)) continue;
    if (ent.isDirectory()) {
      walk(abs, root, acc);
    } else if (ent.isFile() && ent.name.endsWith(".md") && isTargetPath(rel)) {
      acc.push(rel);
    }
  }
}

function readWorkingTree(root, rel) {
  try {
    return fs.readFileSync(path.join(root, rel), "utf8");
  } catch (_e) {
    return null;
  }
}

function readIndex(root, rel) {
  const r = git(root, ["show", `:${rel}`]);
  if (r.error || r.status !== 0) return null;
  return r.stdout;
}

/**
 * Read many index blobs in ONE `git cat-file --batch` process.
 * Spawning one `git show` per file costs ~100 files x process-startup, which on
 * Windows alone exceeds the gate's spawn budget.
 * An empty result and a failed result must never collapse into the same value:
 * returning [] on spawn failure would make the caller report "no violations" and
 * the gate would fail open on a broken git. Every failure returns null.
 * @param {string} root
 * @param {Array<{path: string, oid: string}>} items
 * @returns {Array<{path: string, content: string}>|null} null on infra failure.
 */
function readIndexBatch(root, items) {
  if (items.length === 0) return [];
  const r = spawnSync("git", ["cat-file", "--batch"], {
    cwd: root,
    input: items.map((i) => i.oid).join("\n") + "\n",
    maxBuffer: 256 * 1024 * 1024,
  });
  if (r.error || r.status !== 0 || !r.stdout) return null;

  const buf = r.stdout;
  const files = [];
  let pos = 0;
  for (const item of items) {
    const nl = buf.indexOf(0x0a, pos);
    // A short or malformed batch stream means we did NOT read every requested
    // blob — treat it as an infra failure rather than silently scanning less.
    if (nl === -1) return null;
    const header = buf.slice(pos, nl).toString("utf8");
    const parts = header.split(" ");
    if (parts.length < 3) return null; // "<oid> missing"
    const size = Number(parts[2]);
    if (!Number.isFinite(size)) return null;
    const start = nl + 1;
    if (start + size > buf.length) return null; // truncated blob body
    files.push({
      path: item.path,
      content: buf.slice(start, start + size).toString("utf8"),
    });
    pos = start + size + 1; // trailing LF after the blob body
  }
  return files;
}

/** --all: every target file in the working tree. */
function collectAll(root) {
  const rels = [];
  for (const d of ROOT_DIRS) walk(path.join(root, d), root, rels);
  rels.sort();
  return rels
    .map((rel) => ({ path: rel, content: readWorkingTree(root, rel) }))
    .filter((f) => f.content !== null);
}

/**
 * --staged: every target file present in the git INDEX, content read from the
 * index. The unit of judgement is the tree that the commit would create, not the
 * diff against HEAD: `git add` on a byte-identical file still puts it into the
 * commit, and a commit must be judged against what it actually contains (CPR-E2E).
 * Pre-existing debt is neutralised by .prompt-extraction-allowlist, not by
 * narrowing the scan.
 * @returns {Array|null} null when the index listing or blob read fails.
 */
function collectStaged(root) {
  const r = git(root, [
    "-c",
    "core.quotePath=false",
    "ls-files",
    "-s",
    "-z",
    "--cached",
  ]);
  if (r.error || r.status !== 0) return null;

  const items = [];
  for (const raw of (r.stdout || "").split("\0")) {
    if (raw === "") continue;
    // "<mode> <oid> <stage>\t<path>"
    const tab = raw.indexOf("\t");
    if (tab === -1) continue;
    const meta = raw.slice(0, tab).split(/\s+/);
    if (meta.length < 3) continue;
    const rel = normalize(raw.slice(tab + 1));
    if (!isTargetPath(rel)) continue;
    items.push({ path: rel, oid: meta[1] });
  }
  items.sort((a, b) => a.path.localeCompare(b.path));
  return readIndexBatch(root, items);
}

/**
 * --base <ref>: target files that differ from <ref> in the working tree
 * (committed, staged, unstaged, and untracked alike), content read from disk.
 * @returns {Array|null} null when the ref cannot be resolved.
 */
function collectBase(root, ref) {
  const verify = git(root, ["rev-parse", "--verify", "--quiet", `${ref}^{commit}`]);
  if (verify.error || verify.status !== 0) return null;

  const diff = git(root, [
    "-c",
    "core.quotePath=false",
    "diff",
    "-z",
    "--name-only",
    "--diff-filter=ACMRT",
    ref,
  ]);
  if (diff.error || diff.status !== 0) return null;

  const untracked = git(root, [
    "-c",
    "core.quotePath=false",
    "ls-files",
    "-z",
    "--others",
    "--exclude-standard",
  ]);

  const rels = new Set();
  for (const chunk of [diff.stdout || "", untracked.stdout || ""]) {
    for (const raw of chunk.split("\0")) {
      const rel = normalize(raw.trim());
      if (rel !== "" && isTargetPath(rel)) rels.add(rel);
    }
  }
  return Array.from(rels)
    .sort()
    .map((rel) => ({ path: rel, content: readWorkingTree(root, rel) }))
    .filter((f) => f.content !== null);
}

/**
 * Allowlist text for the given mode. --staged prefers the INDEX copy so the
 * commit is judged against what is actually being committed (CPR-E2E).
 * @returns {string|null} null when no allowlist exists anywhere.
 */
function readRepoAllowlist(root, mode) {
  if (mode === "staged") {
    const indexed = readIndex(root, ALLOWLIST_NAME);
    if (indexed !== null) return indexed;
  }
  return readWorkingTree(root, ALLOWLIST_NAME);
}

module.exports = {
  ALLOWLIST_NAME,
  isTargetPath,
  resolveRepoRoot,
  collectAll,
  collectStaged,
  collectBase,
  readRepoAllowlist,
  normalize,
};
