"use strict";
// hooks/lib/jev/adapters/answers.js — reading one yes/no answer out of a Jev response, shared
// by the conversation adapters. Own keys only: a key never resolves to an inherited property.

// The noul probability of key (asked as is, or answered under its underscore spelling), or null.
function probabilityOf(answers, key) {
  for (const k of [key, key.replace(/-/g, "_")]) {
    if (!answers || !Object.prototype.hasOwnProperty.call(answers, k)) continue;
    const a = answers[k];
    const p = a && typeof a === "object" ? a.noul : undefined;
    if (typeof p === "number" && Number.isFinite(p) && p >= 0 && p <= 1) return p;
  }
  return null;
}

// mapKeys(response, keys) -> {status: ok|unmappable, items: {key: {p}}, probabilities: {key: p|null}}.
function mapKeys(response, keys) {
  const answers = response && response.answers && typeof response.answers === "object" ? response.answers : {};
  const items = {};
  const probabilities = {};
  let valid = true;
  for (const key of keys) {
    const p = probabilityOf(answers, key);
    if (p === null) valid = false;
    items[key] = { p };
    probabilities[key] = p;
  }
  return { status: valid ? "ok" : "unmappable", items, probabilities };
}

module.exports = { probabilityOf, mapKeys };
