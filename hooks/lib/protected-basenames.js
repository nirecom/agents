#!/usr/bin/env node
// SSOT for which basenames hold OFF-clearance / session-override state that no
// tool-issued write may create or mutate. Shared (rules/coding/file-split.md) by
// block-clearance-token-write.js and enforce-worktree/bash-write-scope/marker-gate.js.
// Matching is directory-agnostic — a marker/token written anywhere is still a
// forgery attempt. Suffix lists are canonical (CPR-SSOT); regexes are derived from them.
"use strict";

const path = require("path");
const {
  candidateBasenameMatchesAnySuffix,
  normalizeCandidateBasename,
  STRIPPABLE_TAIL_CHARS,
} = require("./basename-glob-normalize");
const { decodeAnsiCEscapes, candidateSpellings } = require("./basename-glob-normalize/brace-ansi-expand");
// One-way edge (#2108): active-session-ids.js must never require this module back.
const { observeActiveSessionIds } = require("./active-session-ids");

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
// must be equally unforgeable. Kept in sync
// with hooks/lib/session-markers.js and
// hooks/workflow-state/state-io/zombie-cleanup.js.
const EMERGENCY_PROVENANCE_MARKER_KIND = "off-emergency-invoked";

const SESSION_MARKER_KINDS = [
  "workflow-off",
  "worktree-off",
  "issue-close-verified",
  "next-step-paused",
  // The stall-reported ledger AUTHORIZES SUPPRESSION of a mechanism-failure
  // report (#1997), so a forged one silences future reports.
  "stall-reported",
  EMERGENCY_PROVENANCE_MARKER_KIND,
];

// #2053: session state the forge-target-ownership guard trusts when it decides
// to stay SILENT — a cached login, a recorded GH_REPO/GH_HOST, the auth-dirty
// ledger. Forging one lets an unproven repo pass as proven, or clears the dirty
// flag that would otherwise force an ask, so they are unforgeable on the same
// terms as the markers above. They are NOT session markers (session-markers.js
// never reads them), hence a separate list joined only for protection.
const FORGE_OWNERSHIP_STATE_KINDS = ["gh-login", "gh-env", "gh-auth-dirty"];

// Every kind whose on-disk file a tool-issued write may not create or mutate.
const PROTECTED_STATE_KINDS = SESSION_MARKER_KINDS.concat(FORGE_OWNERSHIP_STATE_KINDS);

// M-3 (#1780): writeMarker() in workflow-mark/enforce-override-handlers/
// off-clearance.js writes `<marker>.tmp` then renames, exactly as the token mint
// does — so the marker list covers the `.tmp` intermediate too, symmetric with
// OFF_CLEARANCE_TOKEN_SUFFIXES (CPR-ORTH).
const PROTECTED_MARKER_SUFFIXES = PROTECTED_STATE_KINDS.reduce(
  (acc, kind) => acc.concat(["." + kind, "." + kind + ".tmp"]),
  []
);

// The consume-claim wrapper's shape, as a BODY (unanchored) so both the
// `$`-anchored classifier regex below and the mention gates can embed it —
// retyping the hex shape in a second place would be the CPR-SSOT break.
const CONSUMING_CLAIM_SUFFIX_BODY = "\\.consuming-[0-9a-f]{16}\\.tmp";

// The tail the filesystem discards before the file is created, embedded between
// the suffix and the boundary so the mention gates read a name exactly as
// classifyProtectedPath does (SSOT: basename-glob-normalize.js). Without it
// `<sid>.off-clearance.` mentioned nothing while still classifying as a token —
// the ALLOW/BLOCK split that made a terminal route hand out the real token
// (#1821). It cannot widen: the boundary still has to hold after the tail.
const STRIPPABLE_TAIL_BODY = STRIPPABLE_TAIL_CHARS + "*";

// Two right boundaries for the mention gates, deliberately different (CPR-SC).
// "wide" is the prefilter for routes that re-classify the target afterwards, so
// its over-arming costs nothing. "strict" is for the interpreter route, which is
// TERMINAL — an over-arm there is an over-block of a name classifyProtectedPath
// disowns (#1821). JS `\w` is ASCII-only and cannot see a multi-byte
// continuation; `\p{M}` is required alongside `\p{L}\p{N}` because a combining
// mark carries no letter or number category of its own.
const MENTION_READINGS = {
  wide: { boundary: "(?![\\w.-])", flags: "i" },
  strict: { boundary: "(?![\\p{L}\\p{N}\\p{M}_.-])", flags: "iu" },
};

function suffixesToAnchoredRe(suffixes) {
  const alt = suffixes.map((s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|");
  return new RegExp("(?:" + alt + ")$", "i");
}

// Mention gate for interpreter bodies / shell-variable values, where the text is
// not a clean basename. Derived (CPR-SSOT), not hand-maintained — mirrors
// MARKER_MENTION_RE's boundary discipline (leading "." anchor + trailing
// (?![\w.-]) negative lookahead) so a hyphen-joined script/directory name that
// merely CONTAINS the suffix as a substring (e.g. the sanctioned minter's own
// invocation `bin/request-off-clearance`) never arms this gate, while every
// on-disk suffix variant (including the write-then-rename mint intermediates
// and the optional consume-claim wrapper the write-side classifier strips)
// still does.
function suffixesToMentionRe(suffixes, reading) {
  const alt = suffixes
    .map((s) => s.replace(/^\./, "").replace(/[.*+?^${}()|[\]\\]/g, "\\$&"))
    .join("|");
  const r = MENTION_READINGS[reading];
  return new RegExp(
    "\\.(?:" + alt + ")(?:" + CONSUMING_CLAIM_SUFFIX_BODY + ")?" + STRIPPABLE_TAIL_BODY + r.boundary,
    r.flags
  );
}

// The marker half is hand-built rather than derived from a suffix list, so the
// claim wrapper and the boundary reading must be applied here explicitly too
// (CPR-ORTH) — hitsProtectedMarkerBasename strips the same wrapper on the
// write side.
function markerMentionRe(reading) {
  const r = MENTION_READINGS[reading];
  return new RegExp(
    "\\.(?:" + PROTECTED_STATE_KINDS.join("|") + ")(?:\\.tmp)?" +
      "(?:" + CONSUMING_CLAIM_SUFFIX_BODY + ")?" + STRIPPABLE_TAIL_BODY + r.boundary,
    r.flags
  );
}

// Derived, not hand-maintained. SUFFIX-ONLY: these carry neither the glob/ADS
// normalization nor the stem rule (#2108), so they are for introspection and
// diagnostics only. isClearanceBearingStem / classifyProtectedPath are the SSOT
// for any actual decision.
const TOKEN_BASENAME_RE = suffixesToAnchoredRe(OFF_CLEARANCE_TOKEN_SUFFIXES);
const PROTECTED_MARKER_BASENAME_RE = suffixesToAnchoredRe(PROTECTED_MARKER_SUFFIXES);

// Mention gates for interpreter bodies / shell-variable values, where the text
// is not a clean basename. Both are anchored on the `.<kind>` basename-tail form:
// `rules/workflow-off.md` and `bin/request-off-clearance` are ordinary repo paths
// (the latter is the very command the block message invites, #1821), so a bare
// substring match there would make this hook refuse what it just told you to run.
const TOKEN_MENTION_RE = suffixesToMentionRe(OFF_CLEARANCE_TOKEN_SUFFIXES, "wide");
const MARKER_MENTION_RE = markerMentionRe("wide");
const TOKEN_MENTION_STRICT_RE = suffixesToMentionRe(OFF_CLEARANCE_TOKEN_SUFFIXES, "strict");
const MARKER_MENTION_STRICT_RE = markerMentionRe("strict");

function mentionsProtectedName(text) {
  if (typeof text !== "string") return false;
  return TOKEN_MENTION_RE.test(text) || MARKER_MENTION_RE.test(text);
}

// mentionsProtectedNameStrict(text): the same question read with the Unicode
// boundary, for callers whose verdict is FINAL. Expressed as a REFINEMENT of the
// wide reading rather than an independent gate: the strict boundary forbids a
// superset of what the wide one forbids, so the conjunction is semantically the
// strict test alone, and keeping it explicit means the wide regexes stay the one
// armed denylist that every route is keyed on (CPR-SSOT). Never weaker than what
// classifyProtectedPath owns, so the mention-implies-classify direction that
// makes the wide reading fail-closed is preserved.
function mentionsProtectedNameStrict(text) {
  if (!mentionsProtectedName(text)) return false;
  return TOKEN_MENTION_STRICT_RE.test(text) || MARKER_MENTION_STRICT_RE.test(text);
}

// Two normalizers, deliberately separated (CPR-SC) — the two input shapes disagree
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
// swallowed) so an abandoned enumeration is treated as a hit here too (CPR-ORTH).
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
const CONSUMING_CLAIM_SUFFIX_RE = new RegExp(CONSUMING_CLAIM_SUFFIX_BODY + "$", "i");

// Normalizes FIRST: the `$`-anchored claim regex reads a tail the filesystem
// discards (`<claim>.`, `<claim>::$DATA`) as "not a claim", so stripping the raw
// basename disowned a name whose suffix-list sibling still matched (#1821).
function stripConsumingClaimSuffix(basename) {
  const norm = normalizeCandidateBasename(basename);
  if (typeof norm !== "string" || norm === "") return null;
  return CONSUMING_CLAIM_SUFFIX_RE.test(norm) ? norm.replace(CONSUMING_CLAIM_SUFFIX_RE, "") : null;
}

// A protected suffix alone is not a forgery. Every reader opens exactly
// `path.join(dir, sid + ".<kind>")`, so a name confers clearance only when its
// STEM is an effective session id — `issue-2108-survey.gh-env` is an artifact no
// reader will ever open (#2108).
//
// SPELLING SEPARATION (CPR-UNV named exception). "clean" = an Edit/Write
// file_path, which never met a shell, so an EXACT stem match is required.
// "bash" = a Bash word (the DEFAULT, i.e. the broad side): unquoteBashWord
// collapses `C:\wf\<uuid>.workflow-off` to `C:wf<uuid>.workflow-off`, leaving
// normalization residue on the stem's head, so this route allows a TAIL match.
const SID_UUID_BODY = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
const SID_TS_BODY = "[0-9]{8}-[0-9]{6}";            // clarify-intent's date fallback
const SID_CANONICAL_EXACT_RE = new RegExp("^(?:" + SID_UUID_BODY + "|" + SID_TS_BODY + ")$", "i");
const SID_CANONICAL_TAIL_RE = new RegExp("(?:^|[^0-9A-Za-z])(?:" + SID_UUID_BODY + "|" + SID_TS_BODY + ")$", "i");

// A character no filename component of ours produces is proof the Bash normalizer
// mangled the stem (the drive-colon of `C:wf<uuid>` is the known case). The stem
// is then unprovable, so the bash route treats it as clearance-bearing.
const BASH_STEM_RESIDUE_RE = /[^A-Za-z0-9._-]/;

function stemEndsWithAnySid(stem, sids) {
  const lower = stem.toLowerCase();
  for (const sid of sids) {
    if (sid === "" || !lower.endsWith(sid)) continue;
    const at = lower.length - sid.length;
    if (at === 0 || /[^0-9a-z]/.test(lower[at - 1])) return true;
  }
  return false;
}

// isClearanceBearingStem(stem, { spelling, sessionCtx }): can a file with this
// stem grant clearance to some reader? Fail-closed at every uncertainty.
function isClearanceBearingStem(stem, opts = {}) {
  if (typeof stem !== "string" || stem === "") return false;   // R4: no reader opens `.<kind>`
  const spelling = opts.spelling === "clean" ? "clean" : "bash";
  const canonical = spelling === "clean" ? SID_CANONICAL_EXACT_RE : SID_CANONICAL_TAIL_RE;
  if (canonical.test(stem)) return true;                       // (a) shape alone, observation-free
  if (spelling === "bash" && BASH_STEM_RESIDUE_RE.test(stem)) return true;
  const { sids, complete } = observeActiveSessionIds(opts.sessionCtx);
  if (!complete) return true;                                  // (c) unobservable -> pre-#2108 behaviour
  return spelling === "clean" ? sids.has(stem.toLowerCase()) : stemEndsWithAnySid(stem, sids);
}

const stemOpt = (opts) => ({ stemAllowed: (stem) => isClearanceBearingStem(stem, opts) });

function hitsTokenBasename(basename, opts) {
  if (candidateBasenameMatchesAnySuffix(basename, OFF_CLEARANCE_TOKEN_SUFFIXES, stemOpt(opts))) return true;
  const inner = stripConsumingClaimSuffix(basename);
  return inner !== null &&
    candidateBasenameMatchesAnySuffix(inner, OFF_CLEARANCE_TOKEN_SUFFIXES, stemOpt(opts));
}

function hitsProtectedMarkerBasename(basename, opts) {
  if (candidateBasenameMatchesAnySuffix(basename, PROTECTED_MARKER_SUFFIXES, stemOpt(opts))) return true;
  const inner = stripConsumingClaimSuffix(basename);
  return inner !== null &&
    candidateBasenameMatchesAnySuffix(inner, PROTECTED_MARKER_SUFFIXES, stemOpt(opts));
}

// classifyProtectedPath(filePath, opts): "token" | "marker" | null. Both kinds
// block, but they get different remediation text, so the kind is carried out.
function classifyProtectedPath(filePath, opts) {
  if (!filePath || typeof filePath !== "string") return null;
  const basename = candidateBasenameOf(filePath);
  if (hitsTokenBasename(basename, opts)) return "token";
  if (hitsProtectedMarkerBasename(basename, opts)) return "marker";
  return null;
}

// classifyProtectedBashToken(rawToken): the Bash-word sibling of
// classifyProtectedPath (CPR-ORTH — same verdict vocabulary, different normalizer).
// The spelling is pinned to "bash" here rather than taken from the caller: this
// is the Bash-word entry point by construction, so a caller could only get it
// wrong (#2108).
function classifyProtectedBashToken(rawToken, opts) {
  if (!rawToken || typeof rawToken !== "string") return null;
  const stemOpts = { sessionCtx: opts && opts.sessionCtx, spelling: "bash" };
  const { basenames, overCap } = candidateBasenamesOfBashToken(rawToken);
  // An enumeration that was abandoned has NOT been shown to miss the suffix.
  // Reported as "token" to match what candidateBasenameMatchesAnySuffix already
  // returns for the same condition (it is consulted for the token list first).
  if (overCap) return "token";
  // Explicit arrows, never a bare reference: `some` passes the array INDEX as the
  // second argument, which would land in `opts`.
  if (basenames.some((b) => hitsTokenBasename(b, stemOpts))) return "token";
  if (basenames.some((b) => hitsProtectedMarkerBasename(b, stemOpts))) return "marker";
  return null;
}

function hitsProtectedPath(filePath, opts) {
  return classifyProtectedPath(filePath, opts) !== null;
}

module.exports = {
  OFF_CLEARANCE_TOKEN_SUFFIXES,
  PROTECTED_MARKER_SUFFIXES,
  SESSION_MARKER_KINDS,
  FORGE_OWNERSHIP_STATE_KINDS,
  PROTECTED_STATE_KINDS,
  EMERGENCY_PROVENANCE_MARKER_KIND,
  TOKEN_BASENAME_RE,
  PROTECTED_MARKER_BASENAME_RE,
  TOKEN_MENTION_RE,
  MARKER_MENTION_RE,
  TOKEN_MENTION_STRICT_RE,
  MARKER_MENTION_STRICT_RE,
  CONSUMING_CLAIM_SUFFIX_RE,
  SID_CANONICAL_EXACT_RE,
  SID_CANONICAL_TAIL_RE,
  isClearanceBearingStem,
  stripConsumingClaimSuffix,
  mentionsProtectedName,
  mentionsProtectedNameStrict,
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
