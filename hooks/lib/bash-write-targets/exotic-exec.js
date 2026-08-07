"use strict";
// hooks/lib/bash-write-targets/exotic-exec.js
// Exotic execution-bearing constructs (eval / xargs / find action clauses) plus
// interpreter `-c` bodies. Extracted verbatim from bash-write-targets.js (Pattern A
// file split); behavior is unchanged.
//
// The parent-owned helpers these predicates need (innerCommandIsWrite,
// isCommandSubstWriteIR, resolveRawArgvAfterEnvPrefix) are INJECTED via the `deps`
// argument rather than required back from the parent — a `require` in that direction
// would form a module cycle. This mirrors the existing `innerCommandIsWrite(inner,
// recurse)` callback style.

const { resolveEffectiveCommand, resolveEffectiveArgv, commandBasename } = require("../bash-write-patterns/segment-utils");

// --- Exotic execution-bearing constructs (FINAL shell-layer round) ----------
// A finite set of constructs where a write can hide from the per-segment IR
// predicates because the WRITE verb is carried as an ARGUMENT to another
// command (eval / xargs / find -exec) rather than surfacing as its own segment.
// Design posture (user-approved): re-parse the inner/target command where
// statically feasible → inner write ⇒ whole command is WRITE; DYNAMIC (a
// variable-driven / `$`-bearing body) or UNPARSEABLE ⇒ FAIL-CLOSED (WRITE).
// Genuinely static inner READS stay allowed (no blanket block).
//
// NOT covered here because the IR parser ALREADY exposes them as segments:
//   - process substitution `<(cmd)` / `>(cmd)` — parse() emits the inner cmd as
//     its own segment, so isFileOpWriteIR / isGitWriteIR / … see it directly.
//   - `bash|sh|dash|pwsh -c/-Command "<body>"` — classify()/isReadOnlyInterpreterC
//     re-parse the inner body and fail-closed on an inner write.
// This predicate is the residual: eval, xargs, and find action clauses.

const EVAL_RE = /^eval$/;
const XARGS_RE = /^xargs$/;
const FIND_RE = /^find$/;

// True when a token looks DYNAMIC — it carries an unexpanded shell expansion
// (`$VAR`, `${VAR}`, `$(...)`, backtick) whose runtime value we cannot know
// statically. Such an eval/find/xargs body is fail-closed to WRITE.
function looksDynamic(tok) {
  return typeof tok === "string" && (/\$/.test(tok) || /`/.test(tok));
}

// Known read-only env-emitter commands safe to `eval "$(…)"` (#1679 S-4).
// Only exact single-command forms are allowlisted; multi-segment bodies
// (`;`, `&&`, `||`) fail ALLOWLIST_MATCH by regex design (they contain `;`/`&`/`|`).
// Each pattern must be anchored (^ … $) to prevent prefix attacks.
const EVAL_SUBST_READ_ALLOWLIST = [
  // ssh-agent -s / -c : outputs shell variable assignments (SSH_AUTH_SOCK etc.)
  /^ssh-agent\b(?:\s+-[sack\d])?\s*$/,
  // fnm env : outputs eval-able environment setup for node version management
  /^fnm\s+env\b(?:\s+--[a-z][-a-z0-9]*(?:=[^\s]*)?)?\s*$/,
  // direnv hook <shell> : outputs shell-specific eval hook, read-only
  /^direnv\s+hook\s+(?:bash|zsh|fish|tcsh|elvish|nu)\s*$/,
  // nvm use / nvm env (common nvm idioms used in scripts)
  /^nvm\s+(?:use|env)\b(?:\s+[^\s]*)?\s*$/,
];

// True when the inner cmdsubst body matches a known read-only env emitter.
function evalSubstIsAllowlistedRead(inner) {
  const t = inner.trim();
  return EVAL_SUBST_READ_ALLOWLIST.some((re) => re.test(t));
}

// 3-value expansion disposition for a single resolved token (#1679 S-4):
//   "static"           — no shell expansion (`$`, backtick) in token
//   "allowlisted-read" — expansion is a known safe env-emitter `$(…)`
//   "opaque"           — expansion present but not in allowlist → fail-closed
function expansionDisposition(tok) {
  if (typeof tok !== "string") return "opaque";
  if (!looksDynamic(tok)) return "static";
  // Check for pure $(…) cmdsubst form (whole token = a single cmdsubst)
  const m = tok.match(/^\$\(([^)]*)\)$/);
  if (m && evalSubstIsAllowlistedRead(m[1])) return "allowlisted-read";
  return "opaque";
}

// eval BODY... : the concatenation of eval's arguments is re-executed by the
// shell. Reconstruct the body from the resolved argv (already unquoted) and the
// RAW argv (to detect `$`-dynamic bodies). Static body → re-parse via
// innerCommandIsWrite; allowlisted-read env-emitters → treat as read;
// opaque/unknown → fail-closed WRITE.
function evalSegmentIsWrite(seg, deps) {
  const argv = resolveEffectiveArgv(seg);
  if (!Array.isArray(argv) || argv.length === 0) return false; // bare `eval` — no body
  const rawArgv = deps.resolveRawArgvAfterEnvPrefix(seg);

  // Check resolved argv tokens for expansion disposition.
  // "opaque" (unknown dynamic) → fail-closed immediately.
  let anyAllowlisted = false;
  for (const tok of argv) {
    const disp = expansionDisposition(tok);
    if (disp === "opaque") return true;
    if (disp === "allowlisted-read") anyAllowlisted = true;
  }

  // Belt-and-suspenders: if rawArgv has dynamic content that argv did not
  // (argv resolution missed an expansion in env-prefix position), fail-closed —
  // unless argv also carries the same dynamic content (DQ-wrapped cmdsubst already
  // handled above by the argv loop).
  const argvHasDynamic = argv.some(looksDynamic);
  if ((rawArgv || []).some(looksDynamic) && !argvHasDynamic) return true;

  // If any token is a known allowlisted env-emitter, the eval body is determined
  // at runtime by that emitter (e.g. ssh-agent -s → SSH_AUTH_SOCK=…; export …).
  // No further static analysis is possible or needed — treat as read.
  if (anyAllowlisted) return false;

  // All static: re-parse the static body for writes.
  const body = argv.join(" ").trim();
  if (!body) return false;
  return deps.innerCommandIsWrite(body, deps.isCommandSubstWriteIR);
}

// xargs [xargs-opts] COMMAND [args] : the COMMAND xargs runs is the target.
// Skip xargs's own option flags (value-taking and boolean), then re-parse the
// remainder as a command. No command token (pure `xargs`) → not a write here.
const XARGS_VALUE_FLAGS = new Set(["-I", "-i", "-n", "-P", "-d", "-a", "-E", "-e", "-L", "-l", "-s", "--replace", "--max-lines", "--max-args", "--max-procs", "--delimiter", "--arg-file", "--eof", "--max-chars"]);
function xargsCommandTokens(argv) {
  let i = 0;
  while (i < argv.length) {
    const tok = argv[i];
    if (typeof tok !== "string") return null; // non-string token — fail-closed
    if (tok === "--") { i += 1; break; }
    if (tok[0] === "-") {
      const eq = tok.indexOf("=");
      if (eq !== -1) { i += 1; continue; }          // --flag=value (self-contained)
      // Attached short-option value forms: -I{}, -n1, -d, , -P4, -s1024.
      if (/^-[IinPdaEeLls]./.test(tok)) { i += 1; continue; }
      if (XARGS_VALUE_FLAGS.has(tok)) { i += 2; continue; } // flag + separate value
      i += 1; continue;                              // boolean flag (-0, -r, -t, -p, …)
    }
    break; // first non-flag token = the command
  }
  return i < argv.length ? argv.slice(i) : null;
}
function xargsSegmentIsWrite(seg, deps) {
  const argv = resolveEffectiveArgv(seg);
  if (!Array.isArray(argv)) return false;
  const cmdTokens = xargsCommandTokens(argv);
  if (!cmdTokens || cmdTokens.length === 0) return false; // no explicit command
  // Only the COMMAND token (cmdTokens[0]) is subject to the dynamic fail-closed check.
  // Argument tokens (cmdTokens[1+]) are data passed by the outer shell before xargs runs
  // (#1679 S-5 CPR-ORTH): `$(git rev-parse …)` in a grep arg is not an xargs-executed command.
  if (looksDynamic(cmdTokens[0])) return true;
  return deps.innerCommandIsWrite(cmdTokens.join(" "), deps.isCommandSubstWriteIR);
}

// find ... action-clause : `-delete` is itself a write; `-exec`/`-execdir`/
// `-ok`/`-okdir` <cmd> ... {\; | +} runs <cmd> per match — re-parse that <cmd>.
// The IR tokenizer strips the escape from `\;` leaving a bare `\` or `;`
// terminator token, so terminate the collected command at `;`, `\`, or `+`.
function findSegmentIsWrite(seg, deps) {
  const argv = resolveEffectiveArgv(seg);
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
      // Drop the `{}` placeholder tokens — they are the matched path, not command.
      const clean = cmdToks.filter((t) => t !== "{}");
      if (clean.length === 0) return true;   // only placeholders → fail-closed
      // Only the COMMAND token (clean[0]) is subject to the dynamic fail-closed check.
      // Argument tokens (clean[1+]) are data the outer shell expands before find runs
      // (#1679 S-5 CPR-ORTH): `$(date +%F)` in a grep arg is not a find-executed command.
      if (looksDynamic(clean[0])) return true;
      if (deps.innerCommandIsWrite(clean.join(" "), deps.isCommandSubstWriteIR)) return true;
      i = j; // continue scanning after this action clause
    }
  }
  return false;
}

// True when any segment is a shell/interpreter invocation with a -c/-Command/-EncodedCommand/\/c
// flag AND the inline body contains a write. This retires the "interpreter-c" WRITE_PATTERNS
// entry (#1411 canary-6a) and provides IR-based re-parse of the body.
// Fail-closed: any unrecognized/ambiguous form returns true (treats as write).
// CIRCULAR DEPENDENCY NOTE: isReadOnlyInterpreterC (classify.js) is lazy-required inside
// this function to avoid classify.js → bash-write-targets.js → classify.js cycle.
const INTERP_NAMES = new Set(["bash", "sh", "zsh", "dash", "fish", "pwsh", "powershell", "cmd"]);

// Returns true when any argv token is a -c style flag for the given interpreter.
// interpBase must already be lowercased and .exe-stripped.
// - POSIX shells: -c or combined short flags like -lc, -xc (single-dash, lowercase c).
// - PowerShell: case-insensitive -c/-Command/-EncodedCommand.
// - cmd: /c (case-insensitive).
function hasCFlag(argv, interpBase) {
  return argv.some((a) => {
    const al = a.toLowerCase();
    if (interpBase === "cmd") return al === "/c";
    if (interpBase === "pwsh" || interpBase === "powershell")
      return al === "-c" || al === "-command" || al === "-encodedcommand";
    // POSIX shells: standalone -c or combined like -lc, -xc (lowercase c only)
    return al === "-c" || (a.startsWith("-") && !a.startsWith("--") && /c/.test(a.slice(1)));
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
    // Segment is an interpreter with a -c flag: check if its body is a write.
    // Lazy require to break classify.js ↔ bash-write-targets.js cycle.
    let isReadOnlyInterpreterC;
    try {
      ({ isReadOnlyInterpreterC } = require("../bash-write-patterns/classify"));
    } catch (_) { return true; } // fail-closed if classify unavailable
    if (typeof isReadOnlyInterpreterC !== "function") return true;
    // Use seg.rawText if available, else reconstruct from argv.
    const rawText = seg.rawText || argv.join(" ");
    // Write body → return true immediately; read body → continue checking remaining segments.
    if (!isReadOnlyInterpreterC(rawText)) return true;
  }
  return false;
}

// True when any segment carries a hidden write inside an eval / xargs / find
// action clause. Wire this into the SAME three sites as isCommandSubstWriteIR /
// isNewlineInjectedWriteIR. Fail-safe: guard !ir / parseFailure at the top.
function isExoticExecWriteIR(ir, deps) {
  // The split introduced `deps` at this seam; every sibling module under
  // bash-write-targets/ exports a single-arg predicate, so a future direct
  // require could call this as isExoticExecWriteIR(ir) and make the eval /
  // xargs / find helpers throw. enforce-worktree.js does not wrap the
  // predicate in try/catch, so a throw exits with no verdict — fail-open on
  // exactly the commands this predicate exists to block. Fail closed instead.
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
    const eff = resolveEffectiveCommand(seg);
    const base = eff != null ? commandBasename(eff) : null;
    if (base == null) continue;
    if (EVAL_RE.test(base) && evalSegmentIsWrite(seg, deps)) return true;
    if (XARGS_RE.test(base) && xargsSegmentIsWrite(seg, deps)) return true;
    if (FIND_RE.test(base) && findSegmentIsWrite(seg, deps)) return true;
  }
  return false;
}

module.exports = {
  isExoticExecWriteIR,
  isInterpreterCWriteIR,
};
