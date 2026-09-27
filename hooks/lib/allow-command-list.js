"use strict";
// hooks/lib/allow-command-list.js — the only reader of the two self-script SSOT lists
// (install/settings-allow-commands.txt, install/path-exposed-commands.txt) for bash-guard.
//
// A match here lets bash-guard answer permissionDecision "allow", which skips the prompt, so
// every failure narrows: an unreadable list is "no targets", a malformed entry is dropped,
// an unknown shebang resolves to no interpreter, and nothing here throws.
// resolveEntry() maps one command-line spelling of a script path to its list entry; it is
// shared by the allow path (hooks/bash-guard/allow.js) and the L3 notify (detect.js).

const fs = require("fs");
const path = require("path");
const { normalizeCwd } = require("./path-normalize");

const DEFAULT_ROOT = path.resolve(__dirname, "..", "..");
const ALLOW_LIST_REL = path.join("install", "settings-allow-commands.txt");
const PATH_LIST_REL = path.join("install", "path-exposed-commands.txt");
const ENTRY_RE = /^[A-Za-z0-9._/-]+$/;
const INTERPRETERS = Object.freeze(["bash", "node"]);
const ENV_PREFIX_RE = /^(?:\$AGENTS_CONFIG_DIR|\$\{AGENTS_CONFIG_DIR\})\//;
const SHEBANG_READ_BYTES = 512;

const cache = new Map();

function isValidEntry(entry) {
  if (typeof entry !== "string" || entry === "") return false;
  if (entry.startsWith("/") || !ENTRY_RE.test(entry)) return false;
  return !entry.split("/").some((s) => s === ".." || s === "." || s === "");
}

function readListFile(file) {
  try {
    return fs
      .readFileSync(file, "utf8")
      .split("\n")
      .map((l) => l.replace(/\s+$/, ""))
      .filter((l) => l !== "" && !l.startsWith("#"));
  } catch (_e) {
    return [];
  }
}

/**
 * @param {string} [root] agents root; defaults to this repo
 * @returns {{entries: string[], exposedBare: Set<string>}}
 */
function loadAllowTargets(root) {
  const base = typeof root === "string" && root !== "" ? root : DEFAULT_ROOT;
  if (cache.has(base)) return cache.get(base);
  const entries = Object.freeze(readListFile(path.join(base, ALLOW_LIST_REL)).filter(isValidEntry));
  const exposed = new Set(readListFile(path.join(base, PATH_LIST_REL)));
  const exposedBare = new Set(entries.map((e) => path.posix.basename(e)).filter((n) => exposed.has(n)));
  const targets = Object.freeze({ entries, exposedBare });
  cache.set(base, targets);
  return targets;
}

function firstLine(file) {
  let fd = null;
  try {
    fd = fs.openSync(file, "r");
    const buf = Buffer.alloc(SHEBANG_READ_BYTES);
    const n = fs.readSync(fd, buf, 0, buf.length, 0);
    return buf.slice(0, n).toString("utf8").split("\n")[0].replace(/\r$/, "");
  } catch (_e) {
    return null;
  } finally {
    if (fd !== null) {
      try { fs.closeSync(fd); } catch (_e) { /* already closed */ }
    }
  }
}

/**
 * @param {string} root agents root
 * @param {string} entry a repo-relative list entry
 * @returns {"bash"|"node"|null} the shebang interpreter, or null when absent or unsupported
 */
function interpreterOf(root, entry) {
  try {
    if (!isValidEntry(entry)) return null;
    const base = typeof root === "string" && root !== "" ? root : DEFAULT_ROOT;
    const line = firstLine(path.join(base, entry));
    if (!line || !line.startsWith("#!")) return null;
    const tokens = line.slice(2).trim().split(/\s+/).filter(Boolean);
    if (tokens.length === 0) return null;
    let name = path.posix.basename(tokens[0]);
    if (name === "env") name = tokens.length > 1 ? path.posix.basename(tokens[1]) : null;
    return INTERPRETERS.includes(name) ? name : null;
  } catch (_e) {
    return null;
  }
}

const toSlash = (p) => p.split("\\").join("/");
const canonAbs = (p) => toSlash(normalizeCwd(p) || p).replace(/\/+$/, "");
const isAbsSpelling = (p) => /^[A-Za-z]:[\\/]/.test(p) || p.startsWith("/") || p.startsWith("\\");
const foldCase = (p) => (process.platform === "win32" ? p.toLowerCase() : p);

// Absolute and $AGENTS_CONFIG_DIR spellings never read cwd; a relative one resolves only
// against a cwd that IS the root. The root is stripped on a path boundary (root + "/").
function relativeToRoot(spelling, root, cwd) {
  const env = ENV_PREFIX_RE.exec(spelling);
  if (env) return spelling.slice(env[0].length);
  const rootAbs = canonAbs(root);
  if (isAbsSpelling(spelling)) {
    const abs = canonAbs(spelling);
    const prefix = rootAbs + "/";
    return foldCase(abs).startsWith(foldCase(prefix)) ? abs.slice(prefix.length) : null;
  }
  if (typeof cwd !== "string" || cwd === "") return null;
  if (foldCase(canonAbs(cwd)) !== foldCase(rootAbs)) return null;
  return spelling.replace(/^\.\//, "");
}

/**
 * @param {string[]} spellings candidate spellings of one path token (see spellingsOf)
 * @param {string} [root] agents root
 * @param {string|null} [cwd] a verified absolute cwd, or null
 * @returns {string|null} the allow-list entry the path names, or null
 */
function resolveEntry(spellings, root, cwd) {
  const base = typeof root === "string" && root !== "" ? root : DEFAULT_ROOT;
  const { entries } = loadAllowTargets(base);
  for (const s of Array.isArray(spellings) ? spellings : []) {
    if (typeof s !== "string" || s === "") continue;
    const rel = relativeToRoot(s, base, cwd);
    if (rel === null || rel.split("/").some((seg) => seg === ".." || seg === ".")) continue;
    if (entries.includes(rel)) return rel;
  }
  return null;
}

// The cooked token loses the backslashes of a double-quoted Windows path, so the raw token
// (outer quotes stripped) is a second candidate. A single-quoted or escaped `$` never expands,
// so such a raw token cannot stand for $AGENTS_CONFIG_DIR.
function spellingsOf(cooked, raw) {
  const out = [];
  const literalDollar = typeof raw === "string" && (raw.includes("'") || raw.includes("\\$"));
  const push = (s) => {
    if (typeof s !== "string" || s === "" || out.includes(s)) return;
    if (literalDollar && s.startsWith("$")) return;
    out.push(s);
  };
  push(cooked);
  if (typeof raw === "string") {
    const q = raw.charAt(0);
    if ((q === '"' || q === "'") && raw.length >= 2 && raw.endsWith(q)) {
      const inner = raw.slice(1, -1);
      if (!/["']/.test(inner)) push(inner);
    } else if (!/["']/.test(raw)) {
      push(raw);
    }
  }
  return out;
}

module.exports = {
  DEFAULT_ROOT,
  INTERPRETERS,
  loadAllowTargets,
  interpreterOf,
  resolveEntry,
  spellingsOf,
};
