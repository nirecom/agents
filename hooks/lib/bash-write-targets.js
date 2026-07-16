"use strict";

const { resolveEffectiveCommand, resolveEffectiveArgv, scanWrappedVerb, commandBasename } = require("./bash-write-patterns/segment-utils");
const { extractRedirectTargets } = require("./bash-write-targets/redirect");
const { extractTeeTargets } = require("./bash-write-targets/tee");
const { extractPwshWriteTargets } = require("./bash-write-targets/pwsh");
const { extractCpMvDestination } = require("./bash-write-targets/cp-mv");
const { extractRmTargets } = require("./bash-write-targets/rm");
const { extractStagedFiles } = require("./bash-write-targets/staged");

const ASSIGN_RE = /^[A-Za-z_][A-Za-z0-9_]*=/;

// Return the RAW argv tokens that follow the env-prefix (VAR=val) run and the
// effective command. Shared with the per-verb extractors.
function resolveRawArgvAfterEnvPrefix(seg) {
  if (!seg || !Array.isArray(seg.argv) || !Array.isArray(seg.argvRaw)) return [];
  const skipCmd = ASSIGN_RE.test(seg.cmd0 || "");
  if (!skipCmd) return seg.argvRaw.slice();
  const idx = seg.argv.findIndex((a) => !ASSIGN_RE.test(a));
  if (idx === -1) return [];
  return seg.argvRaw.slice(idx + 1);
}

// Verb sets: the switch between full write-scope scanning and the narrower
// shell-config guard (rm excluded — rm is a delete, not a config-file write).
const FULL_VERB_SET = new Set(["redirect", "tee", "pwsh", "cp", "mv", "rm"]);
const SHELL_CONFIG_VERB_SET = new Set(["redirect", "tee", "pwsh", "cp", "mv"]);

const PWSH_CMDLET_RE = /^(?:set-content|add-content|out-file|new-item|remove-item|move-item|copy-item|sc|ac|ni|ri|mi|ci)$/;

/**
 * Collect write targets from ALL segments of a parsed command (#1069 fix:
 * every pipeline segment is scanned, not just the first verb).
 *
 * @param {object[]} segments - SegmentIR array from parse().segments
 * @param {object} opts - { verbs?: Set<string> } (defaults to FULL_VERB_SET)
 * @returns {{targets: string[]|null, parseFailure: boolean}}
 *   targets: collected write targets (null when none), parseFailure: any
 *   extractor returned null (fail-closed).
 */
function collectWriteTargetsFromSegments(segments, opts) {
  const verbs = (opts && opts.verbs) ? opts.verbs : FULL_VERB_SET;
  const targets = [];
  let parseFailure = false;

  // D1: each extracted path is wrapped as {resolveVia:"ancestor", path} HERE (at
  // the collector), not inside the 5 extractors — the extractors keep returning
  // bare strings so their string-API pins stay green.
  const pushAncestor = (p) => targets.push({ resolveVia: "ancestor", path: p });

  for (const seg of segments) {
    if (verbs.has("redirect") && seg.redirects && seg.redirects.some((r) => r.op !== "<" && r.op !== "<<<")) {
      const r = extractRedirectTargets(seg);
      if (r === null) parseFailure = true; else for (const p of r) pushAncestor(p);
    }
    const effCmd = resolveEffectiveCommand(seg);
    if (effCmd == null) continue;
    const effCmdLower = effCmd.toLowerCase();

    if (verbs.has("tee") && effCmd === "tee") {
      const t = extractTeeTargets(seg);
      if (t === null) parseFailure = true; else for (const p of t) pushAncestor(p);
    } else if (verbs.has("pwsh") && PWSH_CMDLET_RE.test(effCmdLower)) {
      const p = extractPwshWriteTargets(seg);
      if (p === null) parseFailure = true; else for (const q of p) pushAncestor(q);
    } else if ((verbs.has("cp") && effCmd === "cp") || (verbs.has("mv") && effCmd === "mv")) {
      const d = extractCpMvDestination(seg);
      if (d === null) parseFailure = true; else if (d !== undefined) pushAncestor(d);
    } else if (verbs.has("rm") && effCmd === "rm") {
      const r = extractRmTargets(seg);
      if (r === null) parseFailure = true; else for (const p of r) pushAncestor(p);
    }
  }
  return { targets: targets.length > 0 ? targets : null, parseFailure };
}

// --- Green-group fast-allow IR predicates (D2) -----------------------------
// Lightweight IR-shape checks (segment properties) that decide whether a
// command reaches the scope pipeline after its WRITE_PATTERNS entry is retired.
// They live here alongside PWSH_CMDLET_RE / FULL_VERB_SET. Fail-safe: guard
// !ir || ir.parseFailure at the top (parseFailure already forces classify=write,
// so the fast-allow gate never fast-allows a parseFailure).

// True when any segment has a write redirect (>, >>, n>, &>) whose target is not
// solely /dev/null, OR any effective command is `tee`. The /dev/null-only
// exclusion mirrors the extractor: `echo x >/dev/null` stays read.
function isPosixRedirWriteIR(ir) {
  if (!ir || ir.parseFailure === true) return false;
  if (!ir.segments) return false;
  for (const seg of ir.segments) {
    if (resolveEffectiveCommand(seg) === "tee") return true;
    if (seg.redirects && Array.isArray(seg.redirects)) {
      const writeRedirs = seg.redirects.filter((r) => r.op !== "<" && r.op !== "<<<" && !/^&\d/.test(r.targetRaw));
      if (writeRedirs.length === 0) continue;
      // /dev/null-only exclusion: if EVERY write-redirect target is /dev/null,
      // this is a null-sink, not a write.
      const allDevNull = writeRedirs.every((r) => {
        const tgt = (r.target || "").trim();
        return tgt === "/dev/null"; // exact match only — `sub/dev/null` is a real in-scope file
      });
      if (!allDevNull) return true;
    }
  }
  return false;
}

// True when any segment's effective command is a PowerShell write cmdlet/alias.
function isPwshWriteIR(ir) {
  if (!ir || ir.parseFailure === true) return false;
  if (!ir.segments) return false;
  for (const seg of ir.segments) {
    const effCmd = resolveEffectiveCommand(seg);
    if (effCmd != null && PWSH_CMDLET_RE.test(effCmd.toLowerCase())) return true;
  }
  return false;
}

// True when any segment's effective command is rm / cp / mv.
function isFileOpWriteIR(ir) {
  if (!ir || ir.parseFailure === true) return false;
  if (!ir.segments) return false;
  for (const seg of ir.segments) {
    const effCmd = resolveEffectiveCommand(seg);
    if (effCmd === "rm" || effCmd === "cp" || effCmd === "mv") return true;
    // Fail-closed safety net (segment-utils AMBIGUOUS bail): a wrapper segment
    // whose effective command could not be cleanly resolved past an
    // unclassifiable option may still hide a wrapped `rm`/`cp`/`mv` (e.g.
    // `stdbuf -Z rm f` / `env -Z v /bin/rm f`). Scan the raw argv for a file-op
    // verb token by BASENAME (FIX B) so path-qualified spellings are caught too.
    if (scanWrappedVerb(seg, (tok) => {
      const b = commandBasename(tok);
      return b === "rm" || b === "cp" || b === "mv";
    })) return true;
  }
  return false;
}

// Extract the inner command strings from every `$(...)` and backtick
// substitution found in a raw text fragment. Nested `$(...)` is captured at the
// outermost level (the inner content is re-scanned recursively by the caller).
// Fail-open on malformed nesting is acceptable here — the caller only widens
// detection; it never demotes a write to read.
function extractCommandSubstitutions(raw) {
  if (!raw || typeof raw !== "string") return [];
  // Single-quoted spans are LITERAL — the shell does not expand $()/backticks
  // inside them. Blank them out first so `echo '$(rm f)'` is not a false write.
  // Double-quoted spans DO expand substitutions, so they are left intact.
  raw = raw.replace(/'[^']*'/g, "");
  const out = [];
  // $(...) with balanced-paren scan (handles one level of nesting).
  for (let i = 0; i < raw.length - 1; i++) {
    if (raw[i] === "$" && raw[i + 1] === "(") {
      let depth = 1;
      let j = i + 2;
      for (; j < raw.length && depth > 0; j++) {
        if (raw[j] === "(") depth++;
        else if (raw[j] === ")") depth--;
      }
      if (depth === 0) {
        out.push(raw.slice(i + 2, j - 1));
        i = j - 1;
      }
    }
  }
  // Backtick substitution `...`.
  const btRe = /`([^`]*)`/g;
  let m;
  while ((m = btRe.exec(raw)) !== null) out.push(m[1]);
  return out;
}

// True when a write (posix redirect / tee / pwsh cmdlet / rm-cp-mv / git write)
// is hidden inside a `$(...)` or backtick command substitution — including when
// the substitution is wrapped in double quotes (`echo "$(rm f)"`), a shape the
// IR parser keeps as a single argv token and therefore does NOT split into its
// own segment. The retired rm/cp/mv/redirect/pwsh/git WRITE_PATTERNS entries
// used to catch these via whole-string regex; this predicate restores that
// coverage under the IR architecture (#514 protection).
//
// gh writes are deliberately NOT flagged here: gh writes to GitHub, not the
// local worktree — mirroring classify()'s local-write contract (#1296).
// Fail-safe: guard !ir / parseFailure; a lazy require of isGitWriteIR avoids a
// module-load cycle (patterns.js → classify.js → this file).
// Shared: parse an inner command string and report whether it is a local write
// (posix redirect / pwsh cmdlet / rm-cp-mv / git write). gh writes are NOT
// flagged (GitHub-side, not local — mirrors classify()'s contract, #1296).
// Recurse into further-nested command substitutions. Fail-closed: unparseable /
// parseFailure inner command → treated as a write (never a silent demotion).
// `recurse` re-enters isCommandSubstWriteIR to catch a write one level deeper.
function innerCommandIsWrite(inner, recurse) {
  if (!inner || !inner.trim()) return false;
  const { parse } = require("./command-ir");
  let isGitWriteIR;
  try { ({ isGitWriteIR } = require("./bash-write-patterns/patterns")); } catch (_) { isGitWriteIR = () => false; }
  let innerIr;
  try { innerIr = parse(inner); } catch (_) { return true; }
  if (!innerIr || innerIr.parseFailure === true) return true;
  let isPkgMgrWriteIR;
  try { ({ isPkgMgrWriteIR } = require("./bash-write-targets/pkg-mgr")); } catch (_) { isPkgMgrWriteIR = () => false; }
  if (isPosixRedirWriteIR(innerIr) || isPwshWriteIR(innerIr) || isFileOpWriteIR(innerIr) || isGitWriteIR(innerIr) || isPkgMgrWriteIR(innerIr) || isInterpreterCWriteIR(innerIr)) return true;
  // Fail-closed widening: classify() sees interpreter-c wrappers (`sh -c '…'`)
  // and any WRITE_PATTERNS-flagged write that the narrow IR predicates above do
  // not individually cover. classify() never demotes a write to read, so adding
  // it here only widens detection (never a silent demotion).
  let classify;
  try { ({ classify } = require("./bash-write-patterns")); } catch (_) { classify = null; }
  if (classify && classify(innerIr) === "write") return true;
  return recurse ? recurse(innerIr) : false;
}

function isCommandSubstWriteIR(ir) {
  if (!ir || ir.parseFailure === true) return false;
  if (!ir.segments) return false;
  for (const seg of ir.segments) {
    // Scan only the RAW forms — they preserve quote characters so
    // extractCommandSubstitutions can exclude single-quoted (literal) spans.
    const fragments = [];
    if (Array.isArray(seg.argvRaw)) fragments.push(...seg.argvRaw);
    if (seg.cmd0Raw) fragments.push(seg.cmd0Raw);
    for (const frag of fragments) {
      for (const inner of extractCommandSubstitutions(frag)) {
        if (innerCommandIsWrite(inner, isCommandSubstWriteIR)) return true;
      }
    }
  }
  return false;
}

// True when a write is hidden on a later line of a NEWLINE-separated command.
// In bash an unquoted newline is a command separator equivalent to `;`, but the
// IR segment splitter (splitSegmentsWithSeparators) does NOT split on newline —
// so `echo x\nrm foo` parses as a single `echo` segment with `rm`/`foo` as argv
// tokens, and no per-segment predicate sees the `rm`. The retired rm/redirect/…
// WRITE_PATTERNS regexes used to catch this (their `[\s;|&]` prefix matched a
// newline); this predicate restores that coverage. Heredoc bodies are stripped
// first (stripHeredocBody) so a newline INSIDE a heredoc body is not mistaken
// for a command separator (the body is data, not commands). Quoted newlines
// (inside '...' / "...") are left to the per-line parse, which fail-closes on
// unclosed quotes. gh writes are NOT flagged (local-write contract, #1296).
function isNewlineInjectedWriteIR(ir) {
  if (!ir || ir.parseFailure === true) return false;
  const raw = ir.rawText;
  if (!raw || typeof raw !== "string") return false;
  if (!/[\r\n]/.test(raw)) return false;
  const { stripHeredocBody } = require("./strip-quoted-args");
  let stripped;
  try { stripped = stripHeredocBody(raw); } catch (_) { stripped = raw; }
  const lines = stripped.split(/[\r\n]+/).map((l) => l.trim()).filter(Boolean);
  if (lines.length < 2) return false;
  for (const line of lines) {
    if (innerCommandIsWrite(line, isCommandSubstWriteIR)) return true;
  }
  return false;
}

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

// eval BODY... : the concatenation of eval's arguments is re-executed by the
// shell. Reconstruct the body from the resolved argv (already unquoted) and the
// RAW argv (to detect `$`-dynamic bodies). Static body → re-parse via
// innerCommandIsWrite; dynamic/unparseable → fail-closed WRITE.
function evalSegmentIsWrite(seg) {
  const argv = resolveEffectiveArgv(seg);
  if (!Array.isArray(argv) || argv.length === 0) return false; // bare `eval` — no body
  const rawArgv = resolveRawArgvAfterEnvPrefix(seg);
  // Any raw arg that still carries a shell expansion is dynamic → fail-closed.
  if (rawArgv.some(looksDynamic) || argv.some(looksDynamic)) return true;
  const body = argv.join(" ").trim();
  if (!body) return false;
  return innerCommandIsWrite(body, isCommandSubstWriteIR);
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
function xargsSegmentIsWrite(seg) {
  const argv = resolveEffectiveArgv(seg);
  if (!Array.isArray(argv)) return false;
  const cmdTokens = xargsCommandTokens(argv);
  if (!cmdTokens || cmdTokens.length === 0) return false; // no explicit command
  if (cmdTokens.some(looksDynamic)) return true;          // dynamic command → fail-closed
  return innerCommandIsWrite(cmdTokens.join(" "), isCommandSubstWriteIR);
}

// find ... action-clause : `-delete` is itself a write; `-exec`/`-execdir`/
// `-ok`/`-okdir` <cmd> ... {\; | +} runs <cmd> per match — re-parse that <cmd>.
// The IR tokenizer strips the escape from `\;` leaving a bare `\` or `;`
// terminator token, so terminate the collected command at `;`, `\`, or `+`.
function findSegmentIsWrite(seg) {
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
      if (clean.some(looksDynamic)) return true;
      if (clean.length === 0) return true;   // only placeholders → fail-closed
      if (innerCommandIsWrite(clean.join(" "), isCommandSubstWriteIR)) return true;
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
      ({ isReadOnlyInterpreterC } = require("./bash-write-patterns/classify"));
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
function isExoticExecWriteIR(ir) {
  if (!ir || ir.parseFailure === true) return false;
  if (!ir.segments) return false;
  for (const seg of ir.segments) {
    const eff = resolveEffectiveCommand(seg);
    const base = eff != null ? commandBasename(eff) : null;
    if (base == null) continue;
    if (EVAL_RE.test(base) && evalSegmentIsWrite(seg)) return true;
    if (XARGS_RE.test(base) && xargsSegmentIsWrite(seg)) return true;
    if (FIND_RE.test(base) && findSegmentIsWrite(seg)) return true;
  }
  return false;
}

module.exports = {
  extractRedirectTargets,
  extractTeeTargets,
  extractPwshWriteTargets,
  extractCpMvDestination,
  extractRmTargets,
  extractStagedFiles,
  collectWriteTargetsFromSegments,
  resolveRawArgvAfterEnvPrefix,
  FULL_VERB_SET,
  SHELL_CONFIG_VERB_SET,
  isPosixRedirWriteIR,
  isPwshWriteIR,
  isFileOpWriteIR,
  isCommandSubstWriteIR,
  isNewlineInjectedWriteIR,
  isExoticExecWriteIR,
  isInterpreterCWriteIR,
};
