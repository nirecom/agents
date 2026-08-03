"use strict";
// hooks/lib/substitution-spans.js
// Locates unquoted $(...) / `...` / $((...)) substitution spans via the
// existing quote-spans scanner instead of a second hand-rolled walk — the
// prior tokenizer split on whitespace/quotes only, so an unquoted
// substitution containing whitespace let write targets evade detection.
// Detection-direction: fails WIDE — an unscannable span degrades to the
// caller's prior char-by-char behavior rather than swallowing the line.

const { scanSpans } = require("./quote-spans/scan");

// Excludes "subshell" (bare `(`) from the SSOT's EXPANDING_KINDS: a bare
// `(`/`)` pair is what promotes a subshell or process-substitution body to
// its own scanned segment, and preserving it as one token would drop that.
const PRESERVED_SPAN_KINDS = new Set(["cmdsubst", "backtick", "arith"]);

// `${…}` parameter expansion is the fourth member of the same class (a span the
// shell replaces, whose body may hold whitespace — `${x:-<wf>/s1.workflow -off}`)
// but ./quote-spans/scan.js does not model it as a frame kind. Matched here with
// a brace counter rather than by widening the SSOT scanner, whose span list is
// pinned by its own consumers. Returns the exclusive end index, or -1.
function braceExpansionEnd(str, i) {
  if (str[i] !== "$" || str[i + 1] !== "{") return -1;
  let depth = 0;
  for (let j = i + 1; j < str.length; j++) {
    const c = str[j];
    if (c === "\\") { j += 1; continue; }
    if (c === "'" || c === '"') {
      const q = c;
      j += 1;
      while (j < str.length && str[j] !== q) {
        if (q === '"' && str[j] === "\\") j += 1;
        j += 1;
      }
      continue;
    }
    if (c === "{") depth += 1;
    else if (c === "}") {
      depth -= 1;
      if (depth === 0) return j + 1;
    }
  }
  return -1;
}

// substitutionSpanEnds(str) -> Map<startIndex, exclusiveEndIndex>
// Only CLOSED spans are recorded; an unbalanced input yields no entries for the
// frames still open at EOF, which is the fail-wide degrade described above.
function substitutionSpanEnds(str) {
  const ends = new Map();
  if (typeof str !== "string" || str === "") return ends;
  let res;
  try {
    res = scanSpans(str);
  } catch (_e) {
    return ends;
  }
  if (!res || !Array.isArray(res.spans)) return ends;
  for (const s of res.spans) {
    if (!s || s.closed !== true) continue;
    if (!PRESERVED_SPAN_KINDS.has(s.kind)) continue;
    const prev = ends.get(s.start);
    if (prev === undefined || s.end > prev) ends.set(s.start, s.end);
  }
  return ends;
}

// spanEndAt(str, i, ends) -> exclusive end index of a substitution span starting
// at `i`, or -1. `ends` is the map from substitutionSpanEnds(str).
function spanEndAt(str, i, ends) {
  const e = ends && ends.get(i);
  if (typeof e === "number" && e > i) return e;
  const b = braceExpansionEnd(str, i);
  return b > i ? b : -1;
}

// SOURCE ORDER of a span-preserving parse's segments.
// The span-preserving parse is additive — its segments are APPENDED after the
// ordinary ones, so array position no longer reflects source order. Helpers
// that scan `segments[0..idx)` for cwd/assignment state then picked up state
// from segments occurring LATER in the command text, letting a write target's
// cwd be steered (e.g. via a trailing `cd`) to escape a block it should hit.
// Each span segment carries its own (list, idx) non-enumerably to fix that.
const SOURCE_ORDER_KEY = "sourceOrder";

function tagSourceOrder(segments) {
  if (!Array.isArray(segments)) return segments;
  segments.forEach((seg, idx) => {
    if (!seg || typeof seg !== "object") return;
    try {
      Object.defineProperty(seg, SOURCE_ORDER_KEY, {
        value: { list: segments, idx },
        enumerable: false,
        writable: true,
        configurable: true,
      });
    } catch (_e) { /* fail-soft: an unwritable segment simply keeps index order */ }
  });
  return segments;
}

// sourceOrderView(segments, idx) -> { segments, idx }: the list and index an
// order-sensitive helper should scan for `segments[idx]`. Untagged (ordinary)
// segments get the caller's own list back unchanged, so behaviour is identical
// to the pre-fix code everywhere the merged tail is not involved.
function sourceOrderView(segments, idx) {
  const list = Array.isArray(segments) ? segments : [];
  const seg = list[idx];
  const so = seg && seg[SOURCE_ORDER_KEY];
  if (so && Array.isArray(so.list) && typeof so.idx === "number" && so.idx >= 0) {
    return { segments: so.list, idx: so.idx };
  }
  return { segments: list, idx };
}

module.exports = {
  substitutionSpanEnds,
  spanEndAt,
  PRESERVED_SPAN_KINDS,
  tagSourceOrder,
  sourceOrderView,
};
