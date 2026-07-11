"use strict";

const { parse } = require("../command-ir");
const { expandRawToken, isUnresolvableToken, tryResolveEnvUnderPlansDir } = require("./helpers");

const ASSIGN_RE = /^[A-Za-z_][A-Za-z0-9_]*=/;

// Return the RAW argv tokens that follow the env-prefix (VAR=val) run and the
// effective command. Mirrors resolveEffectiveArgv() but on the raw (pre-strip)
// argv so downstream expansion can decide the quote context.
function resolveRawArgvAfterEnvPrefix(seg) {
  if (!seg || !Array.isArray(seg.argv) || !Array.isArray(seg.argvRaw)) return [];
  const skipCmd = ASSIGN_RE.test(seg.cmd0 || "");
  if (!skipCmd) return seg.argvRaw.slice();
  const idx = seg.argv.findIndex((a) => !ASSIGN_RE.test(a));
  if (idx === -1) return [];
  return seg.argvRaw.slice(idx + 1);
}

/**
 * Extract tee write targets from a SegmentIR.
 *
 * Handles: tee [flags] file1 [file2 ...]
 * Skips:   -a/--append/-i/-p/--ignore-interrupts flags and any other -flag.
 * Backward-compat: a raw command string is parsed and its tee segment used.
 * Returns: string[] on success, null on parse failure.
 */
function extractTeeTargets(seg) {
  // Backward compat: accept a raw command string.
  if (typeof seg === "string") {
    // Process substitution in tee args → fail-closed (IR decomposes >(...) into a
    // separate subshell segment, so detect it on the raw string before parsing).
    if (/tee\s[^;|&]*>\s*\(/.test(seg)) return null;
    const ir = parse(seg);
    if (!ir || ir.parseFailure) return null;
    const { resolveEffectiveCommand } = require("../bash-write-patterns/segment-utils");
    const s = (ir.segments || []).find((x) => resolveEffectiveCommand(x) === "tee");
    if (!s) return [];
    seg = s;
  }
  if (!seg || !Array.isArray(seg.argvRaw)) return null;

  const rawArgs = resolveRawArgvAfterEnvPrefix(seg);
  const targets = [];
  for (const rawTok of rawArgs) {
    if (rawTok.startsWith(">(")) return null;       // process substitution
    if (rawTok === "-a" || rawTok === "--append" || rawTok === "-i" ||
        rawTok === "-p" || rawTok === "--ignore-interrupts") continue;
    if (rawTok.startsWith("-")) continue;

    // Simple single-quoted literal: content is verbatim (POSIX single-quote
    // never expands $), so push as-is — bypass the unresolvable-$VAR skip.
    if (rawTok.startsWith("'") && rawTok.endsWith("'") && rawTok.length >= 2) {
      targets.push(rawTok.slice(1, -1));
      continue;
    }

    let expanded = expandRawToken(rawTok);
    if (expanded === null) {
      // Fallback: plans-dir-constrained env resolution on the stripped form.
      const stripped = rawTok.replace(/^["']|["']$/g, "");
      const gm = /^\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))/.exec(stripped);
      if (gm) {
        const remainder = stripped.slice(gm[0].length);
        if (!remainder.includes("$") && !remainder.includes("`")) {
          expanded = tryResolveEnvUnderPlansDir(gm[1] || gm[2], remainder);
        }
      }
    }
    if (expanded === null) return null;             // fail-closed
    if (isUnresolvableToken(expanded)) continue;
    targets.push(expanded);
  }
  return targets;
}

module.exports = { extractTeeTargets };
