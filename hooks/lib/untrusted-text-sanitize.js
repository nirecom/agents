"use strict";
// hooks/lib/untrusted-text-sanitize.js — sanitize and blockquote helpers for untrusted
// third-party text (issue bodies, titles, comments). Moved from issue-comments.js (#2924)
// so the issue snapshot and the comments renderer share one implementation (CPR-SSOT).

// WI-9 contract (CWE-77): workflow sentinels are stripped from untrusted content.
const SENTINEL_RE = /<<WORKFLOW_[A-Z_]+[^>]*>>/g;

// U+0085/U+2028/U+2029 end a line for a Markdown reader but survive a \n-only
// splitter, so a blockquote prefix never reaches the text behind them. The class is
// built from code points so no raw terminator sits in this source.
const EXOTIC_CLASS = ["0085", "2028", "2029"].map((cp) => "\\u" + cp).join("");
const EXOTIC_BREAK_RE = new RegExp(`[${EXOTIC_CLASS}]`, "g");
const ANY_BREAK_RE = new RegExp(`\\r\\n|[\\n\\r${EXOTIC_CLASS}]`, "g");

// #2063 C14: loop to a fixed point — deleting one token can splice a still-live opener back.
function stripSentinels(text) {
  if (typeof text !== "string") return "";
  let out = text;
  let prev;
  do {
    prev = out;
    out = out.replace(SENTINEL_RE, "");
  } while (out !== prev);
  return out;
}

// One-line values: every line terminator becomes a space so the value cannot open a second line.
function sanitizeInline(text) {
  return stripSentinels(String(text).replace(ANY_BREAK_RE, " "));
}

// Multi-line values: real breaks survive as LF (the blockquote prefix covers them); the rest flatten.
function sanitizeBlock(text) {
  const unified = String(text).replace(/\r\n/g, "\n").replace(/\r/g, "\n");
  return stripSentinels(unified.replace(EXOTIC_BREAK_RE, " "));
}

function quoteBlock(text) {
  return sanitizeBlock(text)
    .split("\n")
    .map((line) => (line === "" ? ">" : `> ${line}`))
    .join("\n");
}

module.exports = {
  SENTINEL_RE,
  EXOTIC_BREAK_RE,
  ANY_BREAK_RE,
  stripSentinels,
  sanitizeInline,
  sanitizeBlock,
  quoteBlock,
};
