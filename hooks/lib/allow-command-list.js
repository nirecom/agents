"use strict";
// hooks/lib/allow-command-list.js — the only reader of the two self-script SSOT lists
// (install/settings-allow-commands.txt, install/path-exposed-commands.txt) for bash-guard.
//
// A match here lets bash-guard answer permissionDecision "allow", which skips the prompt, so
// every failure narrows: an unreadable list is "no targets", a malformed entry is dropped,
// an unknown shebang resolves to no interpreter, and nothing here throws.
// resolveScript() maps one command-line spelling of a script path to its list entry in the
// checkout it names (the agents root or a linked worktree of it); resolveEntry() is its entry-only
// view, shared by the allow path (hooks/bash-guard/allow.js) and the L3 notify (detect.js).

const fs = require("fs");
const path = require("path");
const { normalizeCwd } = require("./path-normalize");
const { checkoutRootOf } = require("./checkout-identity");

const DEFAULT_ROOT = path.resolve(__dirname, "..", "..");
const ALLOW_LIST_REL = path.join("install", "settings-allow-commands.txt");
const PATH_LIST_REL = path.join("install", "path-exposed-commands.txt");
const ENTRY_RE = /^[A-Za-z0-9._/-]+$/;
const INTERPRETERS = Object.freeze(["bash", "node"]);
const ENV_PREFIX_RE = /^(?:\$AGENTS_MAIN_ROOT|\$\{AGENTS_MAIN_ROOT\})\//;
const SHEBANG_READ_BYTES = 512;

const cache = new Map();

const toSlash = (p) => p.split("\\").join("/");
const canonAbs = (p) => toSlash(normalizeCwd(p) || p).replace(/\/+$/, "");
const isAbsSpelling = (p) => /^[A-Za-z]:[\\/]/.test(p) || p.startsWith("/") || p.startsWith("\\");
const foldCase = (p) => (process.platform === "win32" ? p.toLowerCase() : p);

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
  const key = foldCase(canonAbs(base));
  if (cache.has(key)) return cache.get(key);
  const entries = Object.freeze(readListFile(path.join(base, ALLOW_LIST_REL)).filter(isValidEntry));
  const exposed = new Set(readListFile(path.join(base, PATH_LIST_REL)));
  const exposedBare = new Set(entries.map((e) => path.posix.basename(e)).filter((n) => exposed.has(n)));
  const targets = Object.freeze({ entries, exposedBare });
  cache.set(key, targets);
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

const hasDotSegment = (p) => p.split("/").some((seg) => seg === ".." || seg === ".");

function stripRoot(abs, rootAbs) {
  const prefix = rootAbs + "/";
  return foldCase(abs).startsWith(foldCase(prefix)) ? abs.slice(prefix.length) : null;
}

/**
 * The checkout a working directory stands at the ROOT of: the agents root itself, or a linked
 * worktree of it (same git common dir). A subdirectory of either is not a checkout root.
 * @param {string} dir an absolute directory
 * @param {string} [root] agents root
 * @returns {string|null}
 */
function checkoutAt(dir, root) {
  if (typeof dir !== "string" || dir === "") return null;
  const base = typeof root === "string" && root !== "" ? root : DEFAULT_ROOT;
  const dirAbs = canonAbs(dir);
  if (foldCase(dirAbs) === foldCase(canonAbs(base))) return base;
  const wt = checkoutRootOf(dirAbs, base);
  return wt !== null && foldCase(canonAbs(wt)) === foldCase(dirAbs) ? wt : null;
}

// $AGENTS_MAIN_ROOT spellings name the agents root whatever the cwd. An absolute spelling is
// stripped on a path boundary of the agents root, else of the linked worktree it lies in; a
// relative one resolves only against a cwd that is a checkout root (see checkoutAt).
function locate(spelling, root, cwd) {
  const env = ENV_PREFIX_RE.exec(spelling);
  if (env) return { rel: spelling.slice(env[0].length), checkoutRoot: root };
  if (isAbsSpelling(spelling)) {
    const abs = canonAbs(spelling);
    const underRoot = stripRoot(abs, canonAbs(root));
    if (underRoot !== null) return { rel: underRoot, checkoutRoot: root };
    if (hasDotSegment(abs)) return null;
    const wt = checkoutRootOf(abs, root);
    const rel = wt === null ? null : stripRoot(abs, canonAbs(wt));
    return rel === null ? null : { rel, checkoutRoot: wt };
  }
  const checkoutRoot = checkoutAt(cwd, root);
  return checkoutRoot === null ? null : { rel: spelling.replace(/^\.\//, ""), checkoutRoot };
}

/**
 * @param {string[]} spellings candidate spellings of one path token (see spellingsOf)
 * @param {string} [root] agents root
 * @param {string|null} [cwd] a verified absolute cwd, or null
 * @returns {{entry: string, checkoutRoot: string}|null} the entry, judged against the list of the
 *          checkout the path lies in, and that checkout's root; or null
 */
function resolveScript(spellings, root, cwd) {
  try {
    const base = typeof root === "string" && root !== "" ? root : DEFAULT_ROOT;
    for (const s of Array.isArray(spellings) ? spellings : []) {
      if (typeof s !== "string" || s === "") continue;
      const loc = locate(s, base, cwd);
      if (loc === null || hasDotSegment(loc.rel)) continue;
      if (loadAllowTargets(loc.checkoutRoot).entries.includes(loc.rel)) {
        return { entry: loc.rel, checkoutRoot: loc.checkoutRoot };
      }
    }
    return null;
  } catch (_e) {
    return null;
  }
}

/**
 * @param {string[]} spellings
 * @param {string} [root]
 * @param {string|null} [cwd]
 * @returns {string|null} the allow-list entry the path names, or null
 */
function resolveEntry(spellings, root, cwd) {
  const hit = resolveScript(spellings, root, cwd);
  return hit ? hit.entry : null;
}

// The cooked token loses the backslashes of a double-quoted Windows path, so the raw token
// (outer quotes stripped) is a second candidate. A single-quoted or escaped `$` never expands,
// so such a raw token cannot stand for $AGENTS_MAIN_ROOT.
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
  checkoutAt,
  resolveScript,
  resolveEntry,
  spellingsOf,
};
