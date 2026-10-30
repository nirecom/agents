"use strict";
// Shared ERE matching of the envClearLine parts (#2507 D7): bash `[[ =~ ]]` semantics through
// hooks/lib/ere. An invalid ERE matches nothing (bash rc 2); an untranslatable one throws, so the
// caller fails closed on that line.
const path = require("node:path");

const ERE_DIR = path.join(__dirname, "..", "..", "..", "ere");
const cache = new Map();

function compile(ere) {
  if (cache.has(ere)) return cache.get(ere);
  const res = require(path.join(ERE_DIR, "translate.js")).translateEre(ere);
  if (res.status === "untranslatable") throw new Error(`envClearLine: untranslatable ERE: ${res.reason}`);
  const regex = res.status === "ok" ? res.regex : null;
  cache.set(ere, regex);
  return regex;
}

function test(ere, text) {
  const regex = compile(ere);
  if (!regex) return false;
  regex.lastIndex = 0;
  return regex.test(text);
}

// longest(ere, text) — the leftmost-longest match text, or null (also for an invalid ERE).
function longest(ere, text) {
  const regex = compile(ere);
  if (!regex) return null;
  regex.lastIndex = 0;
  const m = require(path.join(ERE_DIR, "longest.js")).leftmostLongest(regex, text);
  return m ? m.text : null;
}

const stripCr = (s) => (s.endsWith("\r") ? s.slice(0, -1) : s);

module.exports = { test, longest, stripCr };
