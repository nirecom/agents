"use strict";
// hooks/enforce-worktree/arg-tail-guard.js
// Decision-layer arg-tail safety, expressed over the shared quote-span scanner
// (#1569). Three sanctioned-invocation matchers used to carry three hand-written
// regex scans of the same shape; they now share this module.
//
//   tokenizeArgTail      — shell word splitting with per-word quote provenance
//   rejectsUnsafeToken   — per-token verdict (rules 1-6 below)
//   rejectsUnsafeArgTail — whole-tail verdict under a named profile
//
// Rule set (first match wins), applied by rejectsUnsafeToken:
//   1. malformed Token shape                        -> reject (fail closed)
//   2. any ANSI-C ($'…') piece                      -> reject
//   3. SET-A `| & ; < > ( )` in an unquoted piece   -> reject
//   4. SET-B `$` / backtick, unescaped, in an
//      unquoted or double-quoted piece              -> reject
//   5. SET-A inside a dq / sq piece                 -> ALLOW (quoted text is
//      data, not structure — this is the #1569 relaxation)
//   6. otherwise                                    -> allow
//
// Fail-closed everywhere: an arg tail the scanner cannot parse, an unknown
// profile, or a token whose pieces do not reconstruct it are all rejected, since
// every verdict here gates a write from the main worktree.

const { scanSpans, QUOTE_KINDS, EXPANDING_KINDS } = require("../lib/quote-spans");

const PIECE_KINDS = ["unquoted", "dq", "sq", "ansic"];
const SET_A_UNQUOTED = /[|&;<>()]/;
const SET_B = /[$`]/;

/**
 * Per-call-site reject sets. `setA` is matched OUTSIDE quote spans only; the
 * `&` rule is separate because `&>` / `&>>` are a redirect, not a background
 * operator, and only some call sites may use them.
 *
 * The difference between `worker-script`/`overlay` and `sanctioned-bin` is
 * deliberate and must not be collapsed: the sanctioned bin tools accept no
 * redirect at all, while the worker scripts document `&>` output capture.
 */
const UNSAFE_PROFILES = {
  "worker-script": { allowRedirectAmpersand: true, setA: /[|;()]/ },
  overlay: { allowRedirectAmpersand: true, setA: /\|\||;|<\(|>\(/ },
  "sanctioned-bin": { allowRedirectAmpersand: false, setA: /[|;<>]/ },
};

const isIdx = (v) => Number.isInteger(v) && v >= 0;

// Per-ScanResult offset maps, memoized on the scan object itself.
const offsetCache = new WeakMap();

/**
 * One left-to-right sweep producing, for every offset of `sr.str`:
 *   inner[i]  — the innermost span covering `i`, or null
 *   owners[i] — the nearest enclosing QUOTE span at any depth (substitution
 *               frames are transparent: a quote nested in a `$( )` inside a dq
 *               word is a real quote context, and the dq context resumes once it
 *               closes), or null
 *
 * Both were previously answered by re-scanning the whole span list per
 * character, which made tokenizeArgTail O(n^2) — a 128 KB command took ~7.5 s
 * and blew the PreToolUse hook timeout, and a hook that never answers is
 * fail-OPEN. Spans are start-ordered and properly nested, so a stack walk gives
 * the identical answers in O(n + spans).
 */
function offsetMaps(sr) {
  const hit = offsetCache.get(sr);
  if (hit !== undefined) return hit;
  const n = sr.str.length;
  const inner = new Array(n);
  const owners = new Array(n);
  const open = [];    // spans covering the cursor, innermost last
  const quotes = [];  // the QUOTE subset of `open`, innermost last
  let next = 0;
  for (let i = 0; i < n; i++) {
    while (open.length > 0 && open[open.length - 1].end <= i) {
      const done = open.pop();
      if (quotes.length > 0 && quotes[quotes.length - 1] === done) quotes.pop();
    }
    while (next < sr.spans.length && sr.spans[next].start === i) {
      const s = sr.spans[next];
      open.push(s);
      if (QUOTE_KINDS.indexOf(s.kind) !== -1) quotes.push(s);
      next += 1;
    }
    inner[i] = open.length === 0 ? null : open[open.length - 1];
    owners[i] = quotes.length === 0 ? null : quotes[quotes.length - 1];
  }
  const maps = { inner, owners };
  offsetCache.set(sr, maps);
  return maps;
}

// One character's contribution to a token's value: delimiters drop out, and
// backslash escapes resolve per the context they sit in. Returns the number of
// input characters consumed.
function appendValueChar(out, str, i, owner, limit) {
  const ch = str[i];
  const kind = owner === null ? "unquoted" : owner.kind;
  if (owner !== null && (i < owner.innerStart || i >= owner.innerEnd)) return [out, 1];
  if (kind === "sq" || kind === "ansic") return [out + ch, 1];
  if (ch === "\\" && i + 1 < limit) {
    const next = str[i + 1];
    if (kind === "unquoted") return [out + next, 2];
    if (next === '"' || next === "\\" || next === "`" || next === "$") return [out + next, 2];
  }
  return [out + ch, 1];
}

/**
 * tokenizeArgTail(str) -> { tokens: Token[], ok: boolean }
 *
 *   Token = { raw, start, end, value, pieces }
 *   Piece = { kind: "unquoted"|"dq"|"sq"|"ansic", start, end, text }
 *
 * Pieces cover [token.start, token.end) contiguously and each piece's `text` is
 * exactly str.slice(piece.start, piece.end) — quote delimiters belong to the
 * piece they open. An unparseable tail yields { tokens: [], ok: false }: any
 * token list derived from a guessed span boundary is the attacker's choice.
 */
function tokenizeArgTail(str) {
  if (typeof str !== "string") return { tokens: [], ok: false };
  const sr = scanSpans(str);
  if (!sr.ok) return { tokens: [], ok: false };

  const { inner, owners } = offsetMaps(sr);

  const tokens = [];
  let i = 0;
  while (i < str.length) {
    // Word boundaries are whitespace that no span covers — whitespace inside a
    // substitution body or a quote never splits a shell word.
    if (inner[i] === null && /\s/.test(str[i])) { i += 1; continue; }
    const start = i;
    while (i < str.length) {
      if (inner[i] === null) {
        if (/\s/.test(str[i])) break;
        if (str[i] === "\\") { i += 2; continue; }
      }
      i += 1;
    }
    const end = Math.min(i, str.length);
    tokens.push(makeToken(str, start, end, owners));
    i = end;
  }
  return { tokens, ok: true };
}

function makeToken(str, start, end, owners) {
  const pieces = [];
  let value = "";
  let cur = start;
  while (cur < end) {
    const owner = owners[cur];
    let pEnd = cur;
    while (pEnd < end && owners[pEnd] === owner) pEnd += 1;
    pieces.push({
      kind: owner === null ? "unquoted" : owner.kind,
      start: cur,
      end: pEnd,
      text: str.slice(cur, pEnd),
    });
    let i = cur;
    while (i < pEnd) {
      const [v, used] = appendValueChar(value, str, i, owner, pEnd);
      value = v;
      i += used;
    }
    cur = pEnd;
  }
  return { raw: str.slice(start, end), start, end, value, pieces };
}

// Rule 1: the piece list must exactly and contiguously cover [start,end) with
// non-empty pieces whose text reconstructs `raw`. Checked self-contained (no
// reference to the original string) so a handcrafted Token cannot slip through.
function isWellFormedToken(t) {
  if (t === null || typeof t !== "object") return false;
  if (typeof t.raw !== "string") return false;
  if (!isIdx(t.start) || !isIdx(t.end) || t.end < t.start) return false;
  if (!Array.isArray(t.pieces) || t.pieces.length === 0) return false;
  let cursor = t.start;
  let joined = "";
  for (const p of t.pieces) {
    if (p === null || typeof p !== "object") return false;
    if (PIECE_KINDS.indexOf(p.kind) === -1) return false;
    if (!isIdx(p.start) || !isIdx(p.end)) return false;
    if (p.start !== cursor || p.end <= p.start) return false;
    if (typeof p.text !== "string" || p.text.length !== p.end - p.start) return false;
    joined += p.text;
    cursor = p.end;
  }
  return cursor === t.end && joined === t.raw;
}

// Rule 4 for a dq piece: `\$` and `` \` `` are literal there, so only an
// UNESCAPED SET-B character introduces an expansion.
function hasUnescapedSetB(text) {
  for (let i = 0; i < text.length; i++) {
    if (text[i] === "\\") { i += 1; continue; }
    if (SET_B.test(text[i])) return true;
  }
  return false;
}

/** Rules 1-6 for a single Token. True means "unsafe — reject the command". */
function rejectsUnsafeToken(tok) {
  if (!isWellFormedToken(tok)) return true;
  for (const p of tok.pieces) {
    if (p.kind === "ansic") return true;
    if (p.kind === "unquoted") {
      if (SET_A_UNQUOTED.test(p.text)) return true;
      if (SET_B.test(p.text)) return true;
    } else if (p.kind === "dq" && hasUnescapedSetB(p.text)) {
      return true;
    }
  }
  return false;
}

/**
 * Whole-tail verdict under a named profile. True means "unsafe — reject".
 *
 * Structural characters are judged by POSITION rather than by presence: a
 * metacharacter inside a quote span is data. Substitution and ANSI-C spans are
 * rejected wherever they occur, because their content is re-parsed by the shell
 * and is therefore never data.
 */
function rejectsUnsafeArgTail(argTail, profile) {
  if (typeof argTail !== "string") return true;
  const prof = Object.prototype.hasOwnProperty.call(UNSAFE_PROFILES, profile)
    ? UNSAFE_PROFILES[profile]
    : null;
  if (prof === null) return true;

  const sr = scanSpans(argTail);
  if (!sr.ok) return true;
  // EXPANDING_KINDS is the scanner's own list of frames whose body the shell
  // re-parses (cmdsubst, backtick, subshell, arith); ANSI-C is quoted but
  // re-escaped. Taken from the scanner rather than re-listed here so a new kind
  // cannot be added upstream and silently fall through this gate (CPR-SSOT).
  for (const s of sr.spans) {
    if (s.kind === "ansic" || EXPANDING_KINDS.indexOf(s.kind) !== -1) return true;
  }
  // Raw (not span-aware) newline check: a newline the caller did not fold is a
  // command separator regardless of where it sits.
  if (/[\r\n]/.test(argTail)) return true;
  // Rule 4 at the tail level. `"a$HOME"` and a bare `$HOME` open no span at all,
  // so the sweep above cannot see them, yet the shell still expands both — and
  // rejectsUnsafeToken already answers `true` for that same text. The two
  // predicates must not disagree about the same bytes.
  if (hasExpandingSetB(sr)) return true;
  if (matchesOutsideQuotes(sr, prof.setA)) return true;
  return matchesOutsideQuotes(sr, prof.allowRedirectAmpersand ? /&(?!>)/ : /&/);
}

// True when an unescaped SET-B character sits where the shell would expand it —
// i.e. anywhere except inside a single-quoted or ANSI-C span.
function hasExpandingSetB(sr) {
  const { owners } = offsetMaps(sr);
  const str = sr.str;
  for (let i = 0; i < str.length; i++) {
    const owner = owners[i];
    const kind = owner === null ? "unquoted" : owner.kind;
    if (kind === "sq" || kind === "ansic") continue;
    if (str[i] === "\\") { i += 1; continue; }
    if (SET_B.test(str[i])) return true;
  }
  return false;
}

// True when `re` matches at a position that no quote span covers.
function matchesOutsideQuotes(sr, re) {
  const { owners } = offsetMaps(sr);
  const g = new RegExp(re.source, re.flags.indexOf("g") === -1 ? re.flags + "g" : re.flags);
  let m = g.exec(sr.str);
  while (m !== null) {
    if (m.index < owners.length && owners[m.index] === null) return true;
    if (m[0].length === 0) g.lastIndex += 1;
    m = g.exec(sr.str);
  }
  return false;
}

module.exports = {
  UNSAFE_PROFILES,
  tokenizeArgTail,
  rejectsUnsafeToken,
  rejectsUnsafeArgTail,
};
