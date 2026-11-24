"use strict";
// bin/lib/review-threat-metrics/cache.js — classifier answers kept under the plans dir (#2020):
// the v0 cache (<PLANS_DIR>/review-threat-metrics-v0-cache.json, one classifierId, entries only
// added, never overwritten) and the append-only post boundary subset cache (JSONL, one
// classifierId per line). Entries are keyed by the finding text, which is all the classifier sees.
const fs = require("node:fs");
const path = require("node:path");
const { sha } = require("./common");

const V0_FILE = "review-threat-metrics-v0-cache.json";
const SUBSET_FILE = "review-threat-metrics-subset-cache.jsonl";
const textKey = (text) => sha(String(text)).slice(0, 16);

// readV0(dir) — {classifierId, model, items: {key: {axisA, axisB, category}}}, or null when there is
// no cache file. A file that cannot be read or parsed throws (CLI exit 5): reading it as absent would
// classify v0 a second time.
function readV0(dir) {
  const f = path.join(dir, V0_FILE);
  let s;
  try {
    s = fs.readFileSync(f, "utf8");
  } catch (e) {
    if (e.code === "ENOENT") return null;
    throw new Error(`the v0 cache ${f} cannot be read: ${e.message}`, { cause: e });
  }
  let o;
  try {
    o = JSON.parse(s);
  } catch (e) {
    throw new Error(`the v0 cache ${f} is not valid JSON: ${e.message}`, { cause: e });
  }
  if (o && typeof o === "object" && o.items && typeof o.items === "object") return o;
  throw new Error(`the v0 cache ${f} has no items object`);
}

function writeV0(dir, cache) {
  fs.mkdirSync(dir, { recursive: true });
  const f = path.join(dir, V0_FILE);
  const tmp = `${f}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, `${JSON.stringify(cache)}\n`);
  fs.renameSync(tmp, f);
}

// comparison(cache, classifierId) — whether v0 answers can be compared with this classifier's.
function comparison(cache, classifierId) {
  if (!cache) return "no-v0-cache";
  return cache.classifierId === classifierId ? "comparable" : "not-comparable";
}

// readSubset(dir, classifierId) — Map of key to answer, this classifier's lines only.
function readSubset(dir, classifierId) {
  const m = new Map();
  let lines;
  try {
    lines = fs.readFileSync(path.join(dir, SUBSET_FILE), "utf8").split(/\r?\n/);
  } catch {
    return m;
  }
  for (const l of lines) {
    try {
      const o = JSON.parse(l);
      if (o.classifierId === classifierId && !m.has(o.key)) m.set(o.key, { axisA: o.axisA, axisB: o.axisB, category: o.category });
    } catch {
      // a torn line is skipped; its finding is classified again
    }
  }
  return m;
}

// appendSubset(dir, classifierId, entries) — entries: [{key, axisA, axisB, category}].
function appendSubset(dir, classifierId, entries) {
  if (entries.length === 0) return;
  fs.mkdirSync(dir, { recursive: true });
  const body = entries.map((e) => JSON.stringify({ classifierId, ...e })).join("\n");
  fs.appendFileSync(path.join(dir, SUBSET_FILE), `${body}\n`);
}

module.exports = { V0_FILE, SUBSET_FILE, textKey, readV0, writeV0, comparison, readSubset, appendSubset };
