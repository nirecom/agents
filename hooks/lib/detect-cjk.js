"use strict";
// CJK detection — Hiragana, Katakana, CJK Unified Ideographs, CJK Compatibility
// Ideographs, CJK Symbols/Punctuation, full-width forms.
// Hangul (U+AC00-U+D7AF) is intentionally EXCLUDED — only Japanese/Chinese.
// Use \u escapes (NOT literal chars) to avoid the U+F900 vs U+8C48 look-alike pitfall.
const CJK_RE = /[　-鿿豈-﫿＀-￯]/u;
function hasCJK(s) { return typeof s === "string" && CJK_RE.test(s); }
module.exports = { hasCJK, CJK_RE };
