"use strict";

// Residual retired-variable check (#2512 stage 4). The token is assembled from two
// parts so this module never carries the literal it hunts for.

const { execFileSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const TOKEN_RE = new RegExp("CLAUDE_" + "WORKFLOW_DIR", "i");
// SSOT exclusion list: append-only history records keep the old name by design.
const EXEMPT = [(p) => p === "docs/history.md", (p) => p.startsWith("docs/history/"), (p) => p === "CHANGELOG.md"];

const isExempt = (rel) => EXEMPT.some((f) => f(rel));

function git(repoRoot, args) {
  return execFileSync("git", ["-C", repoRoot, ...args], { maxBuffer: 256 * 1024 * 1024 });
}

const nulList = (buf) => buf.toString("utf8").split("\0").filter(Boolean);

// hits(rel, buf) → RESIDUAL-TOKEN lines for one file's content (binary skipped).
function hits(rel, buf) {
  if (isExempt(rel) || buf.includes(0)) return [];
  const out = [];
  buf.toString("utf8").split("\n").forEach((line, i) => {
    if (TOKEN_RE.test(line)) out.push(`RESIDUAL-TOKEN: ${rel}:${i + 1}`);
  });
  return out;
}

// trackedHits(repoRoot) → lines for every tracked file in the working tree.
function trackedHits(repoRoot) {
  const out = [];
  for (const rel of nulList(git(repoRoot, ["ls-files", "-z"]))) {
    let buf;
    try {
      buf = fs.readFileSync(path.join(repoRoot, rel));
    } catch {
      continue;
    }
    out.push(...hits(rel, buf));
  }
  return out;
}

// stagedPaths(repoRoot) → staged added/copied/modified/renamed paths.
function stagedPaths(repoRoot) {
  return nulList(git(repoRoot, ["diff", "--cached", "--name-only", "-z", "--diff-filter=ACMR"]));
}

// stagedHits(repoRoot, paths) → lines for the staged blob of each path.
function stagedHits(repoRoot, paths) {
  const out = [];
  for (const rel of paths) out.push(...hits(rel, git(repoRoot, ["show", `:${rel}`])));
  return out;
}

module.exports = { trackedHits, stagedPaths, stagedHits };
