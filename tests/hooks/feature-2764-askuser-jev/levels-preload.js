"use strict";
// Test-only preload (--require) for tests/hooks/feature-2764-askuser-jev.js (#2764): the real
// classification table gains one low row declaring two steps, MULTI_ROW, however the hook reads
// it (require of the JSON, fs.readFileSync of it, or classify() of the loader module).
// The real table has no multi-step low row, and the test must not edit it.

const fs = require("node:fs");
const path = require("node:path");
const Module = require("node:module");
const { MULTI_ROW } = require("./levels-preload-row");
const LIB = path.resolve(__dirname, "..", "..", "..", "hooks", "lib");
const key = (p) => (process.platform === "win32" ? path.resolve(p).toLowerCase() : path.resolve(p));
const JSON_PATH = key(path.join(LIB, "askuser-dialog-levels.json"));
const JS_PATH = key(path.join(LIB, "askuser-dialog-levels.js"));
const withRow = (t) => (t && Array.isArray(t.dialogs) ? Object.assign({}, t, { dialogs: t.dialogs.concat([MULTI_ROW]) }) : t);

const readFileSync = fs.readFileSync;
fs.readFileSync = function patchedRead(p, ...rest) {
  const out = readFileSync.call(this, p, ...rest);
  if (typeof p !== "string" || key(p) !== JSON_PATH) return out;
  try {
    const text = JSON.stringify(withRow(JSON.parse(String(out))));
    return typeof out === "string" ? text : Buffer.from(text);
  } catch (_e) { return out; }
};

const load = Module._load;
let patchedJs = null;
Module._load = function patchedLoad(request, parent, ...rest) {
  const out = load.call(this, request, parent, ...rest);
  let file;
  try { file = key(Module._resolveFilename(request, parent)); } catch (_e) { return out; }
  if (file === JSON_PATH) return withRow(out);
  if (file !== JS_PATH || !out || typeof out.classify !== "function") return out;
  if (!patchedJs) {
    const classify = out.classify;
    patchedJs = Object.assign({}, out, { classify: (id) => (id === MULTI_ROW.id ? { level: "low", steps: MULTI_ROW.steps.slice() } : classify(id)) });
  }
  return patchedJs;
};
