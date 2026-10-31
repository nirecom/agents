"use strict";
// Shared helpers for the tests/hooks/feature-2652-state-handoff-*.js files.
// check(name, fn) runs fn NOW (the cases mutate one shared state root in order) and registers one
// node:test test that fails with fn's reason; fn fails by throwing or by returning a string.

const assert = require("node:assert");
const { test } = require("node:test");

const show = (v) => (v === undefined ? "undefined" : JSON.stringify(v));

function check(name, fn) {
  let why = null;
  try {
    const r = fn();
    if (typeof r === "string") why = r;
  } catch (e) {
    why = e && e.message ? e.message : String(e);
  }
  test(name, () => { if (why !== null) assert.fail(why); });
}

function eq(got, want, what) {
  if (JSON.stringify(got) !== JSON.stringify(want)) throw new Error(`${what || "value"}: want=${show(want)} got=${show(got)}`);
}

function parseKv(out) {
  const kv = {};
  for (const line of String(out).split(/\r?\n/)) {
    const m = line.match(/^([A-Z_]+)=(.*)$/);
    if (m) kv[m[1]] = m[2].replace(/^'(.*)'$/, "$1").replace(/^"(.*)"$/, "$1");
  }
  return kv;
}

module.exports = { check, eq, show, parseKv };
