#!/usr/bin/env node
// SSOT for basenames holding OFF-clearance / session-override state that no
// tool-issued write may create or mutate. Matching is directory-agnostic.
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

// Every on-disk form of the token, including the write-then-rename mint
// intermediates and the SID-scoped mint lock (deterministic path, so a
// pre-create/delete race would otherwise bypass it).
const OFF_CLEARANCE_TOKEN_SUFFIXES = [
  ".off-clearance",
  ".off-clearance.tmp",
  ".off-clearance.claimed",
  ".off-clearance.mint",
  ".off-clearance.mint.tmp",
  ".off-clearance.mint.claimed",
  ".off-clearance.mint.lock.tmp",
];

// session-markers.js authorizes purely on a marker's existence, so a forged
// file grants full clearance; kept in sync with hooks/lib/session-markers.js
// and hooks/workflow-state/state-io/zombie-cleanup.js.
const EMERGENCY_PROVENANCE_MARKER_KIND = "off-emergency-invoked";

const SESSION_MARKER_KINDS = [
  "workflow-off",
  "worktree-off",
  "issue-close-verified",
  "next-step-paused",
  "stall-reported", // authorizes suppressing a mechanism-failure report (#1997)
  EMERGENCY_PROVENANCE_MARKER_KIND,
];

// #2053: session state the forge-target-ownership guard trusts to stay
// silent (login, GH_REPO/GH_HOST, auth-dirty ledger); not session markers,
// but forgeable on the same terms.
const FORGE_OWNERSHIP_STATE_KINDS = ["gh-login", "gh-env", "gh-auth-dirty"];

// Every kind whose on-disk file a tool-issued write may not create or mutate.
const PROTECTED_STATE_KINDS = SESSION_MARKER_KINDS.concat(FORGE_OWNERSHIP_STATE_KINDS);

// M-3 (#1780): the marker writer does write-then-rename via `.tmp`, so the
// suffix list covers that intermediate too.
const PROTECTED_MARKER_SUFFIXES = PROTECTED_STATE_KINDS.reduce(
  (acc, kind) => acc.concat(["." + kind, "." + kind + ".tmp"]),
  []
);

// The consume-claim wrapper's shape, unanchored, shared by the classifier
// regex and the mention gates (single source, CPR-SSOT).
const CONSUMING_CLAIM_SUFFIX_BODY = "\\.consuming-[0-9a-f]{16}\\.tmp";

// Tail the filesystem discards before create; included so mention gates read
// a name the same way classifyProtectedPath does — without it a trailing-dot
// form mentioned nothing while still classifying as a token (#1821).
const STRIPPABLE_TAIL_BODY = STRIPPABLE_TAIL_CHARS + "*";

// Two boundaries (CPR-SC): "wide" prefilters routes that re-classify
// afterwards; "strict" is for the TERMINAL interpreter route, where an
// over-arm would over-block a name classifyProtectedPath disowns (#1821).
// `\p{M}` covers combining marks, which `\w`/`\p{L}\p{N}` alone miss.
const MENTION_READINGS = {
  wide: { boundary: "(?![\\w.-])", flags: "i" },
  strict: { boundary: "(?![\\p{L}\\p{N}\\p{M}_.-])", flags: "iu" },
};

function suffixesToAnchoredRe(suffixes) {
  const alt = suffixes.map((s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|");
  return new RegExp("(?:" + alt + ")$", "i");
}

// Mention gate for interpreter bodies / shell-variable text (not a clean
// basename). Boundary discipline mirrors MARKER_MENTION_RE so a path that
// merely contains the suffix as a substring (e.g. `bin/request-off-clearance`)
// never arms this gate, while every on-disk suffix variant still does.
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

// Hand-built (not derived from a suffix list) so the claim wrapper and
// boundary reading must be applied here too (CPR-ORTH).
function markerMentionRe(reading) {
  const r = MENTION_READINGS[reading];
  return new RegExp(
    "\\.(?:" + PROTECTED_STATE_KINDS.join("|") + ")(?:\\.tmp)?" +
      "(?:" + CONSUMING_CLAIM_SUFFIX_BODY + ")?" + STRIPPABLE_TAIL_BODY + r.boundary,
    r.flags
  );
}

// Derived, SUFFIX-ONLY (no glob/ADS normalization or stem rule, #2108) —
// for introspection only; classifyProtectedPath is the real decision.
const TOKEN_BASENAME_RE = suffixesToAnchoredRe(OFF_CLEARANCE_TOKEN_SUFFIXES);
const PROTECTED_MARKER_BASENAME_RE = suffixesToAnchoredRe(PROTECTED_MARKER_SUFFIXES);

// Mention gates for interpreter bodies / shell-variable text, anchored on
// `.<kind>` — a bare substring match would make this hook block its own
// remediation text (e.g. `bin/request-off-clearance`, #1821).
const TOKEN_MENTION_RE = suffixesToMentionRe(OFF_CLEARANCE_TOKEN_SUFFIXES, "wide");
const MARKER_MENTION_RE = markerMentionRe("wide");
const TOKEN_MENTION_STRICT_RE = suffixesToMentionRe(OFF_CLEARANCE_TOKEN_SUFFIXES, "strict");
const MARKER_MENTION_STRICT_RE = markerMentionRe("strict");

function mentionsProtectedName(text) {
  if (typeof text !== "string") return false;
  return TOKEN_MENTION_RE.test(text) || MARKER_MENTION_RE.test(text);
}

// Same question with the Unicode boundary, for FINAL verdicts. Expressed as
// a refinement of the wide reading (never weaker) so the wide regexes stay
// the one denylist every route keys on (CPR-SSOT).
function mentionsProtectedNameStrict(text) {
  if (!mentionsProtectedName(text)) return false;
  return TOKEN_MENTION_STRICT_RE.test(text) || MARKER_MENTION_STRICT_RE.test(text);
}

// Two normalizers (CPR-SC) — the input shapes disagree about `\`. A clean
// Edit/Write path never met a shell, so `\` folds as a Windows separator.
// A raw Bash word treats `\` as the shell's escape char and may have mid-word
// quoting, so it unescapes/collapses instead of folding (folding would be a
// bypass: `s1.workflow\-off` -> `-off`, not what bash actually creates).
function candidateBasenameOf(filePath) {
  return path.basename(String(filePath).replace(/\\/g, "/"));
}

// Runs in the DETECTION direction against a denylist: a spelling this fails
// to produce is a bypass. `$'...'` (ANSI-C quoting) is decoded via the
// shared decoder, matching how bash itself decodes it.
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
      // Inside "…" bash escapes only $ ` " \ — elsewhere `\` stays literal.
      if (c === "\\" && i + 1 < s.length && /["$`\\]/.test(s[i + 1])) { out += s[i + 1]; i += 2; continue; }
      if (c === '"') { mode = "plain"; i += 1; continue; }
      out += c; i += 1; continue;
    }
    // ANSI-C quoted segment `$'…'` — must be tested before the plain escape
    // rule below, which would otherwise eat the leading backslash.
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

// The single reading with no brace expansion; compatibility entry point —
// every decision goes through the plural form below.
function candidateBasenameOfBashToken(rawToken) {
  return basenameOfUnquotedBashWord(unquoteBashWord(rawToken));
}

// Expands the WHOLE token before taking basenames — bash brace-expands
// before splitting on `/`, so a brace spanning a slash needs full expansion
// first. `overCap` propagates so an abandoned enumeration counts as a hit.
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
  push(candidateBasenameOfBashToken(raw)); // defensive: never lose the raw reading
  return { basenames, overCap };
}

// consume-exact-file.js's claim file (`<file>.consuming-<16hex>.tmp`) is
// itself protected state; matched structurally since the hex is content-
// derived — strip the suffix and re-classify what remains.
const CONSUMING_CLAIM_SUFFIX_RE = new RegExp(CONSUMING_CLAIM_SUFFIX_BODY + "$", "i");

// Normalize first: the `$`-anchored regex misses a filesystem-discarded tail
// that the suffix-list sibling still matches (#1821).
function stripConsumingClaimSuffix(basename) {
  const norm = normalizeCandidateBasename(basename);
  if (typeof norm !== "string" || norm === "") return null;
  return CONSUMING_CLAIM_SUFFIX_RE.test(norm) ? norm.replace(CONSUMING_CLAIM_SUFFIX_RE, "") : null;
}

// A protected suffix alone isn't a forgery — every reader opens exactly
// `sid + ".<kind>"`, so only a name whose stem is an effective session id
// confers clearance (#2108).
//
// "clean" (Edit/Write path, no shell) requires an exact stem match; "bash"
// allows a tail match since unquoteBashWord can leave normalization residue
// on the stem's head (CPR-UNV named exception).
const SID_UUID_BODY = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
const SID_TS_BODY = "[0-9]{8}-[0-9]{6}";            // clarify-intent's date fallback
const SID_CANONICAL_EXACT_RE = new RegExp("^(?:" + SID_UUID_BODY + "|" + SID_TS_BODY + ")$", "i");
const SID_CANONICAL_TAIL_RE = new RegExp("(?:^|[^0-9A-Za-z])(?:" + SID_UUID_BODY + "|" + SID_TS_BODY + ")$", "i");

// A char no filename of ours produces means the Bash normalizer mangled the
// stem (e.g. the drive-colon of `C:wf<uuid>`) — unprovable, so treat as
// clearance-bearing.
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

// Bash-word sibling of classifyProtectedPath (CPR-ORTH); spelling is pinned
// to "bash" since this is the Bash-word entry point by construction (#2108).
function classifyProtectedBashToken(rawToken, opts) {
  if (!rawToken || typeof rawToken !== "string") return null;
  const stemOpts = { sessionCtx: opts && opts.sessionCtx, spelling: "bash" };
  const { basenames, overCap } = candidateBasenamesOfBashToken(rawToken);
  if (overCap) return "token"; // an abandoned enumeration has not been shown to miss the suffix
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
