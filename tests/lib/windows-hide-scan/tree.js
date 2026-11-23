"use strict";
// tests/lib/windows-hide-scan/tree.js — the file set of the #3127 windowsHide scan (hooks/** and
// bin/**: .js/.cjs/.mjs plus extensionless node-shebang scripts; node_modules and .git skipped),
// the whole-tree scan, and the file-level count allowlist.
const fs = require("node:fs");
const path = require("node:path");
const { scanSource } = require("./route");

const TOP_DIRS = ["hooks", "bin"];
const SKIP_DIRS = new Set(["node_modules", ".git"]);
const JS_EXT = new Set([".js", ".cjs", ".mjs"]);

// Fail-closed: a directory or file the scan cannot read throws instead of silently shrinking the file set.
function unreadable(kind, target, error) {
  return Object.assign(new Error(`windows-hide-scan: cannot read ${kind} ${target} (${error.code || error.message})`), { code: "SCAN_UNREADABLE", path: target });
}

function hasNodeShebang(file) {
  let fd = null;
  try {
    fd = fs.openSync(file, "r");
    const buf = Buffer.alloc(200);
    const first = buf.subarray(0, fs.readSync(fd, buf, 0, buf.length, 0)).toString("utf8").split("\n")[0];
    return first.startsWith("#!") && /\bnode\b/.test(first);
  } catch (error) { throw unreadable("file", file, error); } finally { if (fd !== null) fs.closeSync(fd); }
}

// listTargetFiles(root) -> sorted repo-relative paths (forward slashes); throws code SCAN_UNREADABLE
// when root/hooks, root/bin or any directory below them is missing, not a directory, or unreadable.
function listTargetFiles(root) {
  const out = [];
  const walk = (dir) => {
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (error) { throw unreadable("directory", dir, error); }
    for (const e of entries) {
      const full = path.join(dir, e.name);
      if (e.isDirectory()) { if (!SKIP_DIRS.has(e.name)) walk(full); continue; }
      if (!e.isFile()) continue;
      const ext = path.extname(e.name);
      if (JS_EXT.has(ext) || (ext === "" && hasNodeShebang(full))) out.push(path.relative(root, full).split(path.sep).join("/"));
    }
  };
  for (const top of TOP_DIRS) walk(path.join(root, top));
  return out.sort();
}

function scanTree(root) {
  return listTargetFiles(root).flatMap((rel) => scanSource(rel, fs.readFileSync(path.join(root, rel), "utf8")));
}

// applyAllowlist(violations, allowlist) -> { violations, stale }: per file, `count` violations are
// allowed; the excess stays a violation and a shortfall is a stale entry.
function applyAllowlist(violations, allowlist) {
  const byFile = new Map();
  for (const v of violations) byFile.set(v.rel, [...(byFile.get(v.rel) || []), v]);
  const stale = [];
  for (const { file, count } of allowlist) {
    const found = (byFile.get(file) || []).length;
    if (found < count) stale.push(`stale allowlist entry: ${file} expects ${count}, found ${found}`);
    byFile.set(file, (byFile.get(file) || []).slice(count));
  }
  return { violations: [...byFile.values()].flat(), stale };
}

const formatViolation = (v) => `${v.rel}:${v.line}${v.call ? " " + v.call : ""} — ${v.reason}`;

module.exports = { listTargetFiles, scanTree, applyAllowlist, formatViolation };
