"use strict";

const path = require("path");
const { spawnSync } = require("child_process");
const { normalizeCwd } = require("../../lib/path-normalize");
const { stripQuotedArgs } = require("../../lib/strip-quoted-args");
const { hasShellChaining, isExcluded, hasWorktreeEndSkillPrefix, stripWorktreeEndSkillPrefix, rejectRceGitFlags, rejectInterpreterAndChaining } = require("../shared-cmd-utils");
const { parseGitCPath } = require("../git-repo-detection");
const { collectBashWriteTargets } = require("../bash-write-scope");
const { rejectsUnsafeArgTail } = require("../arg-tail-guard");
const { resolveAgentsConfigDir } = require("../../lib/agents-config-dir");
// Extracted siblings (file-split per rules/coding/file-split.md) — re-exported below.
const { isAllowedWorktreeCommand } = require("./worktree-command");
const { isAllowedWorkerScriptInvocation } = require("./worker-script");

/**
 * True if cmd is an isolated `git pull --ff-only` or `git merge --ff-only`
 * command. Allows the merge step from the main worktree — the one operation
 * main is reserved for ("Main worktree is reserved for merge/pull only").
 *
 * Blocks: shell chaining (`&& git push` etc.), `--no-ff` (overrides ff-only
 * intent), non-git tools (e.g. `svn merge --ff-only`), and `git rebase
 * --ff-only` (rebase is not merge).
 */
function isAllowedFastForwardMerge(cmd) {
  if (rejectRceGitFlags(cmd)) return false;
  if (rejectInterpreterAndChaining(cmd)) return false;
  if (hasShellChaining(cmd)) return false;
  if (!/\bgit\b/.test(cmd)) return false;
  if (/\s--no-ff\b/.test(cmd)) return false;
  // Strict subcommand position: only flag tokens (and their values) may appear
  // between `git` and the `pull`/`merge` subcommand. This prevents false
  // matches like `git commit -m "merge --ff-only"` or `git push origin merge
  // --ff-only` where `merge` appears as an argument value rather than as the
  // subcommand. Pattern: `(?:-flag value? )*` then subcommand.
  const isPullFf  = /\bgit\s+(?:-\S+(?:\s+[^-|;&\s]\S*)?\s+)*pull\b[^|;&]*\s--ff-only\b/.test(cmd);
  const isMergeFf = /\bgit\s+(?:-\S+(?:\s+[^-|;&\s]\S*)?\s+)*merge\b[^|;&]*\s--ff-only\b/.test(cmd);
  return isPullFf || isMergeFf;
}

/**
 * True if cmd is an isolated `bash -c '...'` matching exactly the
 * read-only CONFIRM_* probe shape used by planning skills:
 *   bash -c 'cd "$AGENTS_CONFIG_DIR" && bash "$AGENTS_CONFIG_DIR/bin/confirm-off" KEY [on|off]'
 *
 * Does NOT call hasShellChaining() — the probe body intentionally uses
 * && as control flow. Safety is enforced by structural clause matching.
 * Coupling: if the skill probe string changes, update this matcher in sync.
 * See docs/architecture/claude-code/workflow.md for the contract.
 */
function isAllowedReadOnlyConfigCheck(cmd) {
  if (!cmd || typeof cmd !== "string") return false;
  const m = cmd.match(/^\s*(?:[A-Za-z_][A-Za-z0-9_]*=[^\s]*\s+)*bash\s+-c\s+(['"])([\s\S]+)\1\s*$/);
  if (!m) return false;
  const quote = m[1];
  let body = m[2];
  // Allow escaped same-quote inside body (e.g. `cd \"$AGENTS_CONFIG_DIR\"` when outer is `"`).
  // The clause regexes below are anchored, so any unescaped quote that breaks the
  // structure will be caught at the clause-match step.
  body = body.replace(quote === '"' ? /\\"/g : /\\'/g, quote);
  if (body.includes("`")) return false;
  if (body.includes("$(")) return false;
  if (body.includes(">") || body.includes("<")) return false;
  if (body.includes(";")) return false;
  if (body.replace(/\|\|/g, "").includes("|")) return false;
  const clauses = body.split(/\s*&&\s*/);
  if (clauses.length !== 2) return false;
  const [c1, c2] = clauses;
  if (!/^cd\s+(?:"?\$AGENTS_CONFIG_DIR"?)\s*$/.test(c1.trim())) return false;
  if (!/^bash\s+"?\$AGENTS_CONFIG_DIR\/bin\/confirm-off"?\s+[A-Z][A-Z0-9_]*(?:\s+(?:on|off))?\s*$/.test(c2.trim())) return false;
  return true;
}

/**
 * Resolve the upstream tracking ref for the current branch.
 * If remote is specified, only returns an upstream on that remote.
 */
function resolveUpstream(repoRoot, remote) {
  try {
    const branchRes = spawnSync("git", ["symbolic-ref", "--short", "HEAD"], {
      cwd: repoRoot, encoding: "utf8", timeout: 2000,
    });
    if (branchRes.status !== 0) return null;
    const branch = (branchRes.stdout || "").trim();
    if (!branch) return null;
    const upRes = spawnSync("git", ["rev-parse", "--abbrev-ref", `${branch}@{upstream}`], {
      cwd: repoRoot, encoding: "utf8", timeout: 2000,
    });
    if (upRes.status !== 0) return null;
    const upstream = (upRes.stdout || "").trim();
    if (!upstream) return null;
    if (remote && !upstream.startsWith(`${remote}/`)) return null;
    return upstream;
  } catch (e) { return null; }
}

// Merge branch strict-head guards (C2 — #1982): env assignments and launcher
// chains preceding `git merge` are rejected because merge invokes the configured
// editor (GIT_EDITOR/VISUAL/EDITOR/core.editor). rejectInterpreterAndChaining
// catches bash/python/etc. as the command head but intentionally allows
// `sudo git …` / `VAR=x git …`, safe for the editor-free cleanup subcommands
// (stash/restore/checkout). For merge only, those forms are blocked too.
const MERGE_ENV_PREFIX_RE = /^\s*[A-Za-z_][A-Za-z0-9_]*=\S*(?:\s+[A-Za-z_][A-Za-z0-9_]*=\S*)*\s+git\b/;
const MERGE_LAUNCHER_RE = /^\s*(?:env|sudo|exec|command)\s+(?:(?:env|sudo|exec|command)\s+)*git\b/;

/**
 * Allow `git push` from the main worktree when every file in every outgoing
 * commit is covered by ENFORCE_WORKTREE_EXCLUDE. Uses `git log --name-only`
 * to enumerate all touched files (not just net diff — a file touched then
 * reverted within the range still counts).
 * Fail-closed on unsupported refspec shapes, missing upstream, or git errors.
 */
function isAllowedPushAllExcluded(cmd, repoRoot, excludePatterns) {
  try {
    if (!excludePatterns || excludePatterns.length === 0) return false;
    if (rejectRceGitFlags(cmd)) return false;
    if (rejectInterpreterAndChaining(cmd)) return false;
    if (hasShellChaining(cmd)) return false;
    if (!/\bgit\b.*\bpush\b/.test(cmd)) return false;

    const stripped = stripQuotedArgs(cmd);
    const tokens = stripped.trim().split(/\s+/);
    const pushIdx = tokens.findIndex((t) => t === "push");
    if (pushIdx === -1) return false;

    const KNOWN_FLAGS = new Set([
      "-q", "--quiet", "-v", "--verbose",
      "--porcelain", "-n", "--dry-run", "--atomic",
    ]);
    const UPSTREAM_FLAGS = new Set(["-u", "--set-upstream"]);
    const positionals = [];
    let sawUpstreamFlag = false;
    for (const t of tokens.slice(pushIdx + 1)) {
      if (UPSTREAM_FLAGS.has(t)) { sawUpstreamFlag = true; continue; }
      if (KNOWN_FLAGS.has(t)) continue;
      if (t.startsWith("-")) return false; // unknown flag → fail-closed
      positionals.push(t);
    }
    // -u/--set-upstream requires an explicit <remote> <branch> — fail-closed otherwise
    if (sawUpstreamFlag && positionals.length !== 2) return false;

    let upstreamRef;
    if (positionals.length === 0) {
      upstreamRef = resolveUpstream(repoRoot);
    } else if (positionals.length === 1) {
      upstreamRef = resolveUpstream(repoRoot, positionals[0]);
    } else if (positionals.length === 2) {
      const [remote, branch] = positionals;
      if (branch.includes(":") || branch.startsWith("refs/") || branch.startsWith("+")) return false;
      if (!/^[A-Za-z0-9._\/-]+$/.test(branch)) return false;
      const checkRes = spawnSync("git", ["rev-parse", "--verify", `${remote}/${branch}`], {
        cwd: repoRoot, timeout: 2000,
      });
      if (checkRes.status !== 0) return false;
      upstreamRef = `${remote}/${branch}`;
    } else {
      return false; // multiple refspecs → fail-closed
    }
    if (!upstreamRef) return false;

    const logRes = spawnSync(
      "git", ["log", "--name-only", "--pretty=format:", `${upstreamRef}..HEAD`],
      { cwd: repoRoot, encoding: "utf8", timeout: 10000 }
    );
    if (logRes.status !== 0) return false;

    // Anchor relative paths from git log against repoRoot (not process.cwd):
    // isExcluded internally calls path.resolve which would otherwise resolve
    // against the hook's cwd, mis-matching absolute-style EXCLUDE patterns.
    const files = (logRes.stdout || "")
      .split("\n")
      .map((f) => f.trim())
      .filter(Boolean)
      .map((f) => path.resolve(repoRoot, normalizeCwd(f) || f));
    if (files.length === 0) return true; // no outgoing commits → allow
    return files.every((f) => isExcluded(f, excludePatterns));
  } catch (e) { return false; }
}

/**
 * True when cmd is `git [merge|rebase|cherry-pick] (--abort|--continue|--skip)`
 * from the main worktree. Mid-operation actions only mutate in-progress state
 * files (.git/MERGE_HEAD, rebase-merge/, sequencer/) — never tracked files in
 * linked worktrees — so no linked-worktree-count gate. Rejects: interpreters,
 * shell chaining, RCE git flags, multiple -C, a -C not resolving to repoRoot,
 * and any first token after the subcommand other than the three actions.
 */
function isAllowedMidOperationAbort(cmd, repoRoot) {
  if (!cmd || typeof cmd !== "string") return false;
  if (!repoRoot) return false;
  if (!/^\s*git\b/.test(cmd)) return false;
  if (rejectRceGitFlags(cmd)) return false;
  if (rejectInterpreterAndChaining(cmd)) return false;
  if (hasShellChaining(cmd)) return false;
  if (!/\bgit\b/.test(cmd)) return false;

  // Multiple -C flags → reject (same gap-closing policy as isAllowedMainWorktreeCleanup).
  if ((cmd.match(/\s-C\s/g) || []).length > 1) return false;
  if (/\s-C\s/.test(stripQuotedArgs(cmd))) {
    const cArg = parseGitCPath(cmd);
    if (!cArg) return false;
    try {
      const normC    = normalizeCwd(cArg)    || cArg;
      const normBase = normalizeCwd(repoRoot) || repoRoot;
      if (path.resolve(normC).toLowerCase() !== path.resolve(normBase).toLowerCase()) return false;
    } catch (e) { return false; }
  }

  const stripped = stripQuotedArgs(cmd);
  const subMatch = stripped.match(
    /\bgit\b(?:\s+-C\s+\S+)?(?:\s+-\S+(?:\s+\S+)?)*\s+(merge|rebase|cherry-pick)\b([\s\S]*)$/
  );
  if (!subMatch) return false;
  const rest = subMatch[2] || "";
  const firstTok = rest.trim().split(/\s+/)[0] || "";
  const MID_OP_ACTIONS = new Set(["--abort", "--continue", "--skip"]);
  return MID_OP_ACTIONS.has(firstTok);
}

/**
 * True when cmd is an approved cleanup-class git command (#297):
 *   git [-C <repoRoot>] stash (push|pop|apply|drop|clear) [...]
 *   git [-C <repoRoot>] restore [--staged] <paths>   — no --source
 *   git [-C <repoRoot>] checkout [HEAD] -- <paths>   — `--` required
 *   git [-C <repoRoot>] merge --no-edit origin/<upstream-branch>  — #1982
 * Rejects shell chaining, interpreters, RCE git flags, multiple -C, a -C not
 * resolving to repoRoot. Per-subcommand rules are documented at their sites.
 */
function isAllowedMainWorktreeCleanup(cmd, repoRoot) {
  if (!cmd || typeof cmd !== "string") return false;
  if (!repoRoot) return false;
  // merge (below) invokes the configured editor, so RCE-capable git flags
  // (-c, --upload-pack, --receive-pack) are rejected for the whole class.
  if (rejectRceGitFlags(cmd)) return false;
  const skillPrefixed = hasWorktreeEndSkillPrefix(cmd);
  if (skillPrefixed) cmd = stripWorktreeEndSkillPrefix(cmd);
  if (rejectInterpreterAndChaining(cmd)) return false;
  if (hasShellChaining(cmd)) return false;
  if (!/\bgit\b/.test(cmd)) return false;

  // -C path, if present, must resolve to repoRoot.
  // Reject multiple -C flags — parseGitCPath only validates the first;
  // git uses the last (or cumulative), creating an ambiguity gap.
  if ((cmd.match(/\s-C\s/g) || []).length > 1) return false;
  if (/\s-C\s/.test(stripQuotedArgs(cmd))) {
    const cArg = parseGitCPath(cmd);
    if (!cArg) return false;
    try {
      const normC    = normalizeCwd(cArg)    || cArg;
      const normBase = normalizeCwd(repoRoot) || repoRoot;
      if (path.resolve(normC).toLowerCase() !== path.resolve(normBase).toLowerCase()) return false;
    } catch (e) { return false; }
  }

  // Find the git subcommand (skip `git`, optional `-C <path>`, optional global flags).
  const stripped = stripQuotedArgs(cmd);
  const subMatch = stripped.match(
    /\bgit\b(?:\s+-C\s+\S+)?(?:\s+-\S+(?:\s+\S+)?)*\s+(stash|restore|checkout|merge)\b([\s\S]*)$/
  );
  if (!subMatch) return false;
  const sub  = subMatch[1];
  const rest = subMatch[2] || "";

  if (sub === "stash") {
    const firstToken = rest.trim().split(/\s+/)[0] || "";
    const ALLOWED_STASH = new Set(["", "push", "pop", "apply", "drop", "clear"]);
    // A leading `-` flag is a push modifier (e.g. `git stash -u`) — allowed.
    if (!ALLOWED_STASH.has(firstToken) && !firstToken.startsWith("-")) return false;
  } else if (sub === "restore") {
    if (/\s--source(?:=|\s)/.test(cmd)) return false;
  } else if (sub === "merge") {
    // Sanctioned divergence-recovery merge (#1982): git merge --no-edit
    // origin/<branch>. --no-edit is mandatory: diverged merges open the
    // configured editor by default; requiring it prevents a hang in
    // non-interactive calls and closes the editor RCE path. Strict command
    // head (C2): `\bgit\b` in subMatch is non-anchored, so a command like
    // `echo git merge …` passes subMatch and must be rejected here.
    if (!/^\s*git(?:\s+-C\s+\S+)?\s+merge\b/.test(cmd)) return false;
    if (MERGE_ENV_PREFIX_RE.test(cmd) || MERGE_LAUNCHER_RE.test(cmd)) return false;
    // Strict form: --no-edit then exactly one origin/<branch> refspec. Rejects
    // extra flags, --ff-only (ff predicate territory), --abort/--continue/--skip
    // (isAllowedMidOperationAbort territory), colon refspecs, `+`, refs/ form.
    const m = rest.trim().match(/^--no-edit\s+origin\/([A-Za-z0-9._\/-]+)$/);
    if (!m) return false;
    // C1: operand must match the current branch's upstream on origin (fail-closed).
    const upstream = resolveUpstream(repoRoot, "origin");
    if (!upstream || upstream !== ("origin/" + m[1])) return false;
    // No linked-worktree count gate: merge is symmetric with the ff-only
    // pull/merge predicate, which also bypasses it. Git refuses to overwrite
    // files checked out in a linked worktree during a merge.
    return true;
  } else { // checkout
    // Path-restore form: requires `--` separator before the file paths.
    if (!/\s--(?:\s|$)/.test(rest)) return false;
    // Reject branch-creation flags before the `--`.
    const beforeSep = rest.split(/\s--(?:\s|$)/)[0] || "";
    if (/(^|\s)-[bBf](\s|$)/.test(beforeSep)) return false;
    // Allow only no-token-before-`--` (→ `git checkout -- <paths>`) or
    // exactly `HEAD` before `--` (→ `git checkout HEAD -- <paths>`).
    const before = beforeSep.trim();
    if (before !== "" && before !== "HEAD") return false;
  }

  // Runtime gate: no linked worktrees remain. Fail-closed on git error.
  try {
    const r = spawnSync("git", ["worktree", "list", "--porcelain"], {
      cwd: repoRoot, encoding: "utf8", timeout: 2000,
    });
    if (r.status !== 0) return false;
    const wtCount = ((r.stdout || "").match(/^worktree\s/gm) || []).length;
    if (wtCount < 1) return false;
    // stash is ref-only (never rewrites tracked working-tree files), so a
    // skill-prefixed stash needs no linked-worktree upper bound (#1024).
    if (skillPrefixed && sub === "stash") return true;
    const maxCount = skillPrefixed ? 2 : 1;
    return wtCount <= maxCount;
  } catch (e) { return false; }
}

/**
 * True when cmd is the canonical compose-doc-append-entry dispatch shape:
 *   bash "<AGENTS_CONFIG_DIR>/bin/compose-doc-append-entry" [--flag value]...
 * Rejects shell chaining, substitutions, redirects, wrong interpreter/script
 * path, unset AGENTS_CONFIG_DIR. rejectInterpreterAndChaining is intentionally
 * NOT called (it rejects any `bash …` head); safety comes from the raw argTail
 * scan below, same style as isAllowedReadOnlyConfigCheck. Consumer: the WE-21
 * manual recovery path in skills/worktree-end/scripts/cleanup-cascade.md — if
 * that command's shape changes, update this matcher.
 */
function isAllowedComposeDocAppend(cmd, repoRoot) {
  if (!cmd || typeof cmd !== "string") return false;
  // Marker-validated config dir (#1630) — env-independent; null stays fail-closed.
  const acd = resolveAgentsConfigDir();
  if (!acd) return false;

  // Structural opening: `bash "<path>"` double-quoted only (matches worker spec literal).
  const m = cmd.match(/^\s*bash\s+"([^"]+)"(\s[\s\S]*)?$/);
  if (!m) return false;
  const scriptPath = m[1];
  const argTail    = m[2] || "";

  // Resolve both sides case-insensitively (Windows filesystem).
  let normScript, normTarget;
  try {
    const expectedTarget = path.join(acd, "bin", "compose-doc-append-entry");
    normScript = path.resolve(normalizeCwd(scriptPath) || scriptPath);
    normTarget = path.resolve(normalizeCwd(expectedTarget) || expectedTarget);
  } catch (e) { return false; }
  if (normScript.toLowerCase() !== normTarget.toLowerCase()) return false;

  // Span-aware argTail scan (`sanctioned-bin`: no redirect of any form, no bare
  // `&`), so a metacharacter inside a quoted argument value stays data while a
  // substitution or ANSI-C word is rejected wherever it sits.
  if (rejectsUnsafeArgTail(argTail, "sanctioned-bin")) return false;

  void repoRoot; // signature symmetry with sibling predicates
  return true;
}

/**
 * True when cmd is a supervisor bin tool invocation whose write targets (if any)
 * resolve to /tmp/ (the universal output sink for supervisor tools).
 *
 * Approved scripts:
 *   bash "$AGENTS_CONFIG_DIR/bin/supervisor-review-codex" — may write to /tmp/
 *   node "$AGENTS_CONFIG_DIR/bin/supervisor-write-alert" — no write targets
 *
 * Hard restriction: any redirect present must point to /tmp/.
 */
function isAllowedSupervisorBinTool(cmd) {
  if (!cmd) return false;

  // Pattern: bash or node invoking a supervisor-* bin tool (quoted or unquoted AGENTS_CONFIG_DIR).
  const supervisorBinPattern = /(?:bash|node)\s+"?\$?\{?AGENTS_CONFIG_DIR\}?\/bin\/supervisor-(?:review-codex|write-alert)/;
  if (!supervisorBinPattern.test(cmd)) return false;

  // If there's a redirect, it must point to /tmp/.
  if (/>/.test(cmd) && !/>\s*(['"])?\/tmp\//.test(cmd)) return false;

  return true;
}

/**
 * True when cmd is the canonical clarify-guard-loop invocation:
 *   bash "<AGENTS_CONFIG_DIR>/bin/github-issues/clarify-guard-loop.sh" [args...]
 * (double-quoted script path only). Rejects: shell chaining, command substitution,
 * redirects, single-quoted path, wrong interpreter, wrong script path.
 * The guard script writes the GUARD_ATTEMPT counter internally (no redirect visible
 * to the hook), so collectBashWriteTargets returns 0 targets → allow.
 */
function isAllowedClarifyGuardLoop(cmd, repoRoot) {
  if (!cmd || typeof cmd !== "string") return false;
  // Marker-validated config dir (#1630) — env-independent; null stays fail-closed.
  const acd = resolveAgentsConfigDir();
  if (!acd) return false;

  // Must start with: bash "<double-quoted-path>" [args...]
  const m = cmd.match(/^\s*bash\s+"([^"]+)"(\s[\s\S]*)?$/);
  if (!m) return false;
  const scriptPath = m[1];
  const argTail    = m[2] || "";

  // Identity: script path must match AGENTS_CONFIG_DIR/bin/github-issues/clarify-guard-loop.sh
  let normScript, normTarget;
  try {
    const expectedTarget = path.join(acd, "bin", "github-issues", "clarify-guard-loop.sh");
    normScript = path.resolve(normalizeCwd(scriptPath) || scriptPath);
    normTarget = path.resolve(normalizeCwd(expectedTarget) || expectedTarget);
  } catch (e) { return false; }
  if (normScript.toLowerCase() !== normTarget.toLowerCase()) return false;

  // Span-aware argTail scan — same `sanctioned-bin` profile as :341 (CPR-ORTH).
  if (rejectsUnsafeArgTail(argTail, "sanctioned-bin")) return false;

  // Fail-closed: any write targets in the command → reject
  const { targets } = collectBashWriteTargets(cmd);
  if (targets && targets.length > 0) return false;

  void repoRoot;
  return true;
}

/**
 * True when cmd is a `bash -c '...'` invocation whose inner body is read-only
 * (no writes, no chaining operators, no $() with write content).
 * Delegates to isReadOnlyInterpreterC from classify.js.
 * Fail-closed: returns false on any error or missing dependency.
 */
function isAllowedReadOnlyWorkflowCli(cmd) {
  if (!cmd || typeof cmd !== "string") return false;
  try {
    const { isReadOnlyInterpreterC } = require("../../lib/bash-write-patterns/classify");
    if (typeof isReadOnlyInterpreterC !== "function") return false;
    return isReadOnlyInterpreterC(cmd) === true;
  } catch (_) {
    return false;
  }
}

module.exports = {
  isAllowedWorktreeCommand,
  isAllowedFastForwardMerge,
  isAllowedReadOnlyConfigCheck,
  isAllowedPushAllExcluded,
  isAllowedMidOperationAbort,
  isAllowedMainWorktreeCleanup,
  isAllowedComposeDocAppend,
  isAllowedWorkerScriptInvocation,
  isAllowedSupervisorBinTool,
  isAllowedClarifyGuardLoop,
  isAllowedReadOnlyWorkflowCli,
};
