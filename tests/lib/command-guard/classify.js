"use strict";
// tests/lib/command-guard/classify.js — which git invocations only read (#2590).
// A read runs the real git unchecked; everything else, unknown verbs and aliases included, is a
// write and goes through the target check in resolve-target.js. When in doubt a form is a write:
// a false write costs one rev-parse, a false read lets a test change a repo it does not own.

const GUARD_EXIT = 97;
const NETWORK_TOOLS = ["gh", "glab", "codex"];

// Verbs that never write a repo, a worktree file or config. The bash bin script and the Windows
// launcher take these straight to the real git (guard.conf `readverbs=`), so a verb listed here
// must be a read in every form except `--output`, which both of them also send to main.js.
const READ_VERBS = [
  "annotate", "blame", "cat-file", "check-attr", "check-ignore", "check-mailmap", "check-ref-format",
  "cherry", "count-objects", "describe", "diff", "diff-files", "diff-index", "diff-tree", "for-each-ref",
  "get-tar-commit-id", "grep", "help", "log", "ls-files", "ls-tree", "merge-base", "name-rev",
  "range-diff", "rev-list", "rev-parse", "shortlog", "show", "show-branch", "show-ref", "status",
  "var", "verify-commit", "verify-tag", "version", "whatchanged",
];

// The fast write path (guard.conf `fastverbs=` / `fastdeny=` / `fastdenyenv=`): a verb whose only
// write target is its own repository, preceded by nothing but `-C <dir>` / `-c <name=value>`
// pairs, no argument after them starting with a FAST_DENY_PREFIXES entry and none of FAST_DENY_ENV
// set, runs the real git without main.js once `rev-parse` with the same pairs (as main.js passes
// its globals) puts its git dir, common dir and work tree under the run root with no link on the
// way. Anything else, or any doubt, goes to main.js.
const FAST_WRITE_VERBS = [
  "add", "branch", "checkout", "cherry-pick", "commit", "commit-tree", "config", "gc", "hash-object", "merge",
  "mktag", "mktree", "mv", "notes", "pack-refs", "prune", "rebase", "reflog", "repack", "replace", "reset",
  "restore", "revert", "rm", "stash", "switch", "symbolic-ref", "tag", "update-index", "update-ref", "write-tree",
];
const FAST_DENY_PREFIXES = ["--system", "--global", "--file", "-f", "--output"];
const FAST_DENY_ENV = ["GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_COMMON_DIR", "GIT_CONFIG"];

// Global options that take the next argument as their value when not written `--opt=value`.
const VALUE_GLOBALS = ["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env", "--super-prefix", "--attr-source", "--list-cmds"];

// splitGlobals(args) — the options before the verb, the verb, and what follows it.
// cDirs lists every -C value in order; gitDir / workTree are the last --git-dir / --work-tree.
function splitGlobals(args) {
  const globals = [];
  const cDirs = [];
  let gitDir = null;
  let workTree = null;
  let i = 0;
  for (; i < args.length; i++) {
    const a = args[i];
    if (VALUE_GLOBALS.includes(a)) {
      const v = i + 1 < args.length ? args[i + 1] : "";
      globals.push(a, v);
      if (a === "-C") cDirs.push(v);
      if (a === "--git-dir") gitDir = v;
      if (a === "--work-tree") workTree = v;
      i++;
      continue;
    }
    const eq = a.indexOf("=");
    const name = eq > 0 ? a.slice(0, eq) : a;
    if (a.startsWith("--") && eq > 0 && VALUE_GLOBALS.includes(name)) {
      globals.push(a);
      if (name === "--git-dir") gitDir = a.slice(eq + 1);
      if (name === "--work-tree") workTree = a.slice(eq + 1);
      continue;
    }
    if (a.startsWith("-")) {
      globals.push(a);
      continue;
    }
    break;
  }
  return { globals, cDirs, gitDir, workTree, verb: i < args.length ? args[i] : null, rest: args.slice(i + 1) };
}

// operands(rest, valueOpts) — the non-option arguments, skipping the value of each option in
// valueOpts written as a separate argument; everything after `--` is an operand.
function operands(rest, valueOpts = []) {
  const out = [];
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i];
    if (a === "--") return out.concat(rest.slice(i + 1));
    if (a.startsWith("-") && a !== "-") {
      if (valueOpts.includes(a)) i++;
      continue;
    }
    out.push(a);
  }
  return out;
}

const has = (rest, ...names) => rest.some((a) => names.some((n) => a === n || a.startsWith(`${n}=`)));

const CONFIG_VALUE_OPTS = ["-f", "--file", "--blob", "--type", "--default", "--comment", "--value"];
const CONFIG_WRITE_FLAGS = ["--unset", "--unset-all", "--add", "--replace-all", "--edit", "-e", "--rename-section", "--remove-section"];
const CONFIG_READ_FLAGS = ["--get", "--get-all", "--get-regexp", "--get-urlmatch", "--get-color", "--get-colorbool", "--list", "-l"];
const CONFIG_SUBCOMMANDS = ["get", "list", "set", "unset", "rename-section", "remove-section", "edit"];

function isConfigRead(rest) {
  if (has(rest, ...CONFIG_WRITE_FLAGS)) return false;
  if (has(rest, ...CONFIG_READ_FLAGS)) return true;
  const ops = operands(rest, CONFIG_VALUE_OPTS);
  if (ops.length > 0 && CONFIG_SUBCOMMANDS.includes(ops[0])) return ops[0] === "get" || ops[0] === "list";
  return ops.length === 1;
}

const LISTING_VALUE_OPTS = ["--contains", "--no-contains", "--merged", "--no-merged", "--points-at", "--sort", "--format"];
const BRANCH_WRITE_FLAGS = ["-d", "-D", "--delete", "-m", "-M", "--move", "-c", "-C", "--copy", "-f", "--force",
  "-u", "--set-upstream-to", "--unset-upstream", "--edit-description", "-t", "--track", "--no-track"];
const TAG_WRITE_FLAGS = ["-d", "--delete", "-a", "--annotate", "-s", "--sign", "-u", "--local-user", "-m", "--message",
  "-F", "--file", "-f", "--force", "-e", "--edit"];

function isListing(rest, writeFlags) {
  if (has(rest, ...writeFlags)) return false;
  return has(rest, "--list", "-l") || operands(rest, LISTING_VALUE_OPTS).length === 0;
}

// isRead(verb, rest) — true when this invocation cannot write. ls-remote is a read only after the
// network check, which main.js runs first.
function isRead(verb, rest) {
  if (verb === null) return true;
  if (READ_VERBS.includes(verb)) return !has(rest, "--output", "--output-directory");
  const ops = operands(rest);
  const sub = ops.length > 0 ? ops[0] : null;
  switch (verb) {
    case "config":
      return isConfigRead(rest);
    case "branch":
      return isListing(rest, BRANCH_WRITE_FLAGS);
    case "tag":
      return has(rest, "-v", "--verify") || isListing(rest, TAG_WRITE_FLAGS);
    case "remote":
      return sub === null || sub === "get-url";
    case "stash":
      return sub === "list" || sub === "show";
    case "worktree":
      return sub === "list";
    case "reflog":
      return sub === null || sub === "show" || sub === "exists";
    case "notes":
      return sub === "list" || sub === "show";
    case "symbolic-ref":
      return !has(rest, "-d", "--delete") && ops.length <= 1;
    case "hash-object":
      return !rest.includes("-w");
    case "submodule":
      return sub === "status" || sub === "summary";
    case "ls-remote":
      return true;
    default:
      return false;
  }
}

module.exports = {
  GUARD_EXIT, NETWORK_TOOLS, READ_VERBS, VALUE_GLOBALS, FAST_WRITE_VERBS, FAST_DENY_PREFIXES, FAST_DENY_ENV,
  splitGlobals, operands, isRead,
};
