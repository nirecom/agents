"use strict";

const { isUnresolvableToken } = require("./helpers");

/**
 * Extract tee write targets from a shell command string.
 *
 * Handles: tee [flags] file1 [file2 ...]
 * Skips:   -a/--append/-i/-p flags
 * Returns: string[] on success, null on parse failure.
 */
function extractTeeTargets(cmd) {
  if (!cmd || typeof cmd !== "string") return null;

  // Process substitutions in tee args → fail-closed.
  if (/tee\s[^;|&]*>\s*\(/.test(cmd)) return null;

  // Find tee invocation.
  const RE = /(?:^|[\s;|&])tee\b(.*?)(?:$|[;|&](?:[^|&]|$))/s;
  const m = RE.exec(cmd);
  if (!m) return [];

  const argStr = m[1];
  // Split on whitespace, filter out flags.
  const tokens = argStr.trim().split(/\s+/).filter(Boolean);
  const targets = [];
  let i = 0;
  while (i < tokens.length) {
    const t = tokens[i];
    if (t === "-a" || t === "--append" || t === "-i" || t === "-p" || t === "--ignore-interrupts") {
      i++;
      continue;
    }
    if (t.startsWith("-")) {
      i++;
      continue;
    }
    // Process substitution
    if (t.startsWith(">(")) return null;
    if (isUnresolvableToken(t)) return null;
    targets.push(t);
    i++;
  }
  return targets;
}

module.exports = { extractTeeTargets };
