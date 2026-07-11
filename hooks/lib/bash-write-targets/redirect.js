"use strict";

const { expandStaticShellTokens, expandRawToken } = require("./helpers");

/**
 * Extract POSIX redirect write targets from a SegmentIR.
 *
 * Reads seg.redirects[] directly (post-#1295 IR migration).
 * Backward-compat: a raw command string is parsed into its first redirect-bearing
 * segment so pre-migration string callers keep working.
 * Handles: > file, >> file, N> file, N>> file, &> file
 * Skips:   read redirects (<, <<<), FD-to-FD redirects (2>&1), /dev/null sinks.
 * Returns: string[] on success, null on parse failure (unresolvable token).
 */
function extractRedirectTargets(seg) {
  // Backward compat: accept a raw command string.
  if (typeof seg === "string") {
    const { parse } = require("../command-ir");
    const ir = parse(seg);
    if (!ir || ir.parseFailure) return null;
    const s = (ir.segments || []).find((x) => (x.redirects || []).some((r) => r.op !== "<" && r.op !== "<<<")) || ir.segments[0];
    seg = s;
  }
  if (!seg || !Array.isArray(seg.redirects)) return null;

  const targets = [];
  for (const r of seg.redirects) {
    if (r.op === "<" || r.op === "<<<") continue;   // read redirects — not writes
    if (r.target === "") continue;                  // empty target (`> `)
    if (/^&\d/.test(r.target)) continue;            // FD-to-FD (e.g. 2>&1 → target "&1")
    const expanded = expandRawToken(r.targetRaw);
    if (expanded === null) return null;             // unresolvable → fail-closed
    if (expanded === "/dev/null" || expanded.endsWith("/dev/null")) continue; // null-sink
    targets.push(expanded);
  }
  return targets;
}

module.exports = { extractRedirectTargets, expandStaticShellTokens };
