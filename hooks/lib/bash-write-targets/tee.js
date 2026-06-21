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
    // Single-quoted strings: POSIX literals — strip surrounding quotes and push as-is.
    // $ is NOT expanded inside single quotes, so skip env-var resolution entirely.
    if (t.startsWith("'") && t.endsWith("'")) {
      targets.push(t.slice(1, -1));
      i++;
      continue;
    }
    // Double-quoted or unquoted tokens: attempt plans-dir-constrained env-var resolution.
    {
      const stripped = t.replace(/^"|"$/g, "");
      const genericVarRe = /^\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))/;
      const gm = genericVarRe.exec(stripped);
      if (gm) {
        const varName = gm[1] || gm[2];
        const remainder = stripped.slice(gm[0].length);
        if (!remainder.includes("$") && !remainder.includes("`")) {
          const { tryResolveEnvUnderPlansDir } = require("./helpers");
          const resolved = tryResolveEnvUnderPlansDir(varName, remainder);
          if (resolved !== null) {
            targets.push(resolved);
            i++;
            continue;
          }
        }
      }
    }
    if (isUnresolvableToken(t)) return null;
    targets.push(t);
    i++;
  }
  return targets;
}

module.exports = { extractTeeTargets };
