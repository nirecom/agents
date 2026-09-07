"use strict";
// Exotic execution-bearing constructs (eval / xargs / find action clauses) plus
// interpreter `-c` bodies. Parent-owned helpers arrive via `deps` because
// requiring them back from the parent would form a module cycle.

const { resolveEffectiveCommand, resolveEffectiveArgv, commandBasename, ASSIGN_RE, peelWrappersUntil } = require("../bash-write-patterns/segment-utils");

// xargs is a registered WRAPPER_SPECS wrapper; stop peeling there so this module
// still sees "xargs" itself and can apply its own dynamic-arg handling.
const EXOTIC_STOP_BASENAMES = new Set(["xargs"]);

function resolveExoticHead(seg) {
  if (!seg || seg.cmd0 == null) return { cmd0: null, argv: [] };
  let cmd0 = seg.cmd0;
  let argv = Array.isArray(seg.argv) ? seg.argv : [];
  if (ASSIGN_RE.test(cmd0)) {
    const idx = argv.findIndex((a) => !ASSIGN_RE.test(a));
    if (idx === -1) return { cmd0: null, argv: [] };
    cmd0 = argv[idx];
    argv = argv.slice(idx + 1);
  }
  const peeled = peelWrappersUntil(cmd0, argv, EXOTIC_STOP_BASENAMES);
  return { cmd0: peeled.cmd0, argv: peeled.argv };
}

// A write can hide as an ARGUMENT to eval / xargs / find -exec rather than as
// its own IR segment. Dynamic or unparseable bodies fail closed to WRITE.
const EVAL_RE = /^eval$/;
const XARGS_RE = /^xargs$/;
const FIND_RE = /^find$/;

function looksDynamic(tok) {
  return typeof tok === "string" && (/\$/.test(tok) || /`/.test(tok));
}

// Read-only env emitters safe to `eval "$(…)"`. Every pattern must stay anchored
// to prevent prefix attacks; multi-segment bodies never match by regex design.
const EVAL_SUBST_READ_ALLOWLIST = [
  /^ssh-agent\b(?:\s+-[sack\d])?\s*$/,
  /^fnm\s+env\b(?:\s+--[a-z][-a-z0-9]*(?:=[^\s]*)?)?\s*$/,
  /^direnv\s+hook\s+(?:bash|zsh|fish|tcsh|elvish|nu)\s*$/,
  /^nvm\s+(?:use|env)\b(?:\s+[^\s]*)?\s*$/,
];

function evalSubstIsAllowlistedRead(inner) {
  const t = inner.trim();
  return EVAL_SUBST_READ_ALLOWLIST.some((re) => re.test(t));
}

// "opaque" means an expansion outside the allowlist, which the caller fails closed on.
function expansionDisposition(tok) {
  if (typeof tok !== "string") return "opaque";
  if (!looksDynamic(tok)) return "static";
  const m = tok.match(/^\$\(([^)]*)\)$/);
  if (m && evalSubstIsAllowlistedRead(m[1])) return "allowlisted-read";
  return "opaque";
}

// The concatenation of eval's arguments is re-executed by the shell, so the body
// is reconstructed from the resolved argv and checked against the RAW argv too.
function evalSegmentIsWrite(seg, deps, argv) {
  if (!Array.isArray(argv) || argv.length === 0) return false; // bare `eval` — no body
  const rawArgv = deps.resolveRawArgvAfterEnvPrefix(seg);

  let anyAllowlisted = false;
  for (const tok of argv) {
    const disp = expansionDisposition(tok);
    if (disp === "opaque") return true;
    if (disp === "allowlisted-read") anyAllowlisted = true;
  }

  // Dynamic content the argv loop above could not see (an expansion left in
  // env-prefix position) fails closed.
  const argvHasDynamic = argv.some(looksDynamic);
  if ((rawArgv || []).some(looksDynamic) && !argvHasDynamic) return true;

  // An allowlisted emitter decides the body at runtime — no static analysis left.
  if (anyAllowlisted) return false;

  const body = argv.join(" ").trim();
  if (!body) return false;
  return deps.innerCommandIsWrite(body, deps.isCommandSubstWriteIR);
}

// The target is the COMMAND xargs runs, so its own value-taking and boolean
// options must be skipped first.
const XARGS_VALUE_FLAGS = new Set(["-I", "-i", "-n", "-P", "-d", "-a", "-E", "-e", "-L", "-l", "-s", "--replace", "--max-lines", "--max-args", "--max-procs", "--delimiter", "--arg-file", "--eof", "--max-chars"]);
function xargsCommandTokens(argv) {
  let i = 0;
  while (i < argv.length) {
    const tok = argv[i];
    if (typeof tok !== "string") return null; // fail-closed
    if (tok === "--") { i += 1; break; }
    if (tok[0] === "-") {
      const eq = tok.indexOf("=");
      if (eq !== -1) { i += 1; continue; }
      // Attached short-option value forms: -I{}, -n1, -P4, -s1024.
      if (/^-[IinPdaEeLls]./.test(tok)) { i += 1; continue; }
      if (XARGS_VALUE_FLAGS.has(tok)) { i += 2; continue; } // flag + separate value
      i += 1; continue;
    }
    break; // first non-flag token = the command
  }
  return i < argv.length ? argv.slice(i) : null;
}
function xargsSegmentIsWrite(seg, deps, argv) {
  if (!Array.isArray(argv)) return false;
  const cmdTokens = xargsCommandTokens(argv);
  if (!cmdTokens || cmdTokens.length === 0) return false; // no explicit command
  // Only the COMMAND token is dynamic-checked: later tokens are data the outer
  // shell expands before xargs runs, so failing closed on them over-blocks.
  if (looksDynamic(cmdTokens[0])) return true;
  return deps.innerCommandIsWrite(cmdTokens.join(" "), deps.isCommandSubstWriteIR);
}

// The IR tokenizer strips the escape from `\;`, leaving a bare `\` or `;`, so the
// collected -exec command terminates at `;`, `\`, or `+`.
function findSegmentIsWrite(seg, deps, argv) {
  if (!Array.isArray(argv)) return false;
  for (let i = 0; i < argv.length; i++) {
    const tok = argv[i];
    if (typeof tok !== "string") continue;
    if (tok === "-delete") return true;
    if (tok === "-exec" || tok === "-execdir" || tok === "-ok" || tok === "-okdir") {
      const cmdToks = [];
      let j = i + 1;
      for (; j < argv.length; j++) {
        const t = argv[j];
        if (t === ";" || t === "\\" || t === "+") break;
        cmdToks.push(t);
      }
      if (cmdToks.length === 0) return true; // malformed action clause → fail-closed
      // `{}` is the matched path, not part of the command.
      const clean = cmdToks.filter((t) => t !== "{}");
      if (clean.length === 0) return true;   // only placeholders → fail-closed
      // Only the COMMAND token is dynamic-checked; see xargsSegmentIsWrite.
      if (looksDynamic(clean[0])) return true;
      if (deps.innerCommandIsWrite(clean.join(" "), deps.isCommandSubstWriteIR)) return true;
      i = j; // continue scanning after this action clause
    }
  }
  return false;
}

// Interpreters whose inline `-c` body is re-parsed for writes; any ambiguous
// form fails closed to write.
const INTERP_NAMES = new Set(["bash", "sh", "zsh", "dash", "fish", "pwsh", "powershell", "cmd"]);

// interpBase must already be lowercased and .exe-stripped.
function hasCFlag(argv, interpBase) {
  return argv.some((a) => {
    const al = a.toLowerCase();
    if (interpBase === "cmd") return al === "/c";
    if (interpBase === "pwsh" || interpBase === "powershell")
      return al === "-c" || al === "-command" || al === "-encodedcommand";
    // POSIX shells also combine the flag: -lc, -xc.
    return al === "-c" || (a.startsWith("-") && !a.startsWith("--") && a.slice(1).includes("c"));
  });
}

function isInterpreterCWriteIR(ir) {
  if (!ir || ir.parseFailure === true) return false;
  if (!ir.segments) return false;
  for (const seg of ir.segments) {
    const eff = resolveEffectiveCommand(seg);
    if (eff == null) continue;
    const base = commandBasename(eff);
    if (base == null) continue;
    const interpBase = base.toLowerCase().replace(/\.exe$/i, "");
    if (!INTERP_NAMES.has(interpBase)) continue;
    const argv = resolveEffectiveArgv(seg);
    if (!argv || !hasCFlag(argv, interpBase)) continue;
    // Lazy require to break the classify.js ↔ bash-write-targets.js cycle.
    let isReadOnlyInterpreterC;
    try {
      ({ isReadOnlyInterpreterC } = require("../bash-write-patterns/classify"));
    } catch (_) { return true; } // fail-closed if classify unavailable
    if (typeof isReadOnlyInterpreterC !== "function") return true;
    const rawText = seg.rawText || argv.join(" ");
    if (!isReadOnlyInterpreterC(rawText)) return true;
  }
  return false;
}

function isExoticExecWriteIR(ir, deps) {
  // Every sibling module exports a single-arg predicate, so a caller may drop
  // `deps`. enforce-worktree.js does not catch throws — a missing dep would
  // fail OPEN on exactly the commands this predicate blocks.
  if (
    !deps ||
    typeof deps.innerCommandIsWrite !== "function" ||
    typeof deps.isCommandSubstWriteIR !== "function" ||
    typeof deps.resolveRawArgvAfterEnvPrefix !== "function"
  ) {
    return true;
  }
  if (!ir || ir.parseFailure === true) return false;
  if (!ir.segments) return false;
  for (const seg of ir.segments) {
    const head = resolveExoticHead(seg);
    const base = head.cmd0 != null ? commandBasename(head.cmd0) : null;
    if (base == null) continue;
    if (EVAL_RE.test(base) && evalSegmentIsWrite(seg, deps, head.argv)) return true;
    if (XARGS_RE.test(base) && xargsSegmentIsWrite(seg, deps, head.argv)) return true;
    if (FIND_RE.test(base) && findSegmentIsWrite(seg, deps, head.argv)) return true;
  }
  return false;
}

module.exports = {
  isExoticExecWriteIR,
  isInterpreterCWriteIR,
};
