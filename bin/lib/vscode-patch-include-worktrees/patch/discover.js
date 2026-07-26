// Root and extension-directory discovery — moved verbatim from the entrypoint's
// `// ---- discovery ----` section, together with the two constants it reads.
'use strict';

const fs = require('fs');
const path = require('path');

const { normalizeInputPath, pathKey, realPathKey, isDirectory } = require('../primitives');

// Home-relative, no platform branch: the same four spellings are probed everywhere and
// simply do not exist on hosts that never install that flavour.
const CANDIDATE_ROOTS = [
  path.join('.vscode', 'extensions'),
  path.join('.vscode-insiders', 'extensions'),
  path.join('.vscode-server', 'extensions'),
  path.join('.vscode-server-insiders', 'extensions'),
];

// Case-insensitive because the marketplace directory casing is not guaranteed; the `\d`
// requires a version segment right after the final `-`, so sibling names such as
// `anthropic.claude-code-beta` are not treated as installed versions. All matches are
// enumerated — two versions routinely coexist on a real install.
const EXTENSION_DIR_PATTERN = /^anthropic\.claude-code-\d/i;

// `overrides`, when non-empty, replaces the candidate table outright: the default roots
// are not scanned at all. Dedup runs in two stages — normalized string, then realpath —
// and preserves input order.
function resolveRoots(options) {
  const opts = options || {};
  const overrides = Array.isArray(opts.overrides) ? opts.overrides : [];
  const candidates = [];
  if (overrides.length > 0) {
    for (const override of overrides) candidates.push(normalizeInputPath(String(override)));
  } else {
    const home = normalizeInputPath(String(opts.home == null ? '' : opts.home));
    for (const relative of CANDIDATE_ROOTS) {
      const root = path.join(home, relative);
      // A default candidate that is absent, or exists as a regular file, is skipped
      // silently — unlike an explicit override, which main() rejects with exit 2.
      if (isDirectory(root)) candidates.push(root);
    }
  }

  const roots = [];
  const seenPath = new Set();
  const seenReal = new Set();
  for (const candidate of candidates) {
    const key = pathKey(candidate);
    if (seenPath.has(key)) continue;
    seenPath.add(key);
    const realKey = realPathKey(candidate);
    if (seenReal.has(realKey)) continue;
    seenReal.add(realKey);
    roots.push(candidate);
  }
  return roots;
}

// Matching directories inside one root, name-ascending, deduped by realpath.
function listExtensionDirs(root) {
  let names;
  try {
    names = fs.readdirSync(root);
  } catch {
    return [];
  }
  names.sort();
  const dirs = [];
  const seen = new Set();
  for (const name of names) {
    if (!EXTENSION_DIR_PATTERN.test(name)) continue;
    const full = path.join(root, name);
    if (!isDirectory(full)) continue;
    const key = realPathKey(full);
    if (seen.has(key)) continue;
    seen.add(key);
    dirs.push(full);
  }
  return dirs;
}

module.exports = { CANDIDATE_ROOTS, EXTENSION_DIR_PATTERN, resolveRoots, listExtensionDirs };
