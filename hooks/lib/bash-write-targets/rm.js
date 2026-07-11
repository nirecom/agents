"use strict";

const { parse } = require("../command-ir");
const { resolveEffectiveCommand } = require("../bash-write-patterns/segment-utils");
const { expandRawToken, isUnresolvableToken } = require("./helpers");

const ASSIGN_RE = /^[A-Za-z_][A-Za-z0-9_]*=/;

// Return the RAW argv tokens that follow the env-prefix (VAR=val) run and the
// effective command.
function resolveRawArgvAfterEnvPrefix(seg) {
  if (!seg || !Array.isArray(seg.argv) || !Array.isArray(seg.argvRaw)) return [];
  const skipCmd = ASSIGN_RE.test(seg.cmd0 || "");
  if (!skipCmd) return seg.argvRaw.slice();
  const idx = seg.argv.findIndex((a) => !ASSIGN_RE.test(a));
  if (idx === -1) return [];
  return seg.argvRaw.slice(idx + 1);
}

/**
 * Extract POSIX rm targets from a SegmentIR.
 *
 * rm [flags] path... — returns all positional (non-flag) args.
 * `--` ends flag parsing: every token after it is a positional.
 *
 * Backward-compat: a raw command string is parsed and its rm segment used.
 * Returns: string[] on success (may be empty), null on parse failure
 *   (unresolvable token via $VAR / $(...) / backticks, single-quote fail-closed).
 */
function extractRmTargets(seg) {
  // Backward compat: accept a raw command string.
  if (typeof seg === "string") {
    const ir = parse(seg);
    if (!ir || ir.parseFailure) return null;
    const s = (ir.segments || []).find((x) => resolveEffectiveCommand(x) === "rm");
    if (!s) return null;
    seg = s;
  }
  if (!seg || !Array.isArray(seg.argvRaw)) return null;
  if (resolveEffectiveCommand(seg) !== "rm") return null;

  const rawArgv = resolveRawArgvAfterEnvPrefix(seg);
  const positionals = [];
  let sawDashDash = false;
  for (const rawTok of rawArgv) {
    if (!sawDashDash && rawTok === "--") { sawDashDash = true; continue; }
    if (!sawDashDash && rawTok.startsWith("-")) continue;

    // Simple single-quoted: literal content, no expansion.
    if (rawTok.startsWith("'") && rawTok.endsWith("'") && rawTok.length >= 2) {
      const lit = rawTok.slice(1, -1);
      if (lit.includes("$")) return null;
      if (lit === "") continue;
      positionals.push(lit);
      continue;
    }

    const expanded = expandRawToken(rawTok);
    if (expanded === null) return null;             // fail-closed
    if (isUnresolvableToken(expanded)) continue;
    if (expanded === "") continue;
    positionals.push(expanded);
  }
  return positionals;
}

module.exports = { extractRmTargets };
