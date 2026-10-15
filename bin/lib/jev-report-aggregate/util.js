"use strict";
// bin/lib/jev-report-aggregate/util.js — value helpers shared by the report sections.

const isObj = (x) => Boolean(x) && typeof x === "object" && !Array.isArray(x);
const own = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
const ratio = (num, den) => (den > 0 ? num / den : null);
const isNum = (x) => typeof x === "number" && Number.isFinite(x);

function fmt(x, digits = 3) {
  if (x === null || x === undefined) return "n/a";
  return typeof x === "number" ? String(Number(x.toFixed(digits))) : String(x);
}

// A counter map keyed by a log-derived string has no prototype: "constructor" or
// "__proto__" is then an ordinary key instead of an inherited property.
function bump(map, key, by = 1) {
  map[key] = (own(map, key) ? map[key] : 0) + by;
}

// `k=v k=v` over a counter map, "-" when empty.
function pairs(map, label = (k) => k) {
  return Object.keys(map).map((k) => `${label(k)}=${map[k]}`).join(" ") || "-";
}

module.exports = { isObj, own, ratio, isNum, fmt, bump, pairs };
