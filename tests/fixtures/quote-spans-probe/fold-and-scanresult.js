"use strict";
// tests/fixtures/quote-spans-probe/fold-and-scanresult.js
// Split out of tests/fixtures/quote-spans-probe.js per rules/coding/file-split.md
// (the parent crossed the 300-line WARN threshold). Entrypoint-private: nothing
// but the probe requires this.
//
// Two op families live here:
//   foldfix / foldvsold — foldNewlinesInSpans(str, kinds), the SELECTOR form
//   srsame / srdoctored — the query API fed a precomputed ScanResult instead of
//                         a raw string
//
// handle() returns the output line, or null when `op` belongs to the parent.

const path = require("path");

// Fold fixtures live here rather than in argv: a newline inside a shell arg is
// exactly what is under test, and round-tripping it through bash quoting would
// make the fixture the thing being debugged.
//
//   mixed — one newline in EACH context: dq, sq, ansic, cmdsubst body, backtick
//           body, and bare (unquoted). A kinds selector must move exactly the
//           newlines of the named kinds and leave the other five alone.
//   dqcmd — a newline directly inside DQ and another inside a $() nested in
//           that DQ, i.e. the case where "innermost span" and "any enclosing
//           span" readings of the selector diverge.
//   bare  — no quotes at all; nothing may move for any selector.
const FOLD_FIXTURES = {
  mixed: 'p "a\nb" q \'c\nd\' r $\'e\nf\' s $(echo g\nh) t `echo u\nv` w\nx',
  dqcmd: '"a\n$(echo b\nc)\nd"',
  bare: "a\nb",
};

// kinds accepts JSON (["dq"]) or a glob-safe comma list (dq,sq) — bash would
// treat a bare [..] argument as a character-class glob.
function parseKinds(spec) {
  if (spec === undefined || spec === "") return undefined;
  return spec.trim().startsWith("[")
    ? JSON.parse(spec)
    : spec.split(",").map((k) => k.trim());
}

function handle(op, ctx) {
  const { api, str, a1, a2 } = ctx;
  switch (op) {
    // foldfix <fixture> <kinds> — printed as JSON so the expectation pins every
    // byte, including which newlines did and did not move.
    case "foldfix": {
      const s = FOLD_FIXTURES[str];
      if (s === undefined) return "ERROR: no fold fixture " + str;
      const kinds = parseKinds(a1);
      const r = kinds === undefined
        ? api.foldNewlinesInSpans(s)
        : api.foldNewlinesInSpans(s, kinds);
      return "ok=" + String(r.ok) + ",out=" + JSON.stringify(r.out);
    }
    // foldvsold <fixture> — the plan calls foldNewlinesInSpans(str,["dq"]) a
    // COMPLETE replacement for worker-script.js's foldDqNewlines, so the two
    // must agree byte-for-byte on any input, including ones the differential
    // corpus does not carry (e.g. a newline inside $() nested in DQ).
    case "foldvsold": {
      const s = FOLD_FIXTURES[str];
      if (s === undefined) return "ERROR: no fold fixture " + str;
      const oldFold = require(
        path.join(__dirname, "..", "quote-spans-frozen", "fold-dq-newlines.js")
      ).foldDqNewlines;
      const r = api.foldNewlinesInSpans(s, ["dq"]);
      return "same=" + String(r.out === oldFold(s)) + ",ok=" + String(r.ok);
    }

    // The query module is specified to accept EITHER a raw string OR a
    // ScanResult. `srsame` proves the two forms answer identically...
    case "srsame": {
      const sr = api.scanSpans(str);
      const i = Number(a1);
      const answers = (src) => [
        String((api.spanAt(src, i) || {}).kind),
        String(api.quoteContextAt(src, i)),
        String(api.findOutsideQuotes(src, a2)),
        String(api.testOutsideQuotes(src, a2)),
        String(api.hasUnclosedQuoteSpan(src)),
      ].join("|");
      const byStr = answers(str);
      return "same=" + String(byStr === answers(sr)) + ",answers=" + byStr;
    }
    // ...and `srdoctored` proves the ScanResult form is actually consumed
    // rather than silently rescanned, by handing over a result whose spans have
    // been emptied: the answers must follow the RESULT, not the string.
    case "srdoctored": {
      const sr = api.scanSpans(str);
      const doctored = {
        spans: [], ok: sr.ok, failReason: sr.failReason,
        failKinds: sr.failKinds, str: str,
      };
      const i = Number(a1);
      const span = api.spanAt(doctored, i);
      return "span=" + (span === null || span === undefined ? "null" : span.kind) +
             ",ctx=" + String(api.quoteContextAt(doctored, i));
    }
    default:
      return null;
  }
}

module.exports = { handle, FOLD_FIXTURES };
