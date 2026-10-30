"use strict";
// The test-language registry as the test gates read it (#2507 D7). The table is loaded at use
// time (a test may swap a cached entry), and a part resolves to its `node` form when it has one.

const fs = require("fs");
const path = require("path");
const TLR = require("../test-language-registry");

const REPO_ROOT = path.resolve(__dirname, "..", "..", "..");
const CATEGORIES = ["hooks", "bin", "skills", "agents", "install", "tests"];
const DEFAULT_FLAT_REJECT_CODE = "FLAT_TEST_REJECTED";

const reg = () => TLR.loadRegistry();

function tryReg() {
  try {
    return reg();
  } catch {
    return null;
  }
}

// match(pathOrName) — { id, status, entry } of the basename, or null.
function match(p) {
  const s = String(p);
  return TLR.matchBasename(s.slice(s.lastIndexOf("/") + 1), reg());
}

const entryById = (id) => reg().entries.find((e) => e.id === id) || null;

// fieldValue(entry, "a.b") — the bash dump's value: "" / null are undefined, an array is csv.
function fieldValue(entry, name) {
  if (!entry) return undefined;
  if (name === "diagnostics.flatRejectCode" && entry.status === "supported") {
    return (entry.diagnostics && entry.diagnostics.flatRejectCode) || DEFAULT_FLAT_REJECT_CODE;
  }
  const v = name.split(".").reduce((o, k) => (o === null || o === undefined ? undefined : o[k]), entry);
  if (Array.isArray(v)) return v.length ? v.join(",") : undefined;
  return v === null || v === undefined || v === "" ? undefined : String(v);
}

// commentPrefix(path) — the entry's header.commentPrefix, else the fallback entry's.
function commentPrefix(p) {
  const m = match(p);
  const hit = m ? fieldValue(m.entry, "header.commentPrefix") : undefined;
  if (hit) return hit;
  return fieldValue(entryById(reg().tableDrivenFallbackEntry), "header.commentPrefix") || "";
}

// partOf(entry, field) — { file, function } of the part, its `node` form preferred; null when none.
function partOf(entry, field) {
  const f = entry && entry[field];
  if (!f) return null;
  const p = f.node || f;
  return p && p.file ? { file: p.file, function: p.function } : null;
}

// loadPart(entry, field) — the part's function, or null when its file or function cannot be reached.
function loadPart(entry, field) {
  const p = partOf(entry, field);
  if (!p) return null;
  const abs = path.join(REPO_ROOT, ...p.file.split("/"));
  if (!fs.existsSync(abs)) return null;
  try {
    const mod = require(abs);
    return typeof mod[p.function] === "function" ? mod[p.function] : null;
  } catch {
    return null;
  }
}

function pathKey(env) {
  return Object.keys(env || {}).find((k) => k.toUpperCase() === "PATH") || "PATH";
}

// The environment the gates run under: a CLI's run({ env }) or the pre-commit context's, set
// for the duration of one call by withEnv; process.env otherwise.
let ambient = null;
const env = () => ambient || process.env;

function withEnv(e, fn) {
  const prev = ambient;
  ambient = e || null;
  try {
    return fn();
  } finally {
    ambient = prev;
  }
}

// which(tool, env) — the tool's path on env's PATH (tool, .exe or .cmd), or null.
function which(tool, e = env()) {
  const dirs = String((e || {})[pathKey(e)] || "").split(path.delimiter).filter(Boolean);
  const names = process.platform === "win32" ? [`${tool}.exe`, `${tool}.cmd`, tool] : [tool];
  for (const dir of dirs) {
    for (const n of names) {
      const abs = path.join(dir, n);
      try {
        if (fs.statSync(abs).isFile()) return abs;
      } catch {
        // next
      }
    }
  }
  return null;
}

module.exports = { REPO_ROOT, CATEGORIES, reg, tryReg, match, entryById, fieldValue, commentPrefix, partOf, loadPart, which, pathKey, env, withEnv };
