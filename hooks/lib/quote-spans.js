"use strict";
// hooks/lib/quote-spans.js
// Barrel for the #1569 shared quote-span scanner. Dispatch + re-export only —
// all logic lives in ./quote-spans/{scan,query,transform}.js
// (rules/coding/file-split.md Pattern A).

const scan = require("./quote-spans/scan");
const query = require("./quote-spans/query");
const transform = require("./quote-spans/transform");

module.exports = {
  // scan
  scanSpans: scan.scanSpans,
  _resetCacheForTest: scan._resetCacheForTest,
  QUOTE_KINDS: scan.QUOTE_KINDS,
  EXPANDING_KINDS: scan.EXPANDING_KINDS,
  // query
  spanAt: query.spanAt,
  quoteContextAt: query.quoteContextAt,
  findOutsideQuotes: query.findOutsideQuotes,
  testOutsideQuotes: query.testOutsideQuotes,
  hasUnclosedQuoteSpan: query.hasUnclosedQuoteSpan,
  splitOutsideQuotes: query.splitOutsideQuotes,
  spanAwareNewlineSplit: query.spanAwareNewlineSplit,
  // transform
  blankQuoteSpans: transform.blankQuoteSpans,
  unwrapCmdSubstInDq: transform.unwrapCmdSubstInDq,
  foldNewlinesInSpans: transform.foldNewlinesInSpans,
};
