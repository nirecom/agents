"use strict";

const { parse } = require("../command-ir");
const { resolveEffectiveCommand, resolveEffectiveArgv } = require("../bash-write-patterns/segment-utils");
const { expandRawToken, isUnresolvableToken, tryResolveEnvUnderPlansDir } = require("./helpers");

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

// Collect env-prefix KEY=VALUE pairs from the assignment run preceding the
// effective command. Only VALUE with no $, `, ( and no ../ traversal accepted.
function collectEnvPrefix(seg) {
  const env = {};
  const consider = [];
  if (ASSIGN_RE.test(seg.cmd0 || "")) {
    consider.push(seg.cmd0);
    for (const a of seg.argv) {
      if (ASSIGN_RE.test(a)) consider.push(a);
      else break;
    }
  }
  for (const tok of consider) {
    const km = /^([A-Za-z_][A-Za-z0-9_]*)=(\S*)$/.exec(tok);
    if (!km) continue;
    const value = km[2];
    if (value.includes("$") || value.includes("`") || value.includes("(")) continue;
    if (/(^|[\\/])\.\.([\\/]|$)/.test(value)) continue;
    env[km[1]] = value;
  }
  return env;
}

function substituteEnvPrefix(s, env) {
  let out = s;
  for (const key of Object.keys(env)) {
    const val = env[key];
    out = out.split("${" + key + "}").join(val);
    const re = new RegExp("\\$" + key + "(?![A-Za-z0-9_])", "g");
    out = out.replace(re, val);
  }
  return out;
}

/**
 * Extract the destination path of a POSIX cp or mv command from a SegmentIR.
 *
 * cp [flags] source... dest — returns last positional arg (destination)
 * mv [flags] source dest   — same
 *
 * Backward-compat: a raw command string is parsed and its cp/mv segment used.
 * Returns: string on success, null on parse failure (unresolvable token or
 * fewer than 2 positional args).
 */
function extractCpMvDestination(seg) {
  // Backward compat: accept a raw command string.
  if (typeof seg === "string") {
    const ir = parse(seg);
    if (!ir || ir.parseFailure) return null;
    const s = (ir.segments || []).find((x) => {
      const c = resolveEffectiveCommand(x);
      return c === "cp" || c === "mv";
    });
    if (!s) return null;
    seg = s;
  }
  if (!seg || !Array.isArray(seg.argvRaw)) return null;

  const effCmd = resolveEffectiveCommand(seg);
  if (effCmd !== "cp" && effCmd !== "mv") return null;

  const env = collectEnvPrefix(seg);
  const rawArgs = resolveRawArgvAfterEnvPrefix(seg);

  const positionals = [];
  for (const rawTok of rawArgs) {
    if (rawTok === "--") break;
    if (rawTok.startsWith("-")) continue;

    // Simple single-quoted: literal; fail-closed if it carries an unexpanded $.
    if (rawTok.startsWith("'") && rawTok.endsWith("'") && rawTok.length >= 2) {
      const lit = rawTok.slice(1, -1);
      if (lit.includes("$")) return null;
      positionals.push(lit);
      continue;
    }

    let resolved;
    if (rawTok.includes("$")) {
      // Try env-prefix substitution first (strip outer double-quotes for it).
      const stripped = rawTok.replace(/^"|"$/g, "");
      const substituted = substituteEnvPrefix(stripped, env);
      if (!isUnresolvableToken(substituted)) {
        resolved = substituted;
      } else {
        // Left an unresolved $VAR — try plans-dir-constrained process.env.
        const gm = /^\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))/.exec(substituted);
        if (gm) {
          const remainder = substituted.slice(gm[0].length);
          if (!remainder.includes("$") && !remainder.includes("`")) {
            const r = tryResolveEnvUnderPlansDir(gm[1] || gm[2], remainder);
            if (r !== null) resolved = r;
            else return null;
          } else return null;
        } else return null;
      }
    } else {
      resolved = expandRawToken(rawTok);
      if (resolved === null) return null;
    }
    positionals.push(resolved);
  }

  if (positionals.length < 2) return null;
  return positionals[positionals.length - 1];
}

// Operands of a cp/mv/ln argument list: the -t / --target-directory value and the positionals.
// The -S / --suffix value (backup suffix) is an option argument, never an operand.
function cpMvOperands(args) {
  let targetDir = null;
  const positionals = [];
  let options = true;
  for (let i = 0; i < args.length; i++) {
    const t = args[i];
    if (options && t === "--") { options = false; continue; }
    if (options && (/^-[A-Za-z]*t$/.test(t) || t === "--target-directory")) {
      if (i + 1 < args.length) targetDir = args[++i];
      continue;
    }
    if (options && (/^-[A-Za-z]*S$/.test(t) || t === "--suffix")) { i++; continue; }
    if (options && t.startsWith("--target-directory=")) { targetDir = t.slice("--target-directory=".length); continue; }
    if (options && /^-t./.test(t)) { targetDir = t.slice(2); continue; }
    if (options && t.startsWith("-") && t !== "-") continue;
    positionals.push(t);
  }
  return { targetDir, positionals };
}

function segmentRenameSources(seg) {
  if (!seg || resolveEffectiveCommand(seg) !== "mv") return [];
  const { targetDir, positionals } = cpMvOperands(resolveEffectiveArgv(seg));
  if (targetDir !== null) return positionals;
  return positionals.length >= 2 ? positionals.slice(0, positionals.length - 1) : [];
}

// The single implementation of "which files does a mv rename away" (a rename deletes each source
// from its directory). A SegmentIR yields its own sources; a command string yields the sources of
// every mv segment. [] when there is no mv, null on parse failure.
function extractRenameSources(seg) {
  if (typeof seg !== "string") return segmentRenameSources(seg);
  const ir = parse(seg);
  if (!ir || ir.parseFailure) return null;
  return (ir.segments || []).flatMap(segmentRenameSources);
}

module.exports = { extractCpMvDestination, extractRenameSources, cpMvOperands };
