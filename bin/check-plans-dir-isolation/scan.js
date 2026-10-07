"use strict";

// Recursive *.sh discovery for the isolation scan (#2512 stage 4).
// `lib` is skipped at the scan root only (shared harness helpers); the other
// names are fixture, archive or vendored trees and are skipped at any depth.

const { execFileSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const SKIP_ANY_DEPTH = new Set(["_archive", "fixtures", "node_modules", ".git"]);
const SKIP_AT_ROOT = new Set(["lib"]);

// listShellFiles(root) → sorted absolute paths of every scanned *.sh under root.
function listShellFiles(root) {
  const out = [];
  const walk = (dir, depth) => {
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      const full = path.join(dir, e.name);
      if (e.isDirectory()) {
        if (SKIP_ANY_DEPTH.has(e.name) || (depth === 0 && SKIP_AT_ROOT.has(e.name))) continue;
        walk(full, depth + 1);
      } else if (e.isFile() && e.name.endsWith(".sh")) {
        out.push(full);
      }
    }
  };
  walk(root, 0);
  return out.sort();
}

// isScannedPath(rel) → whether a root-relative "/"-separated *.sh path passes the walk's skip rules.
function isScannedPath(rel) {
  const parts = rel.split("/");
  if (!parts[parts.length - 1].endsWith(".sh")) return false;
  const dirs = parts.slice(0, -1);
  if (dirs.length > 0 && SKIP_AT_ROOT.has(dirs[0])) return false;
  return !dirs.some((d) => SKIP_ANY_DEPTH.has(d));
}

const git = (repoRoot, args, input) =>
  execFileSync("git", ["-C", repoRoot, ...args], { input, maxBuffer: 256 * 1024 * 1024 });

// readIndexShellFiles(repoRoot, sub) → Map<absPath, text> of every scanned *.sh staged
// under <repoRoot>/<sub>, read from the index (stage 0) rather than the working tree.
function readIndexShellFiles(repoRoot, sub) {
  const entries = [];
  for (const rec of git(repoRoot, ["ls-files", "-s", "-z", "--", sub]).toString("utf8").split("\0")) {
    const m = /^(100644|100755) ([0-9a-f]+) 0\t(.+)$/.exec(rec);
    if (m && isScannedPath(m[3].slice(sub.length + 1))) entries.push({ sha: m[2], rel: m[3] });
  }
  const out = new Map();
  if (entries.length === 0) return out;
  const buf = git(repoRoot, ["cat-file", "--batch"], entries.map((e) => e.sha).join("\n") + "\n");
  let at = 0;
  for (const e of entries) {
    const nl = buf.indexOf(0x0a, at);
    const size = Number(buf.toString("utf8", at, nl).split(" ")[2]);
    out.set(path.join(repoRoot, e.rel), buf.toString("utf8", nl + 1, nl + 1 + size));
    at = nl + 1 + size + 1;
  }
  return out;
}

module.exports = { listShellFiles, readIndexShellFiles };
