"use strict";

const { parse } = require("../command-ir");
const {
  resolveEffectiveCommand,
  commandBasename,
  peelWrappersRaw,
  scanWrappedVerb,
  ASSIGN_RE,
} = require("../bash-write-patterns/segment-utils");
const { expandRawToken, isUnresolvableToken } = require("./helpers");

// Strip shell quoting/escaping so a flag hidden behind it still classifies:
// `"-rf"`, `'-rf'`, `-"rf"`, `""-rf`, `\-rf`, `-\rf` all reduce to `-rf`
// (#2210 F2). Bash brace expansion (`-{r,f}`) is a distinct, lexical-only
// mechanism this does not simulate — an accepted residual gap, not silently
// dropped: see docs/security-policy.md's "Known residual gaps" section for
// the canonical, up-to-date inventory of what this hook does and does not cover.
function dequoteShellToken(raw) {
  if (typeof raw !== "string") return "";
  let out = "";
  let i = 0;
  let inSingle = false;
  let inDouble = false;
  while (i < raw.length) {
    const ch = raw[i];
    if (inSingle) {
      if (ch === "'") { inSingle = false; i += 1; continue; }
      out += ch; i += 1; continue;
    }
    if (inDouble) {
      if (ch === '"') { inDouble = false; i += 1; continue; }
      if (ch === "\\" && i + 1 < raw.length && "\"\\$`".includes(raw[i + 1])) {
        out += raw[i + 1]; i += 2; continue;
      }
      out += ch; i += 1; continue;
    }
    if (ch === "'") { inSingle = true; i += 1; continue; }
    if (ch === '"') { inDouble = true; i += 1; continue; }
    if (ch === "\\" && i + 1 < raw.length) { out += raw[i + 1]; i += 2; continue; }
    out += ch; i += 1;
  }
  return out;
}

// Strip a leading `NAME=VALUE...` env-prefix from a segment's {cmd0, argv} AND
// its raw counterparts in lockstep (command-ir.js's argv/argvRaw positional
// invariant) — the peel step below needs both forms of the real command.
function stripEnvPrefix(seg) {
  let cmd0 = seg.cmd0;
  let cmd0Raw = typeof seg.cmd0Raw === "string" ? seg.cmd0Raw : seg.cmd0;
  let argv = Array.isArray(seg.argv) ? seg.argv : [];
  let argvRaw =
    Array.isArray(seg.argvRaw) && seg.argvRaw.length === argv.length ? seg.argvRaw : argv.slice();
  if (ASSIGN_RE.test(cmd0)) {
    const idx = argv.findIndex((a) => !ASSIGN_RE.test(a));
    if (idx === -1) return null;
    cmd0 = argv[idx];
    cmd0Raw = argvRaw[idx];
    argv = argv.slice(idx + 1);
    argvRaw = argvRaw.slice(idx + 1);
  }
  return { cmd0, cmd0Raw, argv, argvRaw };
}

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

/**
 * isRecursiveRmFlagToken(tok) — classify ONE `-`-leading rm token (#2210).
 * true = requests recursion; null = flag content unresolvable, caller fails
 * closed; false = anything else (incl. a `${VAR:-default}` whose default is
 * itself flag-shaped, #2210 N5). Split out for CPR-SSOT reuse by the
 * assignment-value judgment in recursive-delete-scan.js. Contract: detail.md Step 1.
 */
const PARAM_DEFAULT_RE = /^\$\{[A-Za-z_][A-Za-z0-9_]*:?-([\s\S]*)\}$/;
// Sibling parameter-expansion operators (`:=`/`=`, `:+`/`+`, `:?`/`?`, `//`/`/`)
// are not default-value forms, but their operand can still be flag-shaped or
// itself unresolvable (#2210 F4) — matched broadly so any of them fails
// closed on an unresolvable operand rather than silently returning false.
const PARAM_EXPANSION_RE = /^\$\{[A-Za-z_][A-Za-z0-9_]*(?::?[-=?+]|\/\/?)([\s\S]*)\}$/;

function isRecursiveRmFlagToken(tok) {
  if (typeof tok !== "string" || tok === "") return false;
  const deq = dequoteShellToken(tok);
  if (!deq.startsWith("-")) {
    const m = PARAM_DEFAULT_RE.exec(deq);
    if (m) {
      const def = m[1];
      if (def.includes("$") || def.includes("`") || def.includes("(")) return null;
      return isRecursiveRmFlagToken(def);
    }
    const m2 = PARAM_EXPANSION_RE.exec(deq);
    if (m2) {
      const operand = m2[1];
      if (operand.includes("$") || operand.includes("`") || operand.includes("(")) return null;
      return isRecursiveRmFlagToken(operand);
    }
    return false;
  }
  if (tok.includes("$") || tok.includes("`") || tok.includes("(")) return null;
  if (deq.startsWith("--")) {
    const name = deq.slice(2).split("=")[0];
    if (name.length >= 1 && "recursive".startsWith(name)) return true;
  } else {
    const m = /^-([A-Za-z]+)/.exec(deq);
    if (m && /[rR]/.test(m[1])) return true;
  }
  return false;
}

/**
 * hasRecursiveRmFlag(seg) — does this POSIX `rm` segment request recursion?
 * Same three-value contract; structure mirrors extractRmTargets (string
 * back-compat entry, env-prefix-stripped RAW argv, `--` ends flag parsing).
 * Only `-`-leading tokens are classified: a bare token is a TARGET, and failing
 * closed on those would break the everyday `rm "$file"`. Command test is by
 * BASENAME so `/bin/rm` / `rm.exe` resolve. Contract: detail.md Step 1.
 */
function hasRecursiveRmFlag(seg) {
  if (typeof seg === "string") {
    const ir = parse(seg);
    if (!ir || ir.parseFailure) return false;
    const s = (ir.segments || []).find((x) => commandBasename(resolveEffectiveCommand(x)) === "rm");
    if (!s) return false;
    seg = s;
  }
  if (!seg || !Array.isArray(seg.argvRaw)) return false;

  const stripped = stripEnvPrefix(seg);
  if (!stripped) return false;
  const peeled = peelWrappersRaw(stripped.cmd0, stripped.cmd0Raw, stripped.argv, stripped.argvRaw);
  // An unclassifiable wrapper option must fail closed ONLY when an `rm` is
  // actually hiding somewhere in the wrapper's raw argv (#2210 F4/N4) — an
  // ambiguous option on an unrelated wrapped command (`nice -5 npm test`)
  // must not itself become a block, or every unclassified wrapper flag turns
  // into a universal deny regardless of what it wraps.
  if (peeled.ambiguous) {
    const wrapperSeg = { cmd0: stripped.cmd0, argv: stripped.argv };
    return scanWrappedVerb(wrapperSeg, (tok) => commandBasename(tok) === "rm") ? null : false;
  }
  if (commandBasename(peeled.cmd0) !== "rm") return false;

  for (const rawTok of peeled.argvRaw) {
    if (typeof rawTok !== "string") continue;
    if (rawTok === "--") break;
    const verdict = isRecursiveRmFlagToken(rawTok);
    if (verdict === true) return true;
    if (verdict === null) return null;
  }
  return false;
}

module.exports = { extractRmTargets, hasRecursiveRmFlag, isRecursiveRmFlagToken };
