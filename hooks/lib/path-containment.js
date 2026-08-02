// hooks/lib/path-containment.js
// SSOT for "is this path really inside that directory?" (CPR-2).
//
// Two hook entrypoints ask that question about the SAME directory (the workflow
// state dir) for the SAME reason (a protected file lives there), so per
// rules/coding/file-split.md the answer belongs in the shared hooks/lib/ layer:
//
//   hooks/enforce-worktree/bash-write-scope/marker-gate.js — allow fast-path
//   hooks/block-off-clearance-write/bash-target-context.js — glob qualifier
//
// codex round-5 HIGH: those two had drifted into DIFFERENT implementations. The
// enforce-worktree side resolved symlinks (realResolve) and probed the volume
// for case-sensitivity; the block-off-clearance-write side used a lexical
// path.resolve() and folded case on `process.platform === "win32"` alone. Both
// deviations are exploitable in the same direction — a symlink under the
// workflow dir, or a case-only spelling difference on a case-insensitive
// non-Windows volume (macOS HFS+/APFS default, a Windows share mounted in WSL),
// made the lexical side answer "not contained" for a path that really is. One
// implementation, used by both, is the only way that stays fixed.
//
// The two concerns are kept separate inside this file (CPR-3):
//   realResolve()      — PHYSICAL resolution (symlinks, nonexistent tails)
//   isContainedUnder() — STRING containment, case-folded only when the volume
//                        was PROVEN case-insensitive by probe
//   resolvesUnder()    — the composition, which is what callers actually want
"use strict";

const nodePath = require("path");
const fs = require("fs");

// ── Physical resolution ─────────────────────────────────────────────────────
//
// nodePath.resolve() is purely LEXICAL, so `<workflowDir>/escape -> /outside` is
// lexically "under" the workflow dir while actually escaping it. The target
// usually does not exist yet (it is about to be written), so the deepest
// EXISTING ancestor is realpath'd and the not-yet-existing tail is re-appended.
// Both sides of a comparison must go through this, otherwise a symlinked base
// dir (e.g. macOS /tmp -> /private/tmp) produces a spurious mismatch.
//
// F-3 (security-scanner round 6): a two-step symlink attack — `ln -s
// <wf>/<sid>.workflow-off <wf>/lnk` (the marker does not exist yet; it is about
// to be forged by a SECOND write through the link) — makes fs.realpathSync(head)
// throw ENOENT for the same reason a genuinely nonexistent path would: Node's
// realpath requires the FINAL resolved target to exist, and pre-write it never
// does. Treating both cases identically (walk up, re-append the tail lexically)
// silently kept the symlink's own basename ("lnk") instead of following it. Peek
// with lstat/readlink before the parent-walk so the eventual basename check
// downstream sees "sid.workflow-off", not "lnk".
//
// MAX_SYMLINK_HOPS bounds a circular or attacker-crafted chain (DoS). Exceeding
// it while `head` is STILL a live symlink THROWS rather than falling back to the
// lexical parent-walk (codex round 6/7 HIGH): that fallback resolves the
// unfollowed symlink by its own basename, which can lexically satisfy a
// workflow-dir prefix check while the chain's real target lies outside it. Every
// caller wraps this in a fail-closed try/catch, so throwing is safe.
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
//
// #1780 H-3 (round 4). The old code decided folding from the PLATFORM
// (`win32 || darwin`), then folded every darwin path even though its own comment
// said case-sensitive macOS volumes must not be folded. Case-sensitivity is a
// property of the VOLUME: darwin, WSL mounts, network shares and
// case-sensitivity-enabled Windows directories all break the correlation
// (CPR-8 — no implicit branching on an environment assumption).
//
// probeCaseInsensitive(dir) flips the case of the deepest existing ancestor's
// basename and realpaths BOTH spellings. Same realpath ⇒ case-insensitive.
// ENOENT, a different realpath, an unflippable name, or any error ⇒ treated as
// CASE-SENSITIVE. That fallback direction is the whole point: "unknown" resolves
// to case-sensitive, which makes containment STRICTER, which makes callers (all
// of which use containment to GRANT an allow) fail closed toward blocking. It
// can cost a legitimate write a fast-path; it can never hand an allow to a path
// outside the root.
//
// Detection-direction callers must NOT use this. Folding case before testing
// against a protected-name pattern is a block-direction test where over-matching
// is safe — and those patterns already carry the `i` flag
// (hooks/lib/protected-basenames.js), so they need no folding at all.
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
// The composition callers actually want: resolve BOTH sides physically, then
// test containment.
//
// codex scanner C: this used to return a single `false` for "cannot prove
// containment" (an unresolvable path, or a symlink chain that hits
// MAX_SYMLINK_HOPS and throws), on the theory that "cannot prove" is the
// strict/safe answer everywhere. It is NOT — this SSOT is consulted from two
// opposite directions (see the file header): a PERMISSION caller uses
// containment to GRANT leniency (false = deny the shortcut = fail closed,
// correct), while a DETECTION caller uses containment to ARM a block (false =
// do NOT arm = allow the write through unblocked = fail OPEN, wrong). A single
// hardcoded `false` was safe for the first shape and silently unsafe for the
// second — an attacker-crafted circular symlink ancestor of a glob/dynamic
// write target could force realResolve() to throw, forcing this function to
// "cannot prove" -> false -> the deny-glob qualifier never arms -> the write
// proceeds without the scrutiny that qualifier exists to add.
//
// `opts.onUnknown` (required boolean) makes the caller declare its own fail
// direction explicitly instead of inheriting an implicit one (CPR-8): pass
// `true` from a detection/block-arming caller so "cannot prove" resolves
// toward blocking, `false` from a permission/leniency caller so it resolves
// toward denying the shortcut. Missing/non-boolean `onUnknown` throws — a
// programmer-contract violation, never triggered by attacker-controlled
// input, so this does not weaken the "never throws on bad paths" behavior
// callers rely on for the actual resolution attempt below.
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
