"use strict";
// bin/lib/prompt-extraction/allowlist.js
// Allowlist parsing / matching / totals for bin/check-prompt-extraction (issue #1642).
//
// Format (one entry per line, '#'-prefixed lines and blank lines ignored):
//     <kind> <path> <count>
// where <kind> is code-fence | inline-procedure and <count> is an integer or '*'.

/** Normalize a path to forward slashes so Windows and POSIX compare equal. */
function normalizePath(p) {
  return String(p).replace(/\\/g, "/");
}

/**
 * @param {string} text
 * @returns {Array<{kind: string, path: string, count: number|"*"}>}
 */
function parseAllowlist(text) {
  const entries = [];
  for (const raw of String(text == null ? "" : text).split(/\r?\n/)) {
    const line = raw.trim();
    if (line === "" || line.startsWith("#")) continue;
    const parts = line.split(/\s+/);
    if (parts.length < 3) continue;
    const [kind, path, countToken] = parts;
    if (countToken === "*") {
      entries.push({ kind, path: normalizePath(path), count: "*" });
      continue;
    }
    if (!/^\d+$/.test(countToken)) continue;
    entries.push({
      kind,
      path: normalizePath(path),
      count: Number(countToken),
    });
  }
  return entries;
}

/**
 * Decide whether `actualCount` violations of `kind` in `filePath` are covered.
 * A missing entry behaves exactly like an entry with count 0 (CPR-5).
 */
function matchAllowlist(entries, kind, filePath, actualCount) {
  const path = normalizePath(filePath);
  let best = 0;
  let isWildcard = false;
  for (const e of entries) {
    if (e.kind !== kind || e.path !== path) continue;
    if (e.count === "*") {
      isWildcard = true;
      break;
    }
    if (e.count > best) best = e.count;
  }
  if (isWildcard) {
    return { allowed: true, isWildcard: true, allowlistCount: "*" };
  }
  return {
    allowed: actualCount <= best,
    isWildcard: false,
    allowlistCount: best,
  };
}

/**
 * TOTAL = sum of the count field over NON-wildcard entries.
 * WILDCARD = number of '*' entries.
 * entries = total entry rows (diagnostic only).
 */
function computeTotal(entries) {
  let total = 0;
  let wildcard = 0;
  for (const e of entries) {
    if (e.count === "*") wildcard += 1;
    else total += e.count;
  }
  return { total, wildcard, entries: entries.length };
}

/** Render allowlist text from {kind, path, count} rows. */
function generateAllowlist(rows) {
  const sorted = rows
    .slice()
    .sort((a, b) =>
      a.path === b.path
        ? a.kind.localeCompare(b.kind)
        : a.path.localeCompare(b.path)
    );
  const lines = [
    "# .prompt-extraction-allowlist — frozen baseline of pre-existing prompt bloat.",
    "# Format: <kind> <path> <count>   (kind: code-fence | inline-procedure)",
    "# Ratchet: counts may shrink, never grow (tests/feature-1642-prompt-extraction-static-guards.sh).",
    "# Regenerate with: bin/check-prompt-extraction --all --write-allowlist",
  ];
  for (const r of sorted) {
    lines.push(`${r.kind} ${normalizePath(r.path)} ${r.count}`);
  }
  return lines.join("\n") + "\n";
}

module.exports = {
  parseAllowlist,
  matchAllowlist,
  computeTotal,
  generateAllowlist,
  normalizePath,
};
