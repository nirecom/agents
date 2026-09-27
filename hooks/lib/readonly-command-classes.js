"use strict";
// hooks/lib/readonly-command-classes.js — the only reader of install/readonly-command-classes.json
// (the #2403 external read-only class SSOT), modeled on allow-command-list.js.
//
// A class here lets bash-guard answer "allow", which skips the prompt, so every failure
// narrows: an unreadable or malformed file is "no classes", an invalid entry or an unknown
// delegate is dropped, and nothing here throws.

const fs = require("fs");
const path = require("path");

const DEFAULT_ROOT = path.resolve(__dirname, "..", "..");
const DATA_REL = path.join("install", "readonly-command-classes.json");
const SUPPORTED_VERSION = 1;
const DELEGATE_NAMES = new Set(["git-pure-read", "gh-read"]);
const SYNTAXES = new Set(["getopt", "find"]);
const COMMAND_NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._+-]*$/;

const cache = new Map();

const emptyClasses = () => Object.freeze({ delegate: new Map(), generic: new Map() });
const isPlainObject = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const isFlagList = (v) => Array.isArray(v) && v.every((f) => typeof f === "string" && f.length > 1 && f[0] === "-");

function parseEntry(raw) {
  if (!isPlainObject(raw) || !SYNTAXES.has(raw.syntax)) return null;
  if (raw.denyFlags !== undefined && !isFlagList(raw.denyFlags)) return null;
  if (raw.requireLeading !== undefined && !isFlagList(raw.requireLeading)) return null;
  return Object.freeze({
    syntax: raw.syntax,
    denyFlags: Object.freeze([...(raw.denyFlags || [])]),
    requireLeading: raw.requireLeading ? Object.freeze([...raw.requireLeading]) : null,
  });
}

function buildClasses(data) {
  if (!isPlainObject(data) || data.version !== SUPPORTED_VERSION) return emptyClasses();
  if (!isPlainObject(data.delegate) || !isPlainObject(data.generic)) return emptyClasses();
  const delegate = new Map();
  for (const [name, target] of Object.entries(data.delegate)) {
    if (COMMAND_NAME_RE.test(name) && DELEGATE_NAMES.has(target)) delegate.set(name, target);
  }
  const generic = new Map();
  for (const [name, raw] of Object.entries(data.generic)) {
    if (!COMMAND_NAME_RE.test(name) || delegate.has(name)) continue;
    const entry = parseEntry(raw);
    if (entry) generic.set(name, entry);
  }
  return Object.freeze({ delegate, generic });
}

/**
 * @param {string} [root] agents root; defaults to this repo
 * @returns {{delegate: Map<string, string>, generic: Map<string, object>}}
 */
function loadReadOnlyClasses(root) {
  const base = typeof root === "string" && root !== "" ? root : DEFAULT_ROOT;
  if (cache.has(base)) return cache.get(base);
  let classes;
  try {
    classes = buildClasses(JSON.parse(fs.readFileSync(path.join(base, DATA_REL), "utf8")));
  } catch (_e) {
    classes = emptyClasses();
  }
  cache.set(base, classes);
  return classes;
}

module.exports = { DEFAULT_ROOT, DELEGATE_NAMES, loadReadOnlyClasses };
