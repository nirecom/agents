// hooks/lib/bash-write-patterns/git-write-ir.js
// Git write detection (IR-based SSOT). Extracted from patterns.js (#1401 file-split:
// patterns.js exceeded the 500-line HARD limit). This module owns the BROAD
// FAIL-CLOSED git-write classifier: isGitWriteIR = "git AND not a known read".
//
// FORM recognition is by BASENAME (isGitBasename) so path-qualified / `.exe` /
// wrapped git all resolve to git. SUBCOMMAND classification is a read-allowlist
// (READ_SUBCOMMANDS + flag-conditioned reads); everything else defaults to WRITE.
// Unknown / future / exotic git subcommands therefore fail closed to write —
// closing the invocation-form gap class definitively.
//
// Re-exported by patterns.js so existing require() sites (classify.js,
// bash-write-targets/git.js, bash-write-patterns.js) are unchanged.

"use strict";
const { resolveEffectiveCommand, resolveEffectiveArgv, scanWrappedVerb } = require("./segment-utils");
const { FLAGS_WITH_ARG } = require("../parse-git-args");

// resolveGitSubArgv: skip leading git GLOBAL FLAGS so the subcommand is read from
// its effective position (modeled on resolveGhSubArgv). Returns { subArgv, hasConfigInjection }.
//
// hasConfigInjection: true when a skipped `-c <key>=<val>` or `--config-env <key>=<env>`
// (separated or attached) global flag was seen — used by isGitWriteIR (C3) so a
// config-injection command reaches the safety predicate even with a read subcommand.
//
// Value-taking global set MUST mirror parse-git-args.js FLAGS_WITH_ARG (SSOT).
// SECURITY (C2): without skipping value-taking globals, `git -C <path> commit`
// or `git --config-env core.hooksPath=VAR commit` shifts argv so the write
// subcommand is missed → git write fast-allows with no scope enforcement.
// SSOT (CPR-2): value-taking global set is the SAME as parse-git-args.js
// FLAGS_WITH_ARG — imported, not re-declared, so the two cannot drift.
const GIT_VALUE_TAKING_GLOBAL_FLAGS = FLAGS_WITH_ARG;
const GIT_CONFIG_INJECTION_FLAGS = new Set(["-c", "--config-env"]);
function resolveGitSubArgv(gitArgv) {
  let i = 0;
  let hasConfigInjection = false;
  while (i < gitArgv.length) {
    const tok = gitArgv[i];
    if (typeof tok !== "string" || tok[0] !== "-") break; // first non-flag = subcommand
    const eq = tok.indexOf("=");
    const flagName = eq === -1 ? tok : tok.slice(0, eq);
    if (GIT_CONFIG_INJECTION_FLAGS.has(flagName)) hasConfigInjection = true;
    if (eq !== -1) {
      // attached =value form (e.g. --config-env=k=v, -c k=v is rare but tolerated) — single token
      i += 1;
    } else if (GIT_VALUE_TAKING_GLOBAL_FLAGS.has(flagName)) {
      // value-taking flag with separate value (e.g. -C path, --config-env k=v) — flag + value
      i += 2;
    } else {
      // unknown/boolean lone flag (e.g. --no-pager, -p, --bare) — skip just it
      i += 1;
    }
  }
  return { subArgv: gitArgv.slice(i), hasConfigInjection };
}

// isGitBasename: recognize git regardless of how the binary is spelled. Strip any
// directory prefix (POSIX `/` or Windows `\`) and a trailing `.exe`, lowercase, and
// compare against "git". Catches `/usr/bin/git`, `./git`,
// `C:/Program Files/Git/cmd/git.exe`, `git.exe`, and wrapped forms — closing the
// invocation-form gap class (path-qualified git was previously missed because
// resolveEffectiveCommand returns cmd0 verbatim for non-wrapper commands).
function isGitBasename(cmd) {
  if (typeof cmd !== "string" || cmd === "") return false;
  const base = cmd.split(/[\\/]/).pop();
  if (!base) return false;
  return base.replace(/\.exe$/i, "").toLowerCase() === "git";
}

// Resolve the git argv for a single segment. Uses the shared effective-command
// resolver (segment-utils) so ALL wrapper/env-prefix forms are covered uniformly:
// direct `git`, `VAR=val git`, `env VAR=val git`, `env -u X git`, `env -i git`,
// `command git`, `nice git`, `nohup git`, etc. (GAP 3 — was previously limited to
// git / env VAR=val git / VAR=val git, missing `command` and env-flag variants).
// FORM recognition is by BASENAME (isGitBasename) so path-qualified / `.exe` spellings
// resolve to git too. Returns null when the segment does not resolve to git.
function resolveGitArgvForSegment(seg) {
  if (!seg || seg.cmd0 == null) return null;
  if (isGitBasename(resolveEffectiveCommand(seg))) return resolveEffectiveArgv(seg);
  return null;
}

// READ_SUBCOMMANDS: the git subcommands that are UNCONDITIONALLY read-only.
// This is the allowlist half of the fail-closed design: a subcommand is treated
// as a write UNLESS it is either in this set OR classified read by the
// flag-conditioned logic below. Anything unknown / future / exotic defaults to
// WRITE (the fail-closed safety net). When unsure about a subcommand, LEAVE IT
// OUT so it defaults to write — that is the intended safety posture.
const READ_SUBCOMMANDS = new Set([
  // Inspection / history / diff.
  "status", "log", "diff", "show", "describe", "blame", "annotate", "grep",
  "shortlog", "whatchanged", "range-diff", "diff-tree", "diff-index",
  "diff-files", "difftool", "cherry",
  // Ref / object plumbing (read).
  "rev-parse", "rev-list", "cat-file", "ls-files", "ls-tree", "ls-remote",
  "for-each-ref", "show-ref", "show-branch", "name-rev", "merge-base",
  "merge-tree", "var", "count-objects",
  // Verification (read).
  "verify-commit", "verify-tag", "verify-pack",
  // Attribute / ignore / format checks (read).
  "check-ignore", "check-attr", "check-ref-format",
  // Fetch is read-only w.r.t. the working tree / local refs the guard protects.
  "fetch",
  // Help / meta / UI (read).
  "version", "help", "instaweb", "gui", "gitk", "archive",
]);

// Read-only list/verify flags per ambiguous subcommand.
const BRANCH_READ_FLAGS = new Set([
  "-l", "--list", "-a", "-r", "-v", "-vv", "--show-current",
  "--contains", "--merged", "--no-merged", "--points-at", "--format",
]);
const BRANCH_MUTATE_FLAGS = new Set([
  "-d", "-D", "-m", "-M", "-c", "-C",
  "--set-upstream-to", "--unset-upstream", "--edit-description",
]);
const TAG_READ_FLAGS = new Set([
  "-l", "--list", "-n", "-v", "--verify", "--contains", "--merged",
  "--no-merged", "--points-at", "--sort", "--format",
]);
const CONFIG_READ_FLAGS = new Set([
  "--get", "--get-all", "--get-regexp", "--get-urlmatch", "--list", "-l",
]);
const CONFIG_WRITE_FLAGS = new Set([
  "--add", "--set", "--unset", "--unset-all", "--replace-all",
  "--rename-section", "--remove-section", "--edit", "-e",
]);
const REMOTE_READ_SUB = new Set(["show", "get-url"]);
const REFLOG_READ_SUB = new Set(["show", "list"]);

// classifyGitSubcommand: returns true when the subArgv is a WRITE.
// Design: read-allowlist, else WRITE (fail-closed backstop). sub0 is the first
// non-flag subcommand token. When sub0 is absent (bare `git` + global flags only,
// e.g. `git --version`), treat as read.
function classifyGitSubcommand(subArgv) {
  if (subArgv.length === 0) return false; // bare git / only global flags → read
  const sub0 = subArgv[0];
  const rest = subArgv.slice(1);
  const sub1 = subArgv[1];

  // Simple always-read subcommands.
  if (READ_SUBCOMMANDS.has(sub0)) return false;

  // hash-object: read WITHOUT -w; -w writes the object into the store.
  if (sub0 === "hash-object") return rest.includes("-w");

  // symbolic-ref: read form `git symbolic-ref <name>`; set form
  // `git symbolic-ref <name> <ref>` (two non-flag args) is a write.
  if (sub0 === "symbolic-ref") {
    const nonFlag = rest.filter((t) => typeof t === "string" && t[0] !== "-");
    return nonFlag.length >= 2;
  }

  // branch: READ only if it has a read flag AND no mutate flag; bare `git branch`
  // (list) is READ.
  if (sub0 === "branch") {
    if (rest.some((t) => BRANCH_MUTATE_FLAGS.has(t))) return true;
    if (rest.length === 0) return false;                    // bare = list
    if (rest.some((t) => BRANCH_READ_FLAGS.has(t))) return false;
    // Non-flag arg with no read flag → create/rename form → write.
    return true;
  }

  // tag: bare `git tag` = list (read); read if a list/verify flag present;
  // write if a create arg or -a/-s/-m/-f/-d present.
  if (sub0 === "tag") {
    if (rest.length === 0) return false;                    // bare = list
    if (rest.some((t) => TAG_READ_FLAGS.has(t) || (typeof t === "string" && (/^--sort=/.test(t) || /^--format=/.test(t))))) {
      // A read flag is present; still a write if a mutate flag is also present.
      const mutate = new Set(["-a", "-s", "-m", "-f", "-d"]);
      if (rest.some((t) => mutate.has(t))) return true;
      return false;
    }
    return true;                                            // create/delete form
  }

  // stash: READ only for list/show; bare `git stash` defaults to push = WRITE.
  if (sub0 === "stash") {
    if (sub1 === "list" || sub1 === "show") return false;
    return true;
  }

  // worktree: READ only for list.
  if (sub0 === "worktree") {
    return sub1 !== "list";
  }

  // notes: READ only for list/show.
  if (sub0 === "notes") {
    return !(sub1 === "list" || sub1 === "show");
  }

  // config: READ only with a pure read flag AND no write action.
  if (sub0 === "config") {
    if (rest.some((t) => CONFIG_WRITE_FLAGS.has(t))) return true;
    if (rest.some((t) => CONFIG_READ_FLAGS.has(t))) return false;
    // No read flag and no write flag: bare `git config` prints usage (read);
    // `git config key value` (two non-flag args) is a write; `git config key`
    // (one non-flag) is a read (get).
    const nonFlag = rest.filter((t) => typeof t === "string" && t[0] !== "-");
    return nonFlag.length >= 2;
  }

  // remote: READ for bare / -v / --verbose / show / get-url; WRITE otherwise
  // (add/remove/rename/set-url/set-head/set-branches/prune/update).
  if (sub0 === "remote") {
    if (rest.length === 0) return false;                    // bare = list
    if (sub1 === "-v" || sub1 === "--verbose") return false;
    if (REMOTE_READ_SUB.has(sub1)) return false;
    return true;
  }

  // reflog: READ for show/list/bare; WRITE for expire/delete.
  if (sub0 === "reflog") {
    if (rest.length === 0) return false;                    // bare = show
    if (REFLOG_READ_SUB.has(sub1)) return false;
    return true;
  }

  // checkout / switch / restore: all mutate the working tree / index → WRITE.
  // (git switch and git restore were prior gaps.)
  if (sub0 === "checkout" || sub0 === "switch" || sub0 === "restore") return true;

  // add: staging updates the index but does NOT mutate the working tree or refs;
  // staged files are separately scope-checked. The guard only treats `git add`
  // as a write when the argument is an append-only doc file (docs/history* or
  // CHANGELOG.md) — those must go through doc-append, not a raw add. Generic
  // `git add .` / `git add <src>` is NOT a write here (preserves prior behavior;
  // avoids over-blocking the most common staging form).
  if (sub0 === "add") {
    return rest.some((t) => typeof t === "string" && (/docs\/history/.test(t) || /CHANGELOG\.md/.test(t)));
  }

  // Everything else → WRITE (fail-closed safety net: unknown / future /
  // path-qualified / exotic subcommands default to write).
  return true;
}

// True when a single git argv is a write (or carries config-injection).
function isGitWriteArgv(gitArgv) {
  if (!gitArgv || gitArgv.length === 0) return false;

  const { subArgv, hasConfigInjection } = resolveGitSubArgv(gitArgv);

  // C3: config-injection (`-c k=v` / `--config-env k=v`) reaches the safety
  // predicate regardless of read/write subcommand.
  if (hasConfigInjection) return true;

  return classifyGitSubcommand(subArgv);
}

// isGitWriteIR: IR-owned git write detector (modeled on isGhWriteIR). Covers the
// 18 write forms + config-injection reachability (C3).
// BUG 1 fix: iterate over ALL segments, not just the first git segment. A
// sequenced command like `git status && git commit` must be flagged as a write —
// checking only the first git segment (a read) would fast-allow the whole command
// and let `git commit` bypass the main-worktree guard.
function isGitWriteIR(ir) {
  if (!ir || ir.parseFailure === true) return false;
  if (!ir.segments || ir.segments.length === 0) return false;

  for (const seg of ir.segments) {
    const gitArgv = resolveGitArgvForSegment(seg);
    if (gitArgv !== null) {
      if (isGitWriteArgv(gitArgv)) return true; // ANY git write segment → write
      continue;
    }
    // Fail-closed safety net (segment-utils AMBIGUOUS bail): a wrapper segment
    // whose effective command could NOT be cleanly resolved past an
    // unclassifiable option may still hide a wrapped `git <writeverb>`. Scan the
    // raw argv for a bare `git` token followed by a write argv. Only fires
    // inside wrapper segments with an ambiguous peel (see scanWrappedVerb), so
    // it never over-blocks ordinary commands.
    if (scanWrappedVerb(seg, (tok, rest) => isGitBasename(tok) && isGitWriteArgv(rest))) return true;
  }
  // No git segment resolved to a write.
  return false;
}

module.exports = { isGitWriteIR, isGitWriteArgv, resolveGitSubArgv, resolveGitArgvForSegment, isGitBasename, classifyGitSubcommand };
