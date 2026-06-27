"use strict";

const { isUnresolvableToken } = require("./helpers");

/**
 * Extract the destination path of a POSIX cp or mv command.
 *
 * cp [flags] source... dest — returns last positional arg (destination)
 * mv [flags] source dest   — same
 *
 * Returns: string on success, null on parse failure (unresolvable token or
 * fewer than 2 positional args).
 */
function extractCpMvDestination(cmd) {
  if (!cmd || typeof cmd !== "string") return null;

  const RE = /(?:^|[\s;|&])(?:cp|mv)\b(.*?)(?:$|[;|&](?:[^|&]|$))/s;
  const m = RE.exec(cmd);
  if (!m) return null;

  // Step A — Parse env-prefix tokens from the segment BEFORE `cp`/`mv`.
  // Only KEY=VALUE pairs where VALUE has no $, `, ( are accepted.
  // env-prefix only — process.env not consulted (#739)
  const envPrefix = {};
  const beforeRe = /(?:^|[\s;|&])(?:cp|mv)\b/;
  const beforeMatch = beforeRe.exec(cmd);
  if (beforeMatch) {
    const prefixRegion = cmd.slice(0, beforeMatch.index);
    const prefixTokens = prefixRegion.trim().split(/\s+/).filter(Boolean);
    for (const tok of prefixTokens) {
      const km = /^([A-Za-z_][A-Za-z0-9_]*)=(\S+)$/.exec(tok);
      if (!km) continue;
      const value = km[2];
      if (value.includes("$") || value.includes("`") || value.includes("(")) continue;
      // Reject ../ traversal in env-prefix values: a worktree-backup target
      // expressed via traversal is suspicious — fail-closed (#739 R9/R10).
      if (/(^|[\\/])\.\.([\\/]|$)/.test(value)) continue;
      envPrefix[km[1]] = value;
    }
  }

  // Substitute $KEY / ${KEY} using envPrefix only.
  function substituteEnvPrefix(s) {
    let out = s;
    for (const key of Object.keys(envPrefix)) {
      const val = envPrefix[key];
      out = out.split("${" + key + "}").join(val);
      // $KEY where the next char is not a word char (or end).
      const re = new RegExp("\\$" + key + "(?![A-Za-z0-9_])", "g");
      out = out.replace(re, val);
    }
    return out;
  }

  // Strip surrounding quotes from a single token. Returns { stripped, wasDoubleQuoted }.
  function stripOuterQuotes(t) {
    if (t.length >= 2) {
      if (t[0] === '"' && t[t.length - 1] === '"') {
        return { stripped: t.slice(1, -1), wasDoubleQuoted: true };
      }
      if (t[0] === "'" && t[t.length - 1] === "'") {
        return { stripped: t.slice(1, -1), wasDoubleQuoted: false, wasSingleQuoted: true };
      }
    }
    return { stripped: t, wasDoubleQuoted: false };
  }

  const tokens = m[1].trim().split(/\s+/).filter(Boolean);
  const positionals = [];
  for (const t of tokens) {
    if (t === "--") break;
    if (t.startsWith("-")) continue;

    // Step B — Substitute env-prefix in ALL positionals (source and destination).
    let resolved = t;
    if (t.includes("$")) {
      // Strip outer quotes so substitution can target the inner content.
      const { stripped, wasSingleQuoted } = stripOuterQuotes(t);
      // Single-quoted tokens: never expand — fail-closed if $ present.
      if (wasSingleQuoted) {
        if (stripped.includes("$")) return null;
        resolved = stripped;
      } else {
        const substituted = substituteEnvPrefix(stripped);
        if (isUnresolvableToken(substituted)) {
          // env-prefix substitution left an unresolved $VAR — try process.env
          // constrained to plans-dir (mirrors tee.js:48-65 pattern).
          const genericVarRe = /^\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))/;
          const gm = genericVarRe.exec(substituted);
          if (gm) {
            const varName = gm[1] || gm[2];
            const remainder = substituted.slice(gm[0].length);
            if (!remainder.includes("$") && !remainder.includes("`")) {
              const { tryResolveEnvUnderPlansDir } = require("./helpers");
              const r = tryResolveEnvUnderPlansDir(varName, remainder);
              if (r !== null) { resolved = r; }
              else return null;
            } else { return null; }
          } else { return null; }
        } else {
          resolved = substituted;
        }
      }
    } else {
      // No $ — still strip outer quotes for consistency.
      const { stripped } = stripOuterQuotes(t);
      resolved = stripped;
      if (isUnresolvableToken(resolved)) return null;
    }
    positionals.push(resolved);
  }
  if (positionals.length < 2) return null;
  return positionals[positionals.length - 1];
}

module.exports = { extractCpMvDestination };
