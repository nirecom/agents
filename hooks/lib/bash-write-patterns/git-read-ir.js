"use strict";
// hooks/lib/bash-write-patterns/git-read-ir.js — the positive "pure read" judgement for git
// (#2403 N5). "Not a write" (git-write-ir.js) is never the reason to allow: this module asks
// the opposite question and fails closed on anything it does not recognise. The subcommand
// and read-flag sets stay owned by git-write-ir.js; only concepts that module lacks live here
// (global-option allowlist, list-implying flags, options that launch an external program).
// Design and the accepted config-driven launches: docs/architecture/claude-code/settings.md.

const {
  PURE_READ_SUBCOMMANDS,
  BRANCH_READ_FLAGS,
  TAG_READ_FLAGS,
  resolveGitSubArgv,
  isGitWriteArgv,
} = require("./git-write-ir");

const GLOBAL_VALUE_FLAGS = new Set(["-C", "--git-dir", "--work-tree"]);
const GLOBAL_BOOL_FLAGS = new Set([
  "--no-pager", "-P", "--no-optional-locks", "--literal-pathspecs", "--glob-pathspecs",
  "--noglob-pathspecs", "--icase-pathspecs", "--no-replace-objects",
]);

// Long options matched by prefix, because git accepts any unique abbreviation.
const EXEC_CAPABLE_LONG = Object.freeze([
  "--ext-diff", "--textconv", "--filters", "--output", "--open-files-in-pager", "--show-signature",
]);
const GREP_PAGER_SHORT = "O";
const SIGNATURE_PLACEHOLDER_RE = /%G|%\(signature/;

const TAG_GPG_FLAGS = new Set(["-v", "--verify"]);
const BRANCH_LIST_FLAGS = new Set(["-l", "--list", "--contains", "--merged", "--no-merged", "--points-at"]);
const TAG_LIST_FLAGS = new Set(["-l", "--list", "-n", "--contains", "--merged", "--no-merged", "--points-at"]);
const TAG_N_NUM_RE = /^-n\d+$/;
const STASH_READ_SUB = new Set(["list", "show"]);
const WORKTREE_LIST_FLAGS = new Set(["--porcelain", "-v", "--verbose", "-z"]);

const flagName = (tok) => {
  const eq = tok.indexOf("=");
  return eq === -1 ? tok : tok.slice(0, eq);
};
const isFlag = (tok) => tok.length > 1 && tok[0] === "-";

// Returns the index of the subcommand, or -1 when a global option is not on the allowlist.
function skipGlobals(argv) {
  let i = 0;
  while (i < argv.length) {
    const tok = argv[i];
    if (tok[0] !== "-") return i;
    const name = flagName(tok);
    if (GLOBAL_VALUE_FLAGS.has(name)) {
      if (name !== tok) {
        if (!name.startsWith("--")) return -1;
        i += 1;
      } else {
        if (i + 1 >= argv.length) return -1;
        i += 2;
      }
      continue;
    }
    if (name === tok && GLOBAL_BOOL_FLAGS.has(tok)) {
      i += 1;
      continue;
    }
    return -1;
  }
  return i;
}

function launchesProgram(sub0, opts) {
  for (const tok of opts) {
    if (SIGNATURE_PLACEHOLDER_RE.test(tok)) return true;
    if (tok.startsWith("--") && tok.length > 2) {
      const name = flagName(tok);
      if (EXEC_CAPABLE_LONG.some((f) => f.startsWith(name))) return true;
    } else if (sub0 === "grep" && isFlag(tok) && tok.slice(1).includes(GREP_PAGER_SHORT)) {
      return true;
    }
  }
  return false;
}

function isListFlagForm(rest, allowed, listFlags, extraAllowed) {
  let listMode = false;
  let operands = 0;
  for (const tok of rest) {
    if (isFlag(tok)) {
      const name = flagName(tok);
      if (extraAllowed && extraAllowed(tok)) { listMode = true; continue; }
      if (!allowed.has(name)) return false;
      if (listFlags.has(name)) listMode = true;
    } else {
      operands += 1;
    }
  }
  return operands === 0 || listMode;
}

function isRemoteRead(rest) {
  if (rest.length === 0) return true;
  if (rest.length === 1 && (rest[0] === "-v" || rest[0] === "--verbose")) return true;
  if (rest[0] === "get-url") return rest.length === 2 && !isFlag(rest[1]);
  if (rest[0] !== "show") return false;
  const tail = rest.slice(1);
  if (tail.some((t) => isFlag(t) && t !== "-n")) return false;
  // A named remote is contacted (ssh / credential helper) unless -n keeps it local.
  return !tail.some((t) => !isFlag(t)) || tail.includes("-n");
}

function isConditionalRead(sub0, rest) {
  switch (sub0) {
    case "branch":
      return isListFlagForm(rest, BRANCH_READ_FLAGS, BRANCH_LIST_FLAGS, null);
    case "tag": {
      const allowed = new Set([...TAG_READ_FLAGS].filter((f) => !TAG_GPG_FLAGS.has(f)));
      return isListFlagForm(rest, allowed, TAG_LIST_FLAGS, (t) => TAG_N_NUM_RE.test(t));
    }
    case "stash":
      return STASH_READ_SUB.has(rest[0]);
    case "remote":
      return isRemoteRead(rest);
    case "worktree":
      return rest[0] === "list" && rest.slice(1).every((t) => WORKTREE_LIST_FLAGS.has(t));
    default:
      return false;
  }
}

/**
 * @param {string[]} argv git's argv without the `git` word
 * @returns {boolean} true only for a recognised pure read; false on any doubt
 */
function isGitPureReadArgv(argv) {
  try {
    if (!Array.isArray(argv) || argv.length === 0) return false;
    if (!argv.every((t) => typeof t === "string")) return false;
    if (resolveGitSubArgv(argv).hasConfigInjection) return false;
    const subIdx = skipGlobals(argv);
    if (subIdx < 0 || subIdx >= argv.length) return false;
    if (isGitWriteArgv(argv)) return false;

    const sub0 = argv[subIdx];
    const rest = argv.slice(subIdx + 1);
    const dd = rest.indexOf("--");
    const opts = dd === -1 ? rest : rest.slice(0, dd);
    if (launchesProgram(sub0, opts)) return false;

    if (PURE_READ_SUBCOMMANDS.has(sub0)) return true;
    if (dd !== -1) return false;
    return isConditionalRead(sub0, rest);
  } catch (_e) {
    return false;
  }
}

module.exports = { isGitPureReadArgv, EXEC_CAPABLE_LONG };
