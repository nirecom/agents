"use strict";

const { resolveEffectiveCommand, scanWrappedVerb, commandBasename } = require("./bash-write-patterns/segment-utils");
const { extractRedirectTargets } = require("./bash-write-targets/redirect");
const { extractTeeTargets } = require("./bash-write-targets/tee");
const { extractPwshWriteTargets } = require("./bash-write-targets/pwsh");
const { extractCpMvDestination } = require("./bash-write-targets/cp-mv");
const { extractRmTargets } = require("./bash-write-targets/rm");
const { extractStagedFiles } = require("./bash-write-targets/staged");
const { isEncodedCommandWriteIR } = require("./bash-write-targets/encoded");
const { isExtendedFileOpWriteIR } = require("./bash-write-targets/file-op");
const { isHereWriteIR } = require("./bash-write-targets/here");
const { isExoticExecWriteIR: exoticExecWriteIR, isInterpreterCWriteIR } = require("./bash-write-targets/exotic-exec");
const { spanAwareNewlineSplit, scanSpans } = require("./quote-spans");

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

// Extract the inner command strings of every `$(...)` / backtick substitution in
// a raw fragment -> { ok, subs }. Boundaries come from the shared quote-span
// scanner (hooks/lib/quote-spans), never a local paren counter: `)` also
// terminates a `case` pattern, which truncated the span and lost the write
// (#1569). Single-quoted text opens no substitution frame, so `echo '$(rm f)'`
// stays a read. Nested spans are returned too — over-reporting only widens
// detection, a missed span silently demotes a write. ok:false = fail-closed.
function extractCommandSubstitutions(raw) {
  if (!raw || typeof raw !== "string") return { ok: true, subs: [] };
  const sr = scanSpans(raw);
  if (!sr.ok) return { ok: false, subs: [] };
  const subs = [];
  for (const s of sr.spans) {
    if (s.kind !== "cmdsubst" && s.kind !== "backtick") continue;
    subs.push(raw.slice(s.innerStart, s.innerEnd));
  }
  return { ok: true, subs };
}

// isCommandSubstWriteIR: a write hidden inside a `$(...)` / backtick substitution,
// including the double-quoted shape (`echo "$(rm f)"`) that the IR keeps as a
// single argv token and never splits into its own segment (#514). gh writes are
// NOT flagged — they write to GitHub, not the worktree (#1296).
// #2064: deriveProv derives dispatch provenance from an intact IR. The lazy
// require keeps the module cycle broken (patterns.js → classify.js → this file);
// a failed load yields null, i.e. no provenance = fail-closed.
function deriveProv(ir) {
  try {
    const { deriveDispatchProvenance } = require("./bash-write-patterns/dispatch-provenance");
    return typeof deriveDispatchProvenance === "function" ? deriveDispatchProvenance(ir) : null;
  } catch (e) {
    return null;
  }
}

// Shared: parse an inner command string and report whether it is a local write
// (posix redirect / pwsh cmdlet / rm-cp-mv / git write). gh writes are NOT
// flagged (GitHub-side, not local — mirrors classify()'s contract, #1296).
// Recurse into further-nested command substitutions. Fail-closed: unparseable /
// parseFailure inner command → treated as a write (never a silent demotion).
// `recurse` re-enters isCommandSubstWriteIR to catch a write one level deeper.
function innerCommandIsWrite(inner, recurse, ctx) {
  if (!inner || !inner.trim()) return false;
  const { parse } = require("./command-ir");
  let isGitWriteIR;
  try { ({ isGitWriteIR } = require("./bash-write-patterns/patterns")); } catch (_) { isGitWriteIR = () => false; }
  let innerIr;
  try { innerIr = parse(inner); } catch (_) { return true; }
  if (!innerIr || innerIr.parseFailure === true) return true;
  let isPkgMgrWriteIR;
  try { ({ isPkgMgrWriteIR } = require("./bash-write-targets/pkg-mgr")); } catch (_) { isPkgMgrWriteIR = () => false; }
  // isHereWriteIR always false (here-shape read boundary); not in OR chain.
  // isNewlineInjectedWriteIR IS in it: an inner body is itself a command string,
  // so an unquoted newline separates commands there exactly as at top level
  // (`eval 'echo hi\nrm -rf docs'`). Its own `/[\r\n]/` + `lines.length < 2`
  // guards terminate the mutual recursion.
  if (isPosixRedirWriteIR(innerIr) || isPwshWriteIR(innerIr) || isFileOpWriteIR(innerIr) || isGitWriteIR(innerIr) || isPkgMgrWriteIR(innerIr) || isInterpreterCWriteIR(innerIr) || isEncodedCommandWriteIR(innerIr) || isExtendedFileOpWriteIR(innerIr) || isExoticExecWriteIR(innerIr, ctx) || isNewlineInjectedWriteIR(innerIr, ctx)) return true;
  // Fail-closed widening: classify() sees interpreter-c wrappers (`sh -c '…'`)
  // and any WRITE_PATTERNS-flagged write that the narrow IR predicates above do
  // not individually cover. classify() never demotes a write to read, so adding
  // it here only widens detection (never a silent demotion).
  let classify;
  try { ({ classify } = require("./bash-write-patterns")); } catch (_) { classify = null; }
  if (classify && classify(innerIr, ctx) === "write") return true;
  return recurse ? recurse(innerIr, ctx) : false;
}

function isCommandSubstWriteIR(ir, ctx) {
  if (!ir || ir.parseFailure === true) return false;
  if (!ir.segments) return false;
  const prov = ctx !== undefined ? ctx : deriveProv(ir);
  for (const seg of ir.segments) {
    // Scan only the RAW forms — they preserve quote characters so
    // extractCommandSubstitutions can exclude single-quoted (literal) spans.
    const fragments = [];
    if (Array.isArray(seg.argvRaw)) fragments.push(...seg.argvRaw);
    if (seg.cmd0Raw) fragments.push(seg.cmd0Raw);
    for (const frag of fragments) {
      const { ok, subs } = extractCommandSubstitutions(frag);
      // A fragment the scanner cannot parse hides its own substitution
      // boundaries; guessing at them is the attacker's choice, so this is a
      // write (fail-closed).
      if (!ok) return true;
      for (const inner of subs) {
        if (innerCommandIsWrite(inner, isCommandSubstWriteIR, prov)) return true;
      }
    }
  }
  return false;
}

// True when a write is hidden on a later line of a NEWLINE-separated command.
// An unquoted newline separates commands in bash, but splitSegmentsWithSeparators
// does not split on it, so `echo x\nrm foo` is a single `echo` segment and no
// per-segment predicate sees the `rm`. Heredoc bodies are stripped first — their
// newlines are data, not separators; quoted newlines are left to the per-line
// parse; gh writes are NOT flagged (local-write contract, #1296).
function isNewlineInjectedWriteIR(ir, ctx) {
  if (!ir || ir.parseFailure === true) return false;
  // Derive BEFORE stripHeredocBody: only the intact ir still carries the
  // dispatcher path token and the complete heredoc.
  const prov = ctx !== undefined ? ctx : deriveProv(ir);
  const raw = ir.rawText;
  if (!raw || typeof raw !== "string") return false;
  if (!/[\r\n]/.test(raw)) return false;
  const { stripHeredocBody, stripDqPreservingCmdSubst } = require("./strip-quoted-args");
  let stripped;
  try { stripped = stripHeredocBody(raw); } catch (_) { stripped = raw; }
  const folded = stripped.replace(/\\[ \t]*\r?\n/g, ' ');
  let foldedDq;
  try { foldedDq = stripDqPreservingCmdSubst(folded); } catch (_) { foldedDq = folded; }
  // Span-aware: a newline inside a quote is argument text, not a line break.
  // The split stays INCLUSIVE of expanding frames (`$( )`, backticks, bare
  // subshells, process substitutions): the IR keeps no fragment for an unquoted
  // newline-crossing opener, so this raw split is the only detector a write
  // injected inside such a frame ever reaches (#2064).
  const { ok: splitOk, lines } = spanAwareNewlineSplit(foldedDq);
  if (!splitOk) return true; // unparseable spans → fail closed
  if (lines.length < 2) return false;
  const cleared = !!(prov && prov.dispatchCleared === true);
  for (const line of lines) {
    if (cleared && isSplitArtifactHeredocLine(line, prov)) continue;
    if (innerCommandIsWrite(line, isCommandSubstWriteIR, prov)) return true;
  }
  return false;
}

// A quote-delimited `cat` heredoc opener sitting at the very END of a line,
// with nothing after it to consume the heredoc.
// The `\w+` delimiter shape is classify()'s own (isTruncatedCatHeredocOnly):
// anything outside it stays fail-closed rather than widening the demotion here.
const TRAILING_CAT_HEREDOC_RE = /(?:^|[\s;|&(])cat[ \t]+<<-?[ \t]*(?:'\w+'|"\w+")[ \t]*$/;

// True when a split line's only write evidence is a heredoc opener this split
// created: stripHeredocBody already took the body and delimiter, so a trailing
// `cat <<'EOF'` cut away from its own `)` carries no content (#2064). Callers
// consult it only under dispatch clearance; two further conditions keep the
// signal intact wherever the heredoc IS the payload — the opener must be last
// (`cat <<'X' | bash`, `cat <<'EOF' >/tmp/pwn` are not), and the line minus
// that opener must pass the FULL write predicate chain. classify() alone is
// not enough: it is WRITE_PATTERNS-only and reads `rm -rf docs;` as read.
// Rationale: docs/architecture/claude-code/settings.md.
function isSplitArtifactHeredocLine(line, ctx) {
  try {
    const m = TRAILING_CAT_HEREDOC_RE.exec(line);
    if (!m) return false;
    return !innerCommandIsWrite(line.slice(0, m.index), isCommandSubstWriteIR, ctx);
  } catch (e) {
    return false; // fail closed: judge the line
  }
}

// Exotic exec (eval / xargs / find action clauses) lives in
// bash-write-targets/exotic-exec.js. Its predicates need parent-owned helpers,
// which are injected here rather than required back (no module cycle).
function isExoticExecWriteIR(ir, ctx) {
  // Closure-injected deps keep exotic-exec.js untouched and its 3-key
  // fail-closed typeof contract intact (arity unchanged: 2-arg / 1-arg).
  const prov = ctx !== undefined ? ctx : deriveProv(ir);
  return exoticExecWriteIR(ir, {
    innerCommandIsWrite: (inner, recurse) => innerCommandIsWrite(inner, recurse, prov),
    isCommandSubstWriteIR: (innerIr) => isCommandSubstWriteIR(innerIr, prov),
    resolveRawArgvAfterEnvPrefix,
  });
}

module.exports = {
  extractCommandSubstitutions,
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
  isEncodedCommandWriteIR,
  isExtendedFileOpWriteIR,
  isHereWriteIR,
};
