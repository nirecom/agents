"use strict";
// tests/fixtures/quote-spans-probe.js
// Thin CLI probe over hooks/lib/quote-spans.js (the #1569 barrel).
// Prints a single scalar line so bash table-driven tests can assert on it.
//
// STATUS: every op below fails with `ERROR: <msg>` until C1 (quote-spans core)
// lands. That failure mode is deliberate — an implementation-missing failure,
// not a test bug.
//
// Usage: node quote-spans-probe.js <op> <str> [args...]
//
// The fold-selector (foldfix/foldvsold) and precomputed-ScanResult
// (srsame/srdoctored) ops live in ./quote-spans-probe/fold-and-scanresult.js
// and are reached through the default branch of the switch below.

const path = require("path");

const AGENTS_DIR = path.resolve(__dirname, "..", "..");
const BARREL = path.join(AGENTS_DIR, "hooks", "lib", "quote-spans.js");

function out(v) {
  process.stdout.write(String(v));
}

let api;
try {
  api = require(BARREL);
} catch (e) {
  out("ERROR: require quote-spans.js: " + e.message);
  process.exit(0);
}

const op = process.argv[2];
const str = process.argv[3] === undefined ? "" : process.argv[3];
const a1 = process.argv[4];
const a2 = process.argv[5];
const a3 = process.argv[6];

// Spans of a given kind in start order. kind "*" = all kinds.
function spansOfKind(spans, kind) {
  return kind === "*" ? spans : spans.filter((s) => s.kind === kind);
}

function scan() {
  return api.scanSpans(str);
}

// Pattern spec: "re:/<source>/<flags>" -> RegExp, anything else -> string literal.
function parsePattern(spec) {
  if (typeof spec !== "string") return spec;
  const m = spec.match(/^re:\/([\s\S]*)\/([a-z]*)$/);
  return m ? new RegExp(m[1], m[2]) : spec;
}

// Opts spec: JSON object. `contexts` arrives as an array and becomes a Set.
function parseOpts(spec) {
  if (spec === undefined || spec === "") return undefined;
  const o = JSON.parse(spec);
  if (Array.isArray(o.contexts)) o.contexts = new Set(o.contexts);
  return o;
}

// Non-string scanner inputs, addressed by name (bash cannot pass null/objects).
const NON_STRING_INPUTS = {
  null: null,
  undefined: undefined,
  number: 42,
  object: { a: 1 },
  array: ["a"],
  bool: true,
  empty: "",
};


try {
  switch (op) {
    // ---- scan-level -------------------------------------------------------
    case "ok":
      out(String(scan().ok));
      break;
    case "failreason":
      out(String(scan().failReason === undefined ? "undefined" : scan().failReason));
      break;
    case "failkinds": {
      const r = scan();
      const ks = Array.isArray(r.failKinds) ? r.failKinds.slice() : [];
      out(Array.from(new Set(ks)).sort().join(","));
      break;
    }
    case "count":
      out(String(spansOfKind(scan().spans, a1).length));
      break;
    case "kinds":
      out(scan().spans.map((s) => s.kind).join(","));
      break;
    case "spanfield": {
      // spanfield <kind> <nth> <field>
      const sel = spansOfKind(scan().spans, a1);
      const s = sel[Number(a2)];
      out(s === undefined ? "MISSING" : String(s[a3]));
      break;
    }
    case "spantext": {
      const sel = spansOfKind(scan().spans, a1);
      const s = sel[Number(a2)];
      out(s === undefined ? "MISSING" : str.slice(s.start, s.end));
      break;
    }
    case "innertext": {
      const sel = spansOfKind(scan().spans, a1);
      const s = sel[Number(a2)];
      out(s === undefined ? "MISSING" : str.slice(s.innerStart, s.innerEnd));
      break;
    }
    case "parentkind": {
      // parentkind <kind> <nth> — kind of the parent span (or "null")
      const r = scan();
      const sel = spansOfKind(r.spans, a1);
      const s = sel[Number(a2)];
      if (s === undefined) { out("MISSING"); break; }
      out(s.parent === null || s.parent === undefined ? "null" : String(r.spans[s.parent].kind));
      break;
    }

    // ---- query ------------------------------------------------------------
    case "spanatkind": {
      const s = api.spanAt(str, Number(a1));
      out(s === null || s === undefined ? "null" : String(s.kind));
      break;
    }
    case "ctxat":
      out(String(api.quoteContextAt(str, Number(a1))));
      break;
    case "ctxset": {
      const seen = new Set();
      for (let i = 0; i < str.length; i++) seen.add(String(api.quoteContextAt(str, i)));
      out(Array.from(seen).sort().join(","));
      break;
    }
    case "find":
      out(String(api.findOutsideQuotes(str, a1)));
      break;
    case "test":
      out(String(api.testOutsideQuotes(str, a1)));
      break;
    case "unclosed": {
      // unclosed [kinds-csv] — omit a1 to exercise the default kinds
      if (a1 === undefined || a1 === "") out(String(api.hasUnclosedQuoteSpan(str)));
      else out(String(api.hasUnclosedQuoteSpan(str, a1.split(","))));
      break;
    }
    case "split": {
      // split <sep> — prints ok=<bool>,n=<count>,first_is_input=<bool>
      const r = api.splitOutsideQuotes(str, a1);
      const parts = r.parts;
      out("ok=" + String(r.ok) + ",n=" + parts.length + ",first_is_input=" + String(parts[0] === str));
      break;
    }
    case "splitparts": {
      const r = api.splitOutsideQuotes(str, a1);
      out(JSON.stringify(r.parts));
      break;
    }
    case "nlsplit": {
      const r = api.spanAwareNewlineSplit(str);
      const lines = r.lines;
      out("ok=" + String(r.ok) + ",n=" + lines.length + ",first_is_input=" + String(lines[0] === str));
      break;
    }
    case "nlsplitlines": {
      const r = api.spanAwareNewlineSplit(str);
      out(JSON.stringify(r.lines));
      break;
    }

    // ---- query with opts (contexts / includeCmdSubstBody / onAmbiguous) ----
    // findo  <pattern-spec> <opts-json> -> index
    // testo  <pattern-spec> <opts-json> -> boolean
    // splito <pattern-spec> <opts-json> -> JSON parts array
    // nlsplito <opts-json>              -> JSON lines array
    case "findo":
      out(String(api.findOutsideQuotes(str, parsePattern(a1), parseOpts(a2))));
      break;
    case "testo":
      out(String(api.testOutsideQuotes(str, parsePattern(a1), parseOpts(a2))));
      break;
    case "splito": {
      const r = api.splitOutsideQuotes(str, parsePattern(a1), parseOpts(a2));
      out("ok=" + String(r.ok) + ",parts=" + JSON.stringify(r.parts));
      break;
    }
    case "nlsplito": {
      const r = api.spanAwareNewlineSplit(str, parseOpts(a1));
      out("ok=" + String(r.ok) + ",lines=" + JSON.stringify(r.lines));
      break;
    }
    // Global-flag hygiene: a caller-supplied /g RegExp carries lastIndex state.
    // Calling twice with the SAME RegExp object must give the same answer, and
    // the caller's lastIndex must not be left mutated.
    case "gflag": {
      const re = parsePattern(a1);
      const first = api.findOutsideQuotes(str, re);
      const second = api.findOutsideQuotes(str, re);
      out("first=" + String(first) + ",second=" + String(second) +
          ",lastIndex=" + String(re.lastIndex));
      break;
    }

    // ---- non-string / degenerate inputs -----------------------------------
    // badinput <name> — scanSpans on a non-string value must not throw.
    // The fixture NAME occupies the documented <str> slot (argv[3]); reading it
    // from a1 silently scanned `undefined` for every row.
    case "badinput": {
      const v = NON_STRING_INPUTS[str];
      const r = api.scanSpans(v);
      out("ok=" + String(r.ok) + ",spans=" + (Array.isArray(r.spans) ? r.spans.length : "NOTARRAY") +
          ",reason=" + String(r.failReason === undefined ? "undefined" : r.failReason));
      break;
    }
    // badpredicate <name> — the danger-side answer for a non-string input.
    case "badpredicate": {
      const v = NON_STRING_INPUTS[str];
      out("test=" + String(api.testOutsideQuotes(v, "x")) +
          ",find=" + String(api.findOutsideQuotes(v, "x")) +
          ",unclosed=" + String(api.hasUnclosedQuoteSpan(v)));
      break;
    }
    // Long nested input built in-process (bash argv cannot carry it safely).
    // longnest <depth> — depth levels of $( " ' ... ' " ) then closed.
    case "longnest": {
      const d = Number(str) || 200;
      const s = '$(echo "' .repeat(d) + "x" + '")' .repeat(d);
      const r = api.scanSpans(s);
      out("ok=" + String(r.ok) + ",spans=" + r.spans.length);
      break;
    }

    // ---- transform --------------------------------------------------------
    case "transform": {
      // transform <name> — prints ok=<bool>,unchanged=<bool>
      const fn = { blank: api.blankQuoteSpans, fold: api.foldNewlinesInSpans, unwrap: api.unwrapCmdSubstInDq }[a1];
      if (typeof fn !== "function") { out("ERROR: no transform " + a1); break; }
      const r = fn(str);
      out("ok=" + String(r.ok) + ",unchanged=" + String(r.out === str));
      break;
    }
    case "transformout": {
      const fn = { blank: api.blankQuoteSpans, fold: api.foldNewlinesInSpans, unwrap: api.unwrapCmdSubstInDq }[a1];
      if (typeof fn !== "function") { out("ERROR: no transform " + a1); break; }
      out(JSON.stringify(fn(str).out));
      break;
    }

    // ---- memoization ------------------------------------------------------
    case "memoid": {
      // Same input twice → same cached object; after reset → fresh object.
      const x = api.scanSpans(str);
      const y = api.scanSpans(str);
      api._resetCacheForTest();
      const z = api.scanSpans(str);
      out("same=" + String(x === y) + ",after_reset=" + String(x === z));
      break;
    }
    case "memolru": {
      // 8-entry LRU: scanning 8 other strings evicts the first entry.
      api._resetCacheForTest();
      const x = api.scanSpans(str);
      for (let i = 0; i < 8; i++) api.scanSpans("filler-" + i + "-'q'");
      const y = api.scanSpans(str);
      out("evicted=" + String(x !== y));
      break;
    }

    default: {
      // Ops split out per rules/coding/file-split.md (fold selector +
      // precomputed-ScanResult families, then the deep-nesting family).
      const ctx = { api, str, a1, a2 };
      let extra = require("./quote-spans-probe/fold-and-scanresult.js").handle(op, ctx);
      if (extra === null) {
        extra = require("./quote-spans-probe/deep-recursion.js").handle(op, ctx);
      }
      out(extra === null ? "ERROR: unknown op " + op : extra);
      break;
    }
  }
} catch (e) {
  out("ERROR: " + e.message);
}
process.stdout.write("\n");
