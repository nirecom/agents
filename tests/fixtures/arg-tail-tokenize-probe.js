"use strict";
// tests/fixtures/arg-tail-tokenize-probe.js
// CLI probe over hooks/enforce-worktree/arg-tail-guard.js (#1569).
//
// Usage: node arg-tail-tokenize-probe.js <op> <argTail> [args...]
//
// Prints exactly one line and always exits 0, so the bash caller can assert on
// the text — including the `ERROR: ...` form emitted while the module is still
// missing, which is the expected RED signal before C3 lands.

const path = require("path");

const AGENTS_DIR = path.resolve(__dirname, "..", "..");
const MODULE_PATH = path.join(
  AGENTS_DIR, "hooks", "enforce-worktree", "arg-tail-guard.js"
);

const line1 = (s) => String(s).split("\n")[0];

let mod = null;
try {
  mod = require(MODULE_PATH);
} catch (e) {
  console.log("ERROR: require arg-tail-guard.js: " + line1(e.message));
  process.exit(0);
}

const op = process.argv[2] || "";
const tail = process.argv[3] === undefined ? "" : process.argv[3];
const a1 = process.argv[4];
const a2 = process.argv[5];

function need(name) {
  if (typeof mod[name] !== "function") {
    console.log("ERROR: " + name + " is not exported");
    process.exit(0);
  }
  return mod[name];
}

function tokenize() {
  return need("tokenizeArgTail")(tail);
}

// A piece renders as kind@start-end:text so one string pins all four fields.
const showPiece = (p) => p.kind + "@" + p.start + "-" + p.end + ":" + p.text;

// Contiguous, hole-free, in-order coverage of [token.start, token.end), with
// every piece's `text` equal to the corresponding slice of the arg tail.
function coverageProblem(t, str) {
  if (!Array.isArray(t.pieces) || t.pieces.length === 0) return "no-pieces";
  let cursor = t.start;
  for (const p of t.pieces) {
    if (p.start !== cursor) return "hole-at-" + cursor;
    if (p.end <= p.start) return "empty-piece-at-" + p.start;
    if (p.text !== str.slice(p.start, p.end)) return "text-mismatch-at-" + p.start;
    cursor = p.end;
  }
  if (cursor !== t.end) return "short-by-" + (t.end - cursor);
  if (t.raw !== str.slice(t.start, t.end)) return "raw-mismatch";
  return "";
}

// ---------------------------------------------------------------------------
// Handcrafted malformed Token objects (rule 1: fail closed).
//
// rejectsUnsafeToken is otherwise only ever fed tokens the tokenizer produced,
// i.e. well-formed ones, so an implementation that TRUSTED its input — no
// coverage check at all — would pass every other row in the suite. Rule 1
// requires rejection whenever the piece list does not exactly and contiguously
// cover [start,end) with non-empty pieces whose text reconstructs `raw`.
//
// `base` is the only shape that may be accepted; it exists so a
// reject-everything implementation cannot satisfy this table either.
const P = (kind, start, end, text) => ({ kind, start, end, text });
const BAD_TOKENS = {
  base:            { raw: "abc", start: 0, end: 3, value: "abc", pieces: [P("unquoted", 0, 3, "abc")] },
  hole:            { raw: "abc", start: 0, end: 3, value: "abc", pieces: [P("unquoted", 0, 1, "a"), P("unquoted", 2, 3, "c")] },
  overlap:         { raw: "abc", start: 0, end: 3, value: "abc", pieces: [P("unquoted", 0, 2, "ab"), P("unquoted", 1, 3, "bc")] },
  outoforder:      { raw: "abc", start: 0, end: 3, value: "abc", pieces: [P("unquoted", 2, 3, "c"), P("unquoted", 0, 2, "ab")] },
  empty:           { raw: "abc", start: 0, end: 3, value: "abc", pieces: [P("unquoted", 0, 1, "a"), P("unquoted", 1, 1, ""), P("unquoted", 1, 3, "bc")] },
  short:           { raw: "abc", start: 0, end: 3, value: "abc", pieces: [P("unquoted", 0, 2, "ab")] },
  overrun:         { raw: "abc", start: 0, end: 3, value: "abc", pieces: [P("unquoted", 0, 5, "abcde")] },
  startsafter:     { raw: "abc", start: 0, end: 3, value: "abc", pieces: [P("unquoted", 1, 3, "bc")] },
  reversedpiece:   { raw: "abc", start: 0, end: 3, value: "abc", pieces: [P("unquoted", 2, 1, "b"), P("unquoted", 1, 3, "bc")] },
  reversedtoken:   { raw: "abc", start: 3, end: 0, value: "abc", pieces: [P("unquoted", 0, 3, "abc")] },
  negative:        { raw: "abc", start: -1, end: 3, value: "abc", pieces: [P("unquoted", -1, 3, "abc")] },
  textmismatch:    { raw: "abc", start: 0, end: 3, value: "abc", pieces: [P("unquoted", 0, 3, "xyz")] },
  rawmismatch:     { raw: "zzz", start: 0, end: 3, value: "abc", pieces: [P("unquoted", 0, 3, "abc")] },
  nopieces:        { raw: "abc", start: 0, end: 3, value: "abc", pieces: [] },
  piecesmissing:   { raw: "abc", start: 0, end: 3, value: "abc" },
  piecesnotarray:  { raw: "abc", start: 0, end: 3, value: "abc", pieces: "abc" },
  piecenull:       { raw: "abc", start: 0, end: 3, value: "abc", pieces: [null] },
  badkind:         { raw: "abc", start: 0, end: 3, value: "abc", pieces: [P("dqq", 0, 3, "abc")] },
  floatbounds:     { raw: "abc", start: 0, end: 3, value: "abc", pieces: [P("unquoted", 0, 2.5, "ab"), P("unquoted", 2.5, 3, "c")] },
  boundsnan:       { raw: "abc", start: 0, end: NaN, value: "abc", pieces: [P("unquoted", 0, 3, "abc")] },
  boundsstring:    { raw: "abc", start: "0", end: "3", value: "abc", pieces: [P("unquoted", "0", "3", "abc")] },
  rawmissing:      { start: 0, end: 3, value: "abc", pieces: [P("unquoted", 0, 3, "abc")] },
  nulltoken:       null,
  notanobject:     "abc",
};

try {
  switch (op) {
    // rejshape <name> — rejectsUnsafeToken on a handcrafted Token (see above).
    case "rejshape": {
      const f = need("rejectsUnsafeToken");
      if (!(tail in BAD_TOKENS)) { console.log("ERROR: no shape " + JSON.stringify(tail)); break; }
      console.log(String(f(BAD_TOKENS[tail])));
      break;
    }
    case "ok":
      console.log(String(tokenize().ok));
      break;
    case "n":
      console.log(String(tokenize().tokens.length));
      break;
    case "raws":
      console.log(JSON.stringify(tokenize().tokens.map((t) => t.raw)));
      break;
    case "values":
      console.log(JSON.stringify(tokenize().tokens.map((t) => t.value)));
      break;
    // "0-3,4-9" — every token's half-open [start,end) in order.
    case "bounds":
      console.log(tokenize().tokens.map((t) => t.start + "-" + t.end).join(","));
      break;
    // tok <i> <field>
    case "tok": {
      const t = tokenize().tokens[Number(a1)];
      console.log(t === undefined ? "MISSING" : String(t[a2]));
      break;
    }
    // pieces <i> — full provenance of one token
    case "pieces": {
      const t = tokenize().tokens[Number(a1)];
      console.log(t === undefined ? "MISSING" : t.pieces.map(showPiece).join(","));
      break;
    }
    case "piecekinds": {
      const t = tokenize().tokens[Number(a1)];
      console.log(t === undefined ? "MISSING" : t.pieces.map((p) => p.kind).join(","));
      break;
    }
    // Coverage of every token: "ok" or the first problem found.
    case "cover": {
      const r = tokenize();
      let problem = "";
      for (const t of r.tokens) {
        problem = coverageProblem(t, tail);
        if (problem) break;
      }
      console.log(problem || "ok");
      break;
    }
    // rejtok <i> — rejectsUnsafeToken on a single token
    case "rejtok": {
      const f = need("rejectsUnsafeToken");
      const t = tokenize().tokens[Number(a1)];
      console.log(t === undefined ? "MISSING" : String(f(t)));
      break;
    }
    // reject <profile> — rejectsUnsafeArgTail(argTail, profile)
    case "reject":
      console.log(String(need("rejectsUnsafeArgTail")(tail, a1)));
      break;
    // bench <bytes> <ceilingMs> — cost ceiling for tokenizeArgTail.
    //
    // The input is built HERE rather than passed through argv: a 128 KB
    // argument would hit the platform arg-length limit, and the measurement
    // must not include bash's own quoting of the fixture.
    //
    // Prints "fast" only when the tail parsed, produced the expected token
    // count, AND finished under the ceiling — so an implementation that got
    // fast by bailing out early (ok:false) or by mis-splitting the words
    // cannot buy the row.
    case "bench": {
      const f = need("tokenizeArgTail");
      const bytes = Number(tail);
      const ceiling = Number(a1);
      if (!Number.isFinite(bytes) || !Number.isFinite(ceiling)) {
        console.log("ERROR: bench needs numeric <bytes> <ceilingMs>");
        break;
      }
      // One word per unit, each carrying a dq span with an sq span inside it —
      // the span-count growth is what a per-character full-span-list rescan
      // turns into O(n^2).
      const unit = '"\'\'" ';
      const units = Math.max(1, Math.round(bytes / unit.length));
      const input = unit.repeat(units);
      const t0 = process.hrtime.bigint();
      const r = f(input);
      const ms = Number(process.hrtime.bigint() - t0) / 1e6;
      const took = String(Math.round(ms));
      if (r.ok !== true) { console.log("parse-failed-in-" + took + "ms"); break; }
      if (r.tokens.length !== units) { console.log("wrong-token-count-" + r.tokens.length); break; }
      console.log(ms < ceiling ? "fast" : "slow:" + took + "ms>=" + ceiling + "ms");
      break;
    }
    // Profile table shape: the three documented profile names must all exist.
    case "profiles": {
      const t = mod.UNSAFE_PROFILES;
      if (!t) { console.log("ERROR: UNSAFE_PROFILES is not exported"); break; }
      console.log(Object.keys(t).sort().join(","));
      break;
    }
    // profileflag <profile> <flag>
    case "profileflag": {
      const t = mod.UNSAFE_PROFILES;
      if (!t) { console.log("ERROR: UNSAFE_PROFILES is not exported"); break; }
      const p = t[tail];
      console.log(p === undefined ? "MISSING" : String(p[a1]));
      break;
    }
    default:
      console.log("ERROR: unknown op " + JSON.stringify(op));
  }
} catch (e) {
  console.log("ERROR: threw " + line1(e.message));
}
