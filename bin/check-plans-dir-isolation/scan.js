"use strict";

// Recursive *.sh discovery for the isolation scan (#2512 stage 4).
// `lib` is skipped at the scan root only (shared harness helpers); the other
// names are fixture, archive or vendored trees and are skipped at any depth.

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

module.exports = { listShellFiles };
