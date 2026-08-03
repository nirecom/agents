// hooks/lib/path-containment.js
// SSOT for "is this path really inside that directory?" (CPR-2), shared by
// enforce-worktree's marker-gate allow fast-path and block-clearance-token-write's
// glob qualifier — the two used to drift into separate implementations (one
// resolved symlinks + probed case-sensitivity, one did a lexical resolve()),
// so a symlink or case-only spelling difference could defeat containment on
// only one side.
//
//   realResolve()      — physical resolution (symlinks, nonexistent tails)
//   isContainedUnder() — string containment, case-folded only when proven
//                        case-insensitive by probe
//   resolvesUnder()    — the composition callers actually want
"use strict";

const nodePath = require("path");
const fs = require("fs");

// ── Physical resolution ─────────────────────────────────────────────────────
// nodePath.resolve() is purely lexical, so a symlinked base dir would produce
// a spurious containment mismatch. The deepest EXISTING ancestor is
// realpath'd and the not-yet-existing tail re-appended; a symlink target that
// does not exist yet (mid-attack) is followed via lstat/readlink rather than
// treated as a plain missing path. MAX_SYMLINK_HOPS bounds a circular/crafted
// chain and THROWS rather than falling back to a lexical walk that would
// trust the unfollowed symlink's own basename — callers wrap this fail-closed.
const MAX_SYMLINK_HOPS = 40;

function nativeRealpath() {
  return (fs.realpathSync && fs.realpathSync.native) ? fs.realpathSync.native : fs.realpathSync;
}

function realResolve(p, _depth) {
  const depth = _depth || 0;
  const abs = nodePath.resolve(p);
  const realpath = nativeRealpath();
  let head = abs;
  const tail = [];
  for (;;) {
    try {
      return tail.length === 0 ? realpath(head) : nodePath.join(realpath(head), ...tail);
    } catch (_) {
      let lst = null;
      try { lst = fs.lstatSync(head); } catch (_e2) { /* head doesn't exist at all */ }
      if (lst && lst.isSymbolicLink()) {
        if (depth >= MAX_SYMLINK_HOPS) {
          throw new Error(`realResolve: symlink chain exceeds ${MAX_SYMLINK_HOPS} hops at "${head}"`);
        }
        const linkTarget = fs.readlinkSync(head);
        const resolvedTarget = nodePath.isAbsolute(linkTarget)
          ? linkTarget
          : nodePath.resolve(nodePath.dirname(head), linkTarget);
        const rest = tail.length === 0 ? resolvedTarget : nodePath.join(resolvedTarget, ...tail);
        return realResolve(rest, depth + 1);
      }
      const parent = nodePath.dirname(head);
      if (parent === head) return abs; // reached the root without an existing ancestor
      tail.unshift(nodePath.basename(head));
      head = parent;
    }
  }
}

// ── Case-sensitivity, asked of the filesystem rather than the platform ───────
// Case-sensitivity is a property of the VOLUME, not the platform (darwin, WSL
// mounts, network shares, and case-sensitive Windows dirs all break a
// platform-based guess). probeCaseInsensitive() flips the case of the deepest
// existing ancestor and compares realpaths; any error/mismatch resolves to
// CASE-SENSITIVE, which makes containment stricter and callers fail closed
// toward blocking (never toward granting an allow outside root). Detection-
// direction callers must not use this — protected-name patterns already carry
// the `i` flag and need no folding.
const _caseInsensitiveCache = new Map();

// flipCase("Users") -> "uSERS"; null when the name has no cased letter
// (digits/punctuation only) and therefore cannot be used as a probe.
function flipCase(name) {
  let out = "";
  let flipped = false;
  for (const ch of name) {
    const lo = ch.toLowerCase();
    const up = ch.toUpperCase();
    if (lo !== up) {
      out += ch === lo ? up : lo;
      flipped = true;
    } else {
      out += ch;
    }
  }
  return flipped ? out : null;
}

function probeCaseInsensitive(dir) {
  let cur;
  try { cur = nodePath.resolve(dir); } catch (_) { return false; }
  const realpath = nativeRealpath();
  for (let hops = 0; hops < 64; hops += 1) {
    const parent = nodePath.dirname(cur);
    if (parent === cur) return false; // reached the volume root, nothing probeable
    const flipped = flipCase(nodePath.basename(cur));
    if (flipped) {
      let realOrig = null;
      try { realOrig = realpath(cur); } catch (_) { realOrig = null; }
      if (realOrig !== null) {
        try {
          return realpath(nodePath.join(parent, flipped)) === realOrig;
        } catch (_) {
          return false; // the case-flipped spelling does not exist => case-sensitive
        }
      }
      // `cur` itself does not exist — keep walking up to a real ancestor.
    }
    cur = parent;
  }
  return false; // inconclusive => strict
}

function isCaseInsensitiveFsAt(dir) {
  const key = nodePath.resolve(dir);
  if (_caseInsensitiveCache.has(key)) return _caseInsensitiveCache.get(key);
  let result;
  try { result = probeCaseInsensitive(key); } catch (_) { result = false; }
  _caseInsensitiveCache.set(key, result);
  return result;
}

function _isUnderExact(child, parent) {
  return child === parent ||
    child.startsWith(parent + nodePath.sep) ||
    child.startsWith(parent + "/");
}

// isContainedUnder(child, parent, { allowEqual }) -> boolean
// True only when `child` is provably inside `parent` ON THIS FILESYSTEM. Exact
// string containment always counts; a case-insensitive match counts only when
// `parent`'s volume was PROVEN case-insensitive by probe. `allowEqual` defaults
// to true; the workflow-dir allow passes false because the directory itself must
// stay blocked (that is what keeps `rm -rf <workflowDir>` blocked).
// Inputs are expected to be already physically resolved — see resolvesUnder().
function isContainedUnder(child, parent, opts) {
  const allowEqual = !opts || opts.allowEqual !== false;
  if (typeof child !== "string" || typeof parent !== "string" || !parent) return false;
  if (allowEqual ? _isUnderExact(child, parent) : _isUnderExact(child, parent) && child !== parent) {
    return true;
  }
  if (!isCaseInsensitiveFsAt(parent)) return false;
  const c = child.toLowerCase();
  const p = parent.toLowerCase();
  if (!allowEqual && c === p) return false;
  return _isUnderExact(c, p);
}

// resolvesUnder(childPath, parentPath, opts) -> boolean
// Resolves both sides physically, then tests containment. "Cannot prove
// containment" (unresolvable path, or a symlink chain hitting
// MAX_SYMLINK_HOPS) must NOT collapse to a single hardcoded `false`: this
// SSOT is consulted from opposite directions — a permission caller wants
// false (deny the shortcut, fail closed), a detection caller wants true (arm
// the block, fail closed) — so `opts.onUnknown` (required boolean) makes each
// caller declare its own fail direction. Missing/non-boolean throws
// (programmer-contract error, not attacker-triggered).
function resolvesUnder(childPath, parentPath, opts) {
  if (!opts || typeof opts.onUnknown !== "boolean") {
    throw new Error("resolvesUnder: opts.onUnknown (boolean) is required — the caller must declare its fail direction");
  }
  const onUnknown = opts.onUnknown;
  if (typeof childPath !== "string" || typeof parentPath !== "string") return onUnknown;
  if (childPath === "" || parentPath === "") return onUnknown;
  try {
    return isContainedUnder(realResolve(childPath), realResolve(parentPath), opts);
  } catch (_) {
    return onUnknown;
  }
}

module.exports = {
  MAX_SYMLINK_HOPS,
  realResolve,
  isCaseInsensitiveFsAt,
  isContainedUnder,
  resolvesUnder,
  _flipCase: flipCase,
  _probeCaseInsensitive: probeCaseInsensitive,
};
