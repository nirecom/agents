"use strict";
// Reads <root>/.agents.json into its two sections, cached per (root, mtime). Self-contained: the
// run-all fixtures copy hooks/lib/repo-settings{,.js} alone, so nothing outside them is required.

const fs = require("fs");
const path = require("path");
const { validateDoc } = require("./validate");

const FILE_NAME = ".agents.json";
const cache = new Map();

// Git Bash hands over /<drive>/... paths, which Node's fs cannot open on Windows.
function nativePath(p) {
  const m = process.platform === "win32" && /^\/([a-zA-Z])(\/.*)?$/.exec(p);
  return m ? `${m[1].toUpperCase()}:${m[2] || "/"}` : p;
}

const rootKey = (root) => path.resolve(nativePath(String(root || ".")));
const fileOf = (root) => path.join(rootKey(root), FILE_NAME);

function mtimeOf(file) {
  try {
    return fs.statSync(file).mtimeMs;
  } catch {
    return null;
  }
}

function read(file) {
  let text;
  try {
    text = fs.readFileSync(file, "utf8");
  } catch (e) {
    if (e && e.code === "ENOENT") return { tests: { state: "missing" }, migrate: { state: "missing" } };
    const bad = { state: "malformed", errors: [`cannot read ${FILE_NAME}: ${e.message}`] };
    return { tests: bad, migrate: bad };
  }
  let doc;
  try {
    doc = JSON.parse(text);
  } catch (e) {
    const bad = { state: "malformed", errors: [`${FILE_NAME} is not JSON: ${String(e.message).split("\n")[0]}`] };
    return { tests: bad, migrate: bad };
  }
  return validateDoc(doc);
}

// load(root) — { root, file, tests: { state, value?, errors? }, migrate: { ... } }.
function load(root) {
  const key = rootKey(root);
  const file = path.join(key, FILE_NAME);
  const mtime = mtimeOf(file);
  const hit = cache.get(key);
  if (hit && hit.mtime === mtime) return hit.value;
  const value = Object.freeze({ root: key, file, ...read(file) });
  cache.set(key, { mtime, value });
  return value;
}

// readDoc(root) — the raw parsed object (for writers), {} when the file is absent; throws when unparsable.
function readDoc(root) {
  const file = fileOf(root);
  if (!fs.existsSync(file)) return {};
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

const migrateDone = (root, key) => {
  const m = load(root).migrate;
  return m.state === "ok" && m.value[key] === "done";
};

module.exports = { FILE_NAME, nativePath, rootKey, fileOf, load, readDoc, migrateDone };
