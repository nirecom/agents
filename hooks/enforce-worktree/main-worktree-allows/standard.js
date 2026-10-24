"use strict";

const path = require("path");
const { spawnSync } = require("../../lib/limited-child-process");
const { normalizeCwd } = require("../../lib/path-normalize");
const { isExcluded, rejectRceGitFlags } = require("../shared-cmd-utils");
const { collectBashWriteTargets } = require("../bash-write-scope");
const { rejectsUnsafeArgTail } = require("../arg-tail-guard");
const { resolveScriptCheckoutRoot } = require("../../lib/script-checkout-root");
const { singleInvocation, leadingAssignments, withoutWorktreeEndSkillPrefix, gitSubcommand, gitCDirIsRepo, redirectsUnderTmp } = require("./command-shape");
// Extracted siblings (file-split per rules/coding/file-split.md) — re-exported below.
const { isAllowedWorktreeCommand } = require("./worktree-command");
const { isAllowedWorkerScriptInvocation, describeVariableScriptPath } = require("./worker-script");
const { isAllowedSupervisorBinTool } = require("./supervisor-bin");

// One `git` invocation (command-shape.js) with fd-dup or /tmp/ redirects only.
function singleGitInvocation(cmd) {
  if (rejectRceGitFlags(cmd)) return null;
  const seg = singleInvocation(cmd);
  if (!seg || !redirectsUnderTmp(seg)) return null;
  return gitSubcommand(seg);
}

// One redirect-free `bash "<path>" [args]` invocation -> [, path, argTail], else null.
function bashQuotedScript(cmd) {
  const seg = singleInvocation(cmd);
  if (!seg || seg.cmd0 !== "bash" || seg.cmd0Raw !== "bash" || seg.redirects.length !== 0) return null;
  const m = cmd.match(/^\s*bash\s+"([^"]+)"(\s[\s\S]*)?$/);
  if (!m || seg.argv[0] !== m[1]) return null;
  return m;
}

/**
 * True if cmd is one `git pull --ff-only` or `git merge --ff-only` invocation.
 * Allows the merge step from the main worktree — the one operation main is
 * reserved for. `--no-ff` overrides the ff-only intent and is rejected.
 */
function isAllowedFastForwardMerge(cmd, repoRoot) {
  const git = singleGitInvocation(cmd);
  if (!git || (git.sub !== "pull" && git.sub !== "merge")) return false;
  // A -C must name the repository the hook judged; a repeated or foreign -C acts elsewhere.
  if (!gitCDirIsRepo(git.cDirs, repoRoot)) return false;
  if (git.rest.includes("--no-ff")) return false;
  return git.rest.includes("--ff-only");
}

// Named exception (#1421): the only NAME=value prefix the probe may carry. Any other
// name (BASH_ENV, ENV, PATH, SHELLOPTS, IFS, ...) can change how bash starts or
// resolves the body's commands, so it is rejected.
const CONFIG_CHECK_PREFIX_NAMES = new Set(["CONV_LANG"]);
const CONFIG_CHECK_PREFIX_VALUE_RE = /^[A-Za-z0-9_.-]*$/;

/**
 * True if cmd is one `bash -c '<body>'` invocation whose body is exactly the
 * legacy read-only CONFIRM_* probe used by planning skills:
 *   bash -c 'cd "$AGENTS_MAIN_ROOT" && bash "$AGENTS_MAIN_ROOT/bin/confirm-off" KEY [on|off]'
 * The body's && is control flow, so safety comes from the clause matching below.
 * Kept for compatibility: skills now issue the standalone confirm-off form,
 * which needs no exemption. See docs/architecture/claude-code/workflow-runtime.md.
 */
function isAllowedReadOnlyConfigCheck(cmd) {
  const seg = singleInvocation(cmd);
  if (!seg || seg.redirects.length !== 0) return false;
  const split = leadingAssignments(seg);
  if (!split) return false;
  const prefixOk = split.assignments.every((a) =>
    CONFIG_CHECK_PREFIX_NAMES.has(a.name) && CONFIG_CHECK_PREFIX_VALUE_RE.test(a.value) && a.raw === `${a.name}=${a.value}`);
  if (!prefixOk) return false;
  const s = split.seg;
  if (s.cmd0 !== "bash" || s.cmd0Raw !== "bash" || s.argv.length !== 2 || s.argv[0] !== "-c") return false;
  const body = s.argv[1];
  if (body.includes("`")) return false;
  if (body.includes("$(")) return false;
  if (body.includes(">") || body.includes("<")) return false;
  if (body.includes(";")) return false;
  if (body.replace(/\|\|/g, "").includes("|")) return false;
  const clauses = body.split(/\s*&&\s*/);
  if (clauses.length !== 2) return false;
  const [c1, c2] = clauses;
  if (!/^cd\s+(?:"?\$AGENTS_MAIN_ROOT"?)\s*$/.test(c1.trim())) return false;
  if (!/^bash\s+"?\$AGENTS_MAIN_ROOT\/bin\/confirm-off"?\s+[A-Z][A-Z0-9_]*(?:\s+(?:on|off))?\s*$/.test(c2.trim())) return false;
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
    const git = singleGitInvocation(cmd);
    if (!git || git.sub !== "push" || !gitCDirIsRepo(git.cDirs, repoRoot)) return false;

    const KNOWN_FLAGS = new Set([
      "-q", "--quiet", "-v", "--verbose",
      "--porcelain", "-n", "--dry-run", "--atomic",
    ]);
    const UPSTREAM_FLAGS = new Set(["-u", "--set-upstream"]);
    const positionals = [];
    let sawUpstreamFlag = false;
    for (const t of git.rest) {
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
      if (!/^[A-Za-z0-9._/-]+$/.test(branch)) return false;
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

const MID_OP_SUBCOMMANDS = new Set(["merge", "rebase", "cherry-pick", "revert"]);
const MID_OP_ACTIONS = new Set(["--abort", "--continue", "--skip"]);

/**
 * True when cmd is one `git [merge|rebase|cherry-pick|revert] (--abort|--continue|--skip)`
 * invocation. Mid-operation actions only mutate in-progress state files
 * (.git/MERGE_HEAD, rebase-merge/, sequencer/) — never tracked files in linked
 * worktrees — so no linked-worktree-count gate. A -C must resolve to repoRoot.
 */
function isAllowedMidOperationAbort(cmd, repoRoot) {
  if (!repoRoot) return false;
  const git = singleGitInvocation(cmd);
  if (!git || !MID_OP_SUBCOMMANDS.has(git.sub) || !gitCDirIsRepo(git.cDirs, repoRoot)) return false;
  return MID_OP_ACTIONS.has(git.rest[0] || "");
}

/**
 * True when cmd is an approved cleanup-class git command (#297):
 *   git [-C <repoRoot>] stash (push|pop|apply|drop|clear) [...]
 *   git [-C <repoRoot>] restore [--staged] <paths>   — no --source
 *   git [-C <repoRoot>] checkout [HEAD] -- <paths>   — `--` required
 *   git [-C <repoRoot>] merge --no-edit origin/<upstream-branch>  — #1982
 * The only accepted prefix is WORKTREE_END_SKILL=1; a -C must resolve to repoRoot.
 * Per-subcommand rules are documented at their sites.
 */
function isAllowedMainWorktreeCleanup(cmd, repoRoot) {
  if (!repoRoot) return false;
  // merge (below) invokes the configured editor, so RCE-capable git flags
  // (-c, --upload-pack, --receive-pack) are rejected for the whole class.
  if (rejectRceGitFlags(cmd)) return false;
  const seg = singleInvocation(cmd);
  if (!seg || !redirectsUnderTmp(seg)) return false;
  const split = withoutWorktreeEndSkillPrefix(seg);
  if (!split) return false;
  const { skillPrefixed } = split;
  const git = gitSubcommand(split.seg);
  if (!git || !gitCDirIsRepo(git.cDirs, repoRoot)) return false;
  const { sub, rest } = git;

  if (sub === "stash") {
    const firstToken = rest[0] || "";
    const ALLOWED_STASH = new Set(["", "push", "pop", "apply", "drop", "clear"]);
    // A leading `-` flag is a push modifier (e.g. `git stash -u`) — allowed.
    if (!ALLOWED_STASH.has(firstToken) && !firstToken.startsWith("-")) return false;
  } else if (sub === "restore") {
    if (rest.some((t) => t === "--source" || t.startsWith("--source="))) return false;
  } else if (sub === "merge") {
    // Sanctioned divergence-recovery merge (#1982): git merge --no-edit
    // origin/<branch>. --no-edit is mandatory: diverged merges open the
    // configured editor by default; requiring it prevents a hang in
    // non-interactive calls and closes the editor RCE path. Only -C may sit
    // before the subcommand; the git head already excludes env/launcher prefixes.
    if (git.globalCount !== git.cDirs.length * 2) return false;
    // Strict form: --no-edit then exactly one origin/<branch> refspec. Rejects
    // extra flags, --ff-only (ff predicate territory), --abort/--continue/--skip
    // (isAllowedMidOperationAbort territory), colon refspecs, `+`, refs/ form.
    const m = rest.length === 2 && rest[0] === "--no-edit" ? rest[1].match(/^origin\/([A-Za-z0-9._/-]+)$/) : null;
    if (!m) return false;
    // C1: operand must match the current branch's upstream on origin (fail-closed).
    const upstream = resolveUpstream(repoRoot, "origin");
    if (!upstream || upstream !== ("origin/" + m[1])) return false;
    // No linked-worktree count gate: merge is symmetric with the ff-only
    // pull/merge predicate, which also bypasses it. Git refuses to overwrite
    // files checked out in a linked worktree during a merge.
    return true;
  } else if (sub === "checkout") {
    // Path-restore form: requires `--` separator before the file paths.
    const sep = rest.indexOf("--");
    if (sep < 0) return false;
    // Allow only no-token-before-`--` (→ `git checkout -- <paths>`) or
    // exactly `HEAD` before `--` (→ `git checkout HEAD -- <paths>`).
    if (sep > 1 || (sep === 1 && rest[0] !== "HEAD")) return false;
  } else {
    return false; // only stash/restore/merge/checkout are cleanup-class
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
 *   bash "<script checkout root>/bin/compose-doc-append-entry" [--flag value]...
 * Rejects anything but one invocation, redirects, wrong interpreter/script
 * path, unresolvable checkout root. Consumer: the WE-17 manual recovery path in
 * skills/worktree-end/scripts/cleanup-cascade.md — if that command's shape
 * changes, update this matcher.
 */
function isAllowedComposeDocAppend(cmd, repoRoot) {
  // Marker-validated checkout of this hook (#1630) — env-independent; null stays fail-closed.
  const SCRIPT_CHECKOUT_ROOT = resolveScriptCheckoutRoot();
  if (!SCRIPT_CHECKOUT_ROOT) return false;

  // Structural opening: `bash "<path>"` double-quoted only (matches worker spec literal).
  const m = bashQuotedScript(cmd);
  if (!m) return false;
  const scriptPath = m[1];
  const argTail    = m[2] || "";

  // Resolve both sides case-insensitively (Windows filesystem).
  let normScript, normTarget;
  try {
    const expectedTarget = path.join(SCRIPT_CHECKOUT_ROOT, "bin", "compose-doc-append-entry");
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
 * True when cmd is the canonical clarify-guard-loop invocation:
 *   bash "<script checkout root>/bin/github-issues/clarify-guard-loop.sh" [args...]
 * (double-quoted script path only). Rejects: anything but one invocation,
 * redirects, single-quoted path, wrong interpreter, wrong script path.
 * The guard script writes the GUARD_ATTEMPT counter internally (no redirect visible
 * to the hook), so collectBashWriteTargets returns 0 targets → allow.
 */
function isAllowedClarifyGuardLoop(cmd, repoRoot) {
  // Marker-validated checkout of this hook (#1630) — env-independent; null stays fail-closed.
  const SCRIPT_CHECKOUT_ROOT = resolveScriptCheckoutRoot();
  if (!SCRIPT_CHECKOUT_ROOT) return false;

  const m = bashQuotedScript(cmd);
  if (!m) return false;
  const scriptPath = m[1];
  const argTail    = m[2] || "";

  // Identity: script path must match <script checkout root>/bin/github-issues/clarify-guard-loop.sh
  let normScript, normTarget;
  try {
    const expectedTarget = path.join(SCRIPT_CHECKOUT_ROOT, "bin", "github-issues", "clarify-guard-loop.sh");
    normScript = path.resolve(normalizeCwd(scriptPath) || scriptPath);
    normTarget = path.resolve(normalizeCwd(expectedTarget) || expectedTarget);
  } catch (e) { return false; }
  if (normScript.toLowerCase() !== normTarget.toLowerCase()) return false;

  // Span-aware argTail scan — same `sanctioned-bin` profile as isAllowedComposeDocAppend (CPR-ORTH).
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
  const seg = singleInvocation(cmd);
  if (!seg || !redirectsUnderTmp(seg)) return false;
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
  describeVariableScriptPath,
  isAllowedSupervisorBinTool,
  isAllowedClarifyGuardLoop,
  isAllowedReadOnlyWorkflowCli,
};
