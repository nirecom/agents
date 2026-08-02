"use strict";
// hooks/lib/substitution-spans.js
// "Where does an EXPANDING substitution span start and end?" — answered from the
// #1569 span scanner (./quote-spans/scan.js) rather than from a second hand-rolled
// walk.
//
// #1780 round-11 CAUSE-2. `hooks/lib/command-parser.js` hand-rolled its own
// character walks (tokenizeSegment / tokenizeSegmentWithQuotes /
// splitSegmentsWithSeparators) that knew about `"`, `'` and `$'` and NOTHING
// else. An UNQUOTED substitution containing whitespace was therefore torn apart:
//
//     touch `printf '%s%s' <wf>/s1.workflow -off`     -> ALLOW (measured)
//     touch $(printf '%s%s' <wf>/s1.workflow -off)    -> ALLOW (measured)
//     echo x > `printf '%s%s' <wf>/s1.workflow -off`  -> ALLOW (measured)
//
// The backtick form split on WHITESPACE into `` `printf ``/`%s%s`/`<wf>/s1.workflow``
// /``-off` `` and the `$( )` form additionally split on the PARENS into three
// segments — so no single token was ever the write target the shell actually
// lands on, and every target-classifying rule (redirect-raw, argv, workflow-dir
// qualifier) looked at fragments instead. `hooks/lib/session-markers.js`
// authorizes WORKFLOW_OFF / WORKTREE_OFF / issue-close-verified on file
// EXISTENCE alone, so a single such `touch` forges those grants.
//
// This is a CPR-2 defect before it is a security defect: ./quote-spans/scan.js
// already IS the single source of truth for this grammar (it models cmdsubst,
// backtick, subshell and arith frames, with `case … esac` and dq-nesting rules
// the ad-hoc walks never had). The parser duplicated it badly, and the two
// disagreed. Nothing here re-implements the grammar; it only projects the SSOT
// scan into the "does a span start at index i, and where does it end" lookup the
// parser walks need.
//
// DIRECTION DISCIPLINE: this module is consumed in the DETECTION direction —
// preserving a span keeps MORE text inside one candidate target, which can only
// add a classification, never clear one. It therefore fails WIDE: an unclosed or
// unscannable span simply reports "no span here" and the caller degrades to its
// previous character-by-character behaviour rather than swallowing the rest of
// the line.

const { scanSpans } = require("./quote-spans/scan");

// Deliberately NOT the SSOT's EXPANDING_KINDS: that set also contains
// "subshell" (a bare `(`), and a bare `(` / `)` pair is what
// splitSegmentsWithSeparators() uses to promote a subshell body — and a process
// substitution body `<(cmd)` / `>(cmd)` — to its own scanned segment. Preserving
// those spans as one opaque token would REMOVE that segment, i.e. lose a reading
// that blocks today. Only the three kinds whose delimiters are unambiguous
// substitution syntax are preserved here (CPR-8: the exception is named and
// bounded rather than left implicit).
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

// ---------------------------------------------------------------------------
// SOURCE ORDER of a span-preserving parse's segments.
//
// #1780 round-13 (index-vs-source-order): the span-preserving parse is a SECOND,
// ADDITIVE reading, and its segments are APPENDED after the ordinary ones by
// hooks/block-off-clearance-write/bash-scan/scan.js. Array position in that
// merged list therefore carries no source-order meaning for the appended tail —
// but the index-based helpers commandCwd() and priorAssignmentsText() both scan
// `segments[0..idx)` precisely BECAUSE they assume it does. An appended span
// segment consequently inherited the `cd` / assignment state of every ordinary
// segment, including the ones that occur LATER in the command text:
//
//     echo x > $(printf '%s' 's1.workflow') ; cd /tmp
//
// Here the trailing `cd /tmp` sits at a LOWER merged index than the span segment
// for the redirect, so commandCwd() resolved the span segment's relative target
// against /tmp — a directory the shell had not entered yet when that write ran.
// That is a cwd the qualifier can be steered to from outside the workflow dir,
// i.e. it can CLEAR a block, which is the direction this hook may never fail in.
//
// The fix keeps the merged list (it is what every non-order-sensitive rule
// consumes) and records, on each span segment, the reading it came from and its
// index inside it. tagSourceOrder() is applied to the span parse's FULL segment
// list before the caller dedups against the ordinary parse, so the recorded
// index stays faithful to the span reading even after filtering.
//
// The property is NON-ENUMERABLE: segment objects are compared, keyed and
// snapshotted elsewhere (segmentKey in bash-scan/scan.js, redirects snapshots in
// command-ir.js), and none of those may start seeing a new field.
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
