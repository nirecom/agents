#!/usr/bin/env node
// SSOT for which basenames hold OFF-clearance / session-override state that no
// tool-issued write may create or mutate. Shared (rules/coding/file-split.md) by
// block-clearance-token-write.js and enforce-worktree/bash-write-scope/marker-gate.js.
// Matching is directory-agnostic — a marker/token written anywhere is still a
// forgery attempt. Suffix lists are canonical (CPR-2); regexes are derived from them.
"use strict";

const path = require("path");
const { candidateBasenameMatchesAnySuffix } = require("./basename-glob-normalize");
const { decodeAnsiCEscapes, candidateSpellings } = require("./basename-glob-normalize/brace-ansi-expand");

// Every on-disk form of the OFF-clearance token: bare, the write-then-rename mint
// intermediates, the claimed form, and the SID-scoped mint lock — the lock path is
// deterministic from the session ID, so it must be protected here too or it's a
// pre-create/delete-and-race DoS vector.
const OFF_CLEARANCE_TOKEN_SUFFIXES = [
  ".off-clearance",
  ".off-clearance.tmp",
  ".off-clearance.claimed",
  ".off-clearance.mint",
  ".off-clearance.mint.tmp",
  ".off-clearance.mint.claimed",
  ".off-clearance.mint.lock.tmp",
];

// Session-override markers. session-markers.js authorizes purely on a marker's
// existence, so one forged file grants full clearance. `off-emergency-invoked` is
// the EMERGENCY-provenance marker, written only by the UserPromptSubmit hook, and
// must be equally unforgeable. Kept in sync with hooks/lib/session-markers.js and
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

// Two normalizers, deliberately separated (CPR-3) — the two input shapes disagree
// about what `\` means. candidateBasenameOf(filePath) is an Edit/Write path with no
// shell in front, so `\` is a Windows separator (fold to `/`).
// candidateBasenameOfBashToken(rawToken) is a raw Bash word, where `\` is the
// shell's escape character and quotes may appear mid-word — folding it would be a
// bypass (`s1.workflow\-off` folded to `/` yields basename `-off`, while bash
// actually creates `s1.workflow-off`), so it unescapes and collapses intra-word
// quoting instead of folding. Only `/` splits a Bash word into components; losing a
// separator can never lose a match since the suffix lists are tail-anchored.
function candidateBasenameOf(filePath) {
  return path.basename(String(filePath).replace(/\\/g, "/"));
}

// Direction discipline (same rule as basename-glob-normalize/brace-ansi-expand.js):
// this normalizer runs in the DETECTION direction and is matched against a
// denylist, so a spelling it fails to produce is a bypass, and a wrong spelling is
// worse than none. Bash ANSI-C quoting (`$'…'`) must be decoded the way bash
// decodes it (via the shared decoder), not left to the plain-escape rule below —
// that rule would erase rather than preserve the match.
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

// candidateBasenamesOfBashToken(rawToken): { basenames, overCap } — every basename
// this token can land on. Must expand the WHOLE token first, then take the
// basename of every candidate — bash performs brace expansion before splitting on
// `/`, so a brace group spanning a slash (`{<wf>/x,<wf>/s1.workflow-off}`) produces
// alternatives with different directory parts; splitting first would erase the
// protected alternative instead of finding it. `overCap` is propagated (not
// swallowed) so an abandoned enumeration is treated as a hit here too (CPR-5).
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

// consume-exact-file.js creates a claim file at
// `${filePath}.consuming-<16-hex-sha256-prefix>.tmp` during its exclusive-open
// window. That basename is itself protected state — pre-creating it forces the
// real consumer's `wx` open into EEXIST, and deleting it mid-window breaks the
// exclusion — but the hex prefix is content-derived, so it's matched structurally:
// strip the suffix and re-classify what remains (widens detection, never narrows).
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
