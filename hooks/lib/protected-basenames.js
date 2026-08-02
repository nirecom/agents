#!/usr/bin/env node
// SSOT for "which basenames hold OFF-clearance / session-override state that no
// tool-issued write may create or mutate" (#1780 H-1/H-2/M-3).
//
// Two entrypoints consume this module — hooks/block-off-clearance-write.js
// (location-INDEPENDENT: blocks the write outright, whatever the worktree) and
// hooks/enforce-worktree/bash-write-scope/marker-gate.js (defence in depth:
// denies the workflow-dir allow fast-paths) — so per rules/coding/file-split.md
// it lives in the shared hooks/lib/ layer, not in either entrypoint's folder.
//
// Matching is intentionally DIRECTORY-AGNOSTIC: the workflow directory varies by
// CLAUDE_WORKFLOW_DIR, and a marker or token written anywhere is still an attempt
// to forge clearance state.
//
// The SUFFIX LISTS are the canonical form; the regexes are derived from them so
// the two can never drift (CPR-2). Suffix lists are what the glob-aware matcher
// in ./basename-glob-normalize needs, and they are trivially auditable.
"use strict";

const path = require("path");
const { candidateBasenameMatchesAnySuffix } = require("./basename-glob-normalize");
const { decodeAnsiCEscapes, candidateSpellings } = require("./basename-glob-normalize/brace-ansi-expand");

// Every on-disk form of the OFF-clearance token: bare, the two write-then-rename
// mint intermediates, the claimed form (#1626), and the SID-scoped exclusive
// mint lock (#1780 round-14 HIGH-2). Unlike mintTmp (pid + random bytes), the
// lock path is fully deterministic from the session ID — exactly what makes it
// exploitable as a DoS vector (pre-create / delete-and-race another minter's
// lock) if left unprotected here.
const OFF_CLEARANCE_TOKEN_SUFFIXES = [
  ".off-clearance",
  ".off-clearance.tmp",
  ".off-clearance.claimed",
  ".off-clearance.mint",
  ".off-clearance.mint.tmp",
  ".off-clearance.mint.claimed",
  ".off-clearance.mint.lock.tmp",
];

// Session-override markers. hooks/lib/session-markers.js authorizes purely on a
// marker's EXISTENCE, so one forged file grants full clearance for the session.
// `off-emergency-invoked` is the EMERGENCY-provenance marker (#1780 M-2) — it is
// written only by the UserPromptSubmit hook and must be equally unforgeable.
// Kept in sync with hooks/lib/session-markers.js and
// hooks/workflow-state/state-io/zombie-cleanup.js.
const EMERGENCY_PROVENANCE_MARKER_KIND = "off-emergency-invoked";

const SESSION_MARKER_KINDS = [
  "workflow-off",
  "worktree-off",
  "issue-close-verified",
  "next-step-paused",
  EMERGENCY_PROVENANCE_MARKER_KIND,
];

// M-3 (#1780): writeMarker() in workflow-mark/enforce-override-handlers/
// off-clearance.js writes `<marker>.tmp` then renames, exactly as the token mint
// does — so the marker list covers the `.tmp` intermediate too, symmetric with
// OFF_CLEARANCE_TOKEN_SUFFIXES (CPR-5).
const PROTECTED_MARKER_SUFFIXES = SESSION_MARKER_KINDS.reduce(
  (acc, kind) => acc.concat(["." + kind, "." + kind + ".tmp"]),
  []
);

function suffixesToAnchoredRe(suffixes) {
  const alt = suffixes.map((s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|");
  return new RegExp("(?:" + alt + ")$", "i");
}

// Derived, not hand-maintained. Exported for callers that still want the regex
// shape (and for test/diagnostic introspection); the predicates below are the
// preferred API because only they carry the glob/ADS normalization.
const TOKEN_BASENAME_RE = suffixesToAnchoredRe(OFF_CLEARANCE_TOKEN_SUFFIXES);
const PROTECTED_MARKER_BASENAME_RE = suffixesToAnchoredRe(PROTECTED_MARKER_SUFFIXES);

// Mention gates for interpreter bodies / shell-variable values, where the text
// is not a clean basename. "off-clearance" is distinctive enough to match as a
// bare substring. Marker names are NOT: `rules/workflow-off.md` and
// `skills/enforce-workflow-off/SKILL.md` are ordinary repo paths, so the marker
// gate is anchored on the `.<kind>` basename-tail form and must not fire on them.
const TOKEN_MENTION_RE = /off-clearance/i;
const MARKER_MENTION_RE = new RegExp(
  "\\.(?:" + SESSION_MARKER_KINDS.join("|") + ")(?:\\.tmp)?(?![\\w.-])",
  "i"
);

function mentionsProtectedName(text) {
  if (typeof text !== "string") return false;
  return TOKEN_MENTION_RE.test(text) || MARKER_MENTION_RE.test(text);
}

// TWO candidate normalizers, deliberately separated (CPR-3): the two input
// shapes disagree about what a backslash MEANS, so one function cannot serve
// both without silently mis-reading one of them.
//
//   candidateBasenameOf(filePath)          — an Edit/Write `file_path`. There is
//     no shell in front of it, so `\` is a Windows PATH SEPARATOR and folding it
//     to `/` is correct (`C:\wf\<sid>.workflow-off` → `<sid>.workflow-off`).
//
//   candidateBasenameOfBashToken(rawToken) — a word out of a Bash command line
//     (a redirect target or an argv token, in the RAW spelling the user typed).
//     There `\` is the shell's ESCAPE character and quotes may appear mid-word,
//     so folding `\` to `/` is a live bypass: `s1.workflow\-off` folded to
//     `s1.workflow/-off` yields the basename `-off`, while bash actually creates
//     the file `s1.workflow-off` (#1780 N-1). This normalizer therefore
//     UNESCAPES instead of folding, and collapses intra-word `'…'` / `"…"`
//     quoting (`s1.workflow'-'off`, `s1.work"flow-off"`) before splitting.
//
// Only `/` splits a Bash word into path components — a backslash never does,
// because it was consumed as an escape. A Windows-style Bash argument such as
// `C:\wf\s1.workflow-off` therefore collapses to `C:wfs1.workflow-off`, which
// still ends with the protected suffix and still matches (the suffix lists are
// tail-anchored, so losing separators can never lose a hit).
function candidateBasenameOf(filePath) {
  return path.basename(String(filePath).replace(/\\/g, "/"));
}

// DIRECTION DISCIPLINE (same rule as the header of
// ./basename-glob-normalize/brace-ansi-expand.js, and the mirror of the block
// comment in hooks/block-off-clearance-write/interpreter-scan.js): this is a
// NORMALIZER consumed in the DETECTION direction. Its output is matched against
// a denylist, so a spelling it fails to produce is a bypass — and a spelling it
// produces WRONGLY is worse than one it leaves alone.
//
// #1780 round-9 HIGH-2: bash ANSI-C quoting (`$'…'`) was not modelled at all, so
// `$'<wf>/s1.workflow-of\x66'` fell through to the PLAIN-context escape rule
// below (`\` + next char -> next char), which turned `\x66` into the literal
// `x66` and ACTIVELY ERASED the match — the normalizer manufactured a basename
// (`s1.workflow-ofx66`) that the real shell never creates, while the shell
// created `s1.workflow-off`. An ANSI-C segment is now decoded as bash decodes
// it, via the shared decoder in the sibling normalizer module (CPR-2).
function unquoteBashWord(rawToken) {
  const s = String(rawToken);
  let out = "";
  let mode = "plain"; // plain | sq | dq
  let i = 0;
  while (i < s.length) {
    const c = s[i];
    if (mode === "sq") {
      if (c === "'") { mode = "plain"; i += 1; continue; }
      out += c; i += 1; continue;
    }
    if (mode === "dq") {
      // Inside "…" bash treats `\` as an escape only before $ ` " \ — elsewhere
      // it stays a literal backslash.
      if (c === "\\" && i + 1 < s.length && /["$`\\]/.test(s[i + 1])) { out += s[i + 1]; i += 2; continue; }
      if (c === '"') { mode = "plain"; i += 1; continue; }
      out += c; i += 1; continue;
    }
    // ANSI-C quoted segment `$'…'`: consume to the terminating unescaped quote
    // and hand the body to the shared decoder. Must be tested BEFORE the plain
    // escape rule below, which would otherwise eat the leading backslash.
    if (c === "$" && s[i + 1] === "'") {
      let j = i + 2;
      let seg = "";
      while (j < s.length) {
        if (s[j] === "\\" && j + 1 < s.length) { seg += s[j] + s[j + 1]; j += 2; continue; }
        if (s[j] === "'") { j += 1; break; }
        seg += s[j]; j += 1;
      }
      out += decodeAnsiCEscapes(seg);
      i = j;
      continue;
    }
    if (c === "\\" && i + 1 < s.length) { out += s[i + 1]; i += 2; continue; }
    if (c === "'") { mode = "sq"; i += 1; continue; }
    if (c === '"') { mode = "dq"; i += 1; continue; }
    out += c; i += 1;
  }
  return out;
}

function basenameOfUnquotedBashWord(unquoted) {
  const idx = unquoted.lastIndexOf("/");
  return idx === -1 ? unquoted : unquoted.slice(idx + 1);
}

// The SINGLE reading of the raw token — the spelling bash produces when no brace
// group is involved. Kept as the compatibility entry point; every DECISION goes
// through the plural form below.
function candidateBasenameOfBashToken(rawToken) {
  return basenameOfUnquotedBashWord(unquoteBashWord(rawToken));
}

// candidateBasenamesOfBashToken(rawToken): { basenames, overCap } — EVERY
// basename this token can land on.
//
// #1780 round-10 HIGH-1. The singular function above splits on `/` FIRST and
// only then (deep inside candidateBasenameMatchesAnySuffix) asks the expander
// what the resulting basename could become. That ordering contradicts both bash
// and the DIRECTION DISCIPLINE stated at line 113: brace expansion is the FIRST
// word expansion bash performs, so a brace group that SPANS a slash produces
// alternatives with DIFFERENT directory parts —
// `{<wf>/x,<wf>/s1.workflow-off}` really writes `s1.workflow-off` — while the
// old order took the basename of the unexpanded word (`s1.workflow-off}`, or
// worse a leading alternative that commits to nothing) and handed the expander
// a string in which the protected alternative no longer existed. The normalizer
// therefore ERASED the match instead of widening it. Measured ALLOW for
// `touch`, `tee`, `dd of=`, `mv` and nested groups.
//
// Correct order, and the one bash uses: expand the WHOLE token first, then take
// the basename of EVERY candidate. The raw token is always among the candidates
// (candidateSpellings never drops it), so every non-brace token keeps exactly
// its previous basename and its previous verdict.
//
// `overCap` is propagated rather than swallowed: candidateBasenameMatchesAnySuffix
// already answers "hit" when the expander refuses to finish an enumeration, and
// this call site must answer the same way or the two disagree about an identical
// doubt (CPR-5).
function candidateBasenamesOfBashToken(rawToken) {
  const raw = String(rawToken);
  const { candidates, overCap } = candidateSpellings(raw);
  const basenames = [];
  const seen = new Set();
  const push = (b) => {
    if (typeof b !== "string" || b === "" || seen.has(b)) return;
    seen.add(b);
    basenames.push(b);
  };
  for (const cand of candidates) push(basenameOfUnquotedBashWord(unquoteBashWord(cand)));
  push(candidateBasenameOfBashToken(raw));   // defensive: never lose the raw reading
  return { basenames, overCap };
}

// codex MEDIUM-1 (#1780): hooks/lib/consume-exact-file.js (the SSOT single-use
// consumption primitive backing the OFF-clearance `.claimed` file AND the
// EMERGENCY-OFF provenance marker, #1626) creates a claim file at
// `${filePath}.consuming-<16-hex-sha256-prefix>.tmp` for the duration of its
// exclusive-open window (see that module's header for why `wx` and not
// `rename` is the mutex primitive on this platform). That claim basename is
// itself protected state — pre-creating it lets a tool-issued write force the
// real consumer's `wx` open into EEXIST ("lost"), and deleting it mid-window
// breaks the exclusion — but it was never enumerable as a fixed suffix
// because the hex prefix is content-derived (sha256 of the exact bytes being
// consumed). Matched structurally instead: strip a trailing
// `.consuming-<16 hex>.tmp` and re-classify what remains — the claim is
// protected exactly when the state file it claims is (additive-only, DIRECTION
// DISCIPLINE — this widens detection, never narrows it).
const CONSUMING_CLAIM_SUFFIX_RE = /\.consuming-[0-9a-f]{16}\.tmp$/i;

function stripConsumingClaimSuffix(basename) {
  return CONSUMING_CLAIM_SUFFIX_RE.test(basename) ? basename.replace(CONSUMING_CLAIM_SUFFIX_RE, "") : null;
}

function hitsTokenBasename(basename) {
  if (candidateBasenameMatchesAnySuffix(basename, OFF_CLEARANCE_TOKEN_SUFFIXES)) return true;
  const inner = stripConsumingClaimSuffix(basename);
  return inner !== null && candidateBasenameMatchesAnySuffix(inner, OFF_CLEARANCE_TOKEN_SUFFIXES);
}

function hitsProtectedMarkerBasename(basename) {
  if (candidateBasenameMatchesAnySuffix(basename, PROTECTED_MARKER_SUFFIXES)) return true;
  const inner = stripConsumingClaimSuffix(basename);
  return inner !== null && candidateBasenameMatchesAnySuffix(inner, PROTECTED_MARKER_SUFFIXES);
}

// classifyProtectedPath(filePath): "token" | "marker" | null. Both kinds block,
// but they get different remediation text, so the kind is carried out.
function classifyProtectedPath(filePath) {
  if (!filePath || typeof filePath !== "string") return null;
  const basename = candidateBasenameOf(filePath);
  if (hitsTokenBasename(basename)) return "token";
  if (hitsProtectedMarkerBasename(basename)) return "marker";
  return null;
}

// classifyProtectedBashToken(rawToken): the Bash-word sibling of
// classifyProtectedPath (CPR-5 — same verdict vocabulary, different normalizer).
function classifyProtectedBashToken(rawToken) {
  if (!rawToken || typeof rawToken !== "string") return null;
  const { basenames, overCap } = candidateBasenamesOfBashToken(rawToken);
  // An enumeration that was abandoned has NOT been shown to miss the suffix.
  // Reported as "token" to match what candidateBasenameMatchesAnySuffix already
  // returns for the same condition (it is consulted for the token list first).
  if (overCap) return "token";
  if (basenames.some(hitsTokenBasename)) return "token";
  if (basenames.some(hitsProtectedMarkerBasename)) return "marker";
  return null;
}

function hitsProtectedPath(filePath) {
  return classifyProtectedPath(filePath) !== null;
}

module.exports = {
  OFF_CLEARANCE_TOKEN_SUFFIXES,
  PROTECTED_MARKER_SUFFIXES,
  SESSION_MARKER_KINDS,
  EMERGENCY_PROVENANCE_MARKER_KIND,
  TOKEN_BASENAME_RE,
  PROTECTED_MARKER_BASENAME_RE,
  TOKEN_MENTION_RE,
  MARKER_MENTION_RE,
  CONSUMING_CLAIM_SUFFIX_RE,
  stripConsumingClaimSuffix,
  mentionsProtectedName,
  candidateBasenameOf,
  unquoteBashWord,
  candidateBasenameOfBashToken,
  candidateBasenamesOfBashToken,
  hitsTokenBasename,
  hitsProtectedMarkerBasename,
  classifyProtectedPath,
  classifyProtectedBashToken,
  hitsProtectedPath,
};
