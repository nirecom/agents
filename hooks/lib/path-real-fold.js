"use strict";
// Single owner of the letter-case fold rule and the real-path walk (#3138). foldsCase decides by
// platform only (win32 / darwin fold; no FS probe). realResolve walks one segment at a time on the
// real FS so `link/..` climbs from the link's target, and returns on-disk spellings; any doubt throws.

const fs = require("fs");
const path = require("path");

const { normalizeCwd } = require("./path-normalize");

function foldsCase(platform = process.platform) {
  return platform === "win32" || platform === "darwin";
}

// Comparison key only: apply to realResolve output when the input may hold links.
function foldKey(p) {
  const normalized = normalizeCwd(String(p)) || String(p);
  const key = path.resolve(normalized).replace(/\\/g, "/").replace(/\/+$/, "");
  return foldsCase() ? key.toLowerCase() : key;
}

function stripLongPrefix(p) {
  return /^\\\\\?\\[A-Za-z]:\\/.test(p) ? p.slice(4) : p;
}

function splitAbsolute(p) {
  const normalized = normalizeCwd(String(p)) || String(p);
  const abs = path.isAbsolute(normalized) ? normalized : process.cwd() + path.sep + normalized;
  let root = path.parse(abs).root;
  const rest = abs.slice(root.length);
  if (/^[a-z]:/.test(root)) root = root.charAt(0).toUpperCase() + root.slice(1);
  const sep = process.platform === "win32" ? /[\\/]+/ : /\/+/;
  return { root, segments: rest.split(sep).filter((s) => s !== "") };
}

// The on-disk entry of <dir> naming <seg>: an exact entry wins, else the only fold match.
function realEntryName(dir, seg) {
  // No fold: the caller's lstat already proved this exact spelling exists, so a traversable but
  // unlistable parent (POSIX 0711) must not make the walk fail.
  if (!foldsCase()) return seg;
  const names = fs.readdirSync(dir).map((d) => (typeof d === "string" ? d : d.name));
  if (names.includes(seg)) return seg;
  const lower = seg.toLowerCase();
  const folded = names.filter((n) => n.toLowerCase() === lower);
  if (folded.length === 1) return folded[0];
  throw new Error(`realResolve: ${folded.length === 0 ? "no" : "ambiguous"} entry for '${seg}' in ${dir}`);
}

function realResolve(p) {
  const { root, segments } = splitAbsolute(p);
  let cur = root;
  let missing = false;
  for (const seg of segments) {
    if (seg === ".") continue;
    if (seg === "..") {
      if (missing) throw new Error(`realResolve: '..' after a part that does not exist: ${p}`);
      cur = path.dirname(cur);
      continue;
    }
    const next = path.join(cur, seg);
    if (missing) {
      cur = next;
      continue;
    }
    let st;
    try {
      st = fs.lstatSync(next);
    } catch (e) {
      if (!e || e.code !== "ENOENT") throw e;
      missing = true;
      cur = next;
      continue;
    }
    cur = st.isSymbolicLink() ? stripLongPrefix(fs.realpathSync.native(next)) : path.join(cur, realEntryName(cur, seg));
  }
  return cur;
}

module.exports = { foldsCase, foldKey, realResolve };
