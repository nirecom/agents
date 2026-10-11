"use strict";
// hooks/enforce-worktree/main-worktree-allows/command-shape.js
// Shape helpers shared by the main-worktree allow predicates (#2589). Every
// predicate reads its command through command-ir once and judges the single
// segment it gets back, so no regex can match a command that sits behind a
// separator, inside a substitution, or after a non-leading head.
// cdTailInvocation is the one named exception (#982, worktree-command.js only).

const path = require("path");
const { parse, analysisOf } = require("../../lib/command-ir");
const { ASSIGN_RE } = require("../../lib/command-ir/effective");
const { syncRaw } = require("../../lib/command-ir/segments");
const { stripQuotedArgs } = require("../../lib/strip-quoted-args");
const { normalizeCwd } = require("../../lib/path-normalize");

function parseWithoutNesting(cmd) {
  if (!cmd || typeof cmd !== "string") return null;
  let ir;
  try { ir = parse(cmd); } catch (_) { return null; }
  if (!ir || ir.parseFailure === true || !Array.isArray(ir.segments)) return null;
  const a = analysisOf(ir);
  if (a.heredocs.length > 0 || a.substitutions.length > 0 || a.groups.length > 0) return null;
  if (/[<>]\(/.test(stripQuotedArgs(cmd))) return null;
  if (ir.segments.some((s) => !s || s.sub === true || !s.cmd0)) return null;
  return ir;
}

/** The one segment of a command that is exactly one invocation, else null. */
function singleInvocation(cmd) {
  const ir = parseWithoutNesting(cmd);
  if (!ir || ir.separators.length !== 0 || ir.segments.length !== 1) return null;
  return ir.segments[0];
}

/**
 * `<invocation> && cd <literal path>` -> the first segment, else null.
 * Named exception for the worktree-start shape (#982); no other predicate uses it.
 */
function cdTailInvocation(cmd) {
  const ir = parseWithoutNesting(cmd);
  if (!ir || ir.separators.length !== 1 || ir.separators[0] !== "&&") return null;
  if (ir.segments.length !== 2) return null;
  const tail = ir.segments[1];
  if (tail.cmd0 !== "cd" || tail.cmd0Raw !== "cd") return null;
  if (tail.argv.length !== 1 || tail.redirects.length !== 0) return null;
  const rawPath = (tail.argvRaw && tail.argvRaw[0]) || "";
  if (!tail.argv[0] || /[$`]/.test(tail.argv[0]) || /[$`]/.test(rawPath)) return null;
  return ir.segments[0];
}

/**
 * Splits the leading NAME=value words off a segment. Returns
 * { assignments: [{name, value, raw}], seg } or null when no command follows.
 */
function leadingAssignments(seg) {
  if (!seg || typeof seg.cmd0 !== "string" || !Array.isArray(seg.argv)) return null;
  const words = [seg.cmd0, ...seg.argv];
  const raws = [seg.cmd0Raw, ...(Array.isArray(seg.argvRaw) ? seg.argvRaw : seg.argv)];
  let n = 0;
  while (n < words.length && ASSIGN_RE.test(words[n]) && ASSIGN_RE.test(String(raws[n] || ""))) n++;
  if (n === words.length) return null;
  const assignments = words.slice(0, n).map((w, i) => {
    const eq = w.indexOf("=");
    return { name: w.slice(0, eq), value: w.slice(eq + 1), raw: raws[i] };
  });
  if (n === 0) return { assignments, seg };
  return { assignments, seg: { ...seg, cmd0: seg.argv[n - 1], argv: seg.argv.slice(n), ...syncRaw(seg, n) } };
}

/**
 * The segment without the one sanctioned skill prefix `WORKTREE_END_SKILL=1`:
 * { seg, skillPrefixed }. null for any other leading assignment.
 */
function withoutWorktreeEndSkillPrefix(seg) {
  const split = leadingAssignments(seg);
  if (!split || split.assignments.length > 1) return null;
  if (split.assignments.length === 0) return { seg: split.seg, skillPrefixed: false };
  if (split.assignments[0].raw !== "WORKTREE_END_SKILL=1") return null;
  return { seg: split.seg, skillPrefixed: true };
}

const GIT_VALUE_OPTS = new Set(["-C", "--namespace", "--super-prefix"]);
// RCE-capable options, plus the ones that retarget the repository or working tree: the allow
// predicates validate only -C, so --git-dir/--work-tree would run the command elsewhere.
const GIT_RCE_OPTS = /^(?:-c|--config-env|--upload-pack|--receive-pack|--exec-path|--git-dir|--work-tree)(?:=|$)/;

/**
 * For a `git` segment: { sub, index, rest, cDirs, globalCount } where `rest` is the
 * argv after the subcommand. null for a non-git head (an assignment included), an
 * RCE-capable global option, or a missing subcommand.
 */
function gitSubcommand(seg) {
  if (!seg || seg.cmd0 !== "git" || seg.cmd0Raw !== "git" || !Array.isArray(seg.argv)) return null;
  const cDirs = [];
  let i = 0;
  while (i < seg.argv.length && seg.argv[i].startsWith("-")) {
    const tok = seg.argv[i];
    if (GIT_RCE_OPTS.test(tok)) return null;
    // Attached `-C<path>` would select a repository without reaching cDirs.
    if (tok.startsWith("-C") && tok !== "-C") return null;
    if (GIT_VALUE_OPTS.has(tok)) {
      if (i + 1 >= seg.argv.length) return null;
      if (tok === "-C") cDirs.push(seg.argv[i + 1]);
      i += 2;
      continue;
    }
    i += 1;
  }
  if (i >= seg.argv.length) return null;
  return { sub: seg.argv[i], index: i, rest: seg.argv.slice(i + 1), cDirs, globalCount: i };
}

// Case is folded only where the filesystem folds it: on a case-sensitive one,
// /path/Repo and /path/repo are different directories.
const CASE_INSENSITIVE_FS = process.platform === "win32" || process.platform === "darwin";

/** True when no `-C` was given, or exactly one that resolves to repoRoot. */
function gitCDirIsRepo(cDirs, repoRoot, foldCase = CASE_INSENSITIVE_FS) {
  if (!Array.isArray(cDirs) || cDirs.length === 0) return true;
  if (cDirs.length > 1 || !repoRoot) return false;
  try {
    const normC = path.resolve(normalizeCwd(cDirs[0]) || cDirs[0]);
    const normBase = path.resolve(normalizeCwd(repoRoot) || repoRoot);
    return foldCase ? normC.toLowerCase() === normBase.toLowerCase() : normC === normBase;
  } catch (_) { return false; }
}

const FD_DUP_OP = /^\d?>$/;
const FD_DUP_TARGET = /^&[12]$/;
const TMP_FILE_OPS = new Set([">", ">>", "1>", "1>>", "2>", "2>>", "&>", "&>>", ">&"]);
const NON_LITERAL = /[$`*?[~]|\.\./;

function isLiteralTmpPath(p) {
  return typeof p === "string" && p.startsWith("/tmp/") && !NON_LITERAL.test(p);
}

/** True when every redirect is an &1/&2 fd duplication or a literal /tmp/ file write. */
function redirectsUnderTmp(seg) {
  if (!seg || !Array.isArray(seg.redirects)) return false;
  return seg.redirects.every((r) => {
    if (FD_DUP_OP.test(r.op) && FD_DUP_TARGET.test(r.target)) return true;
    if (!TMP_FILE_OPS.has(r.op)) return false;
    const raw = typeof r.targetRaw === "string" ? r.targetRaw.replace(/["']/g, "") : "";
    return isLiteralTmpPath(r.target) && isLiteralTmpPath(raw);
  });
}

module.exports = {
  singleInvocation,
  cdTailInvocation,
  leadingAssignments,
  withoutWorktreeEndSkillPrefix,
  gitSubcommand,
  gitCDirIsRepo,
  redirectsUnderTmp,
  CASE_INSENSITIVE_FS,
};
