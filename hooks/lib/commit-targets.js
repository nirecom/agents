"use strict";
// hooks/lib/commit-targets.js — per-commit target enumeration for a command list
// (one entry per Bash command or runCommands element). Each `git commit` found in
// any element, logical line, or POSIX `-c` inline body yields
// { target: explicit(dir) | default | ambiguous(reason), commitText }.
// Pure: no filesystem or git access. Anything the text cannot pin down is
// ambiguous, so callers that relax a gate on a target stay fail-closed.

const { parse } = require("./command-ir");
const { isCommitCommand, isCommitArgv, quoteIfNeeded } = require("./commit-detect");
const { resolveGitArgvForSegment, isGitBasename } = require("./bash-write-patterns/git-write-ir");
const {
  scanWrappedVerb,
  resolveEffectiveCommand,
  resolveEffectiveArgv,
  commandBasename,
} = require("./bash-write-patterns/segment-utils");
const {
  logicalLines,
  isInlineBodyFlag,
  attachedBodyOf,
  skipShellOptions,
  POSIX_SHELLS,
  PWSH_SHELLS,
  MAX_DEPTH,
  MAX_BODIES,
  MAX_TOTAL_BYTES,
} = require("./interpreter-inline-body");
const { FLAGS_WITH_ARG, parseGitConfigValues } = require("./parse-git-args");
const { scanHeredocs } = require("./command-ir/heredoc");

const FLOW_SEPS = new Set(["&&", ";"]);
const BREAK_SEPS = new Set(["||", "|", "|&", "&"]);
const CD_VERBS = new Set(["cd", "pushd", "popd"]);
// Before a cd: these make it skippable or subshell-bound; these start a new chain.
const CONDITIONAL_SEPS = new Set(["&&", "||", "|", "|&"]);
const CHAIN_RESET_SEPS = new Set([";", "&"]);
const ENV_DECLARE_VERBS = new Set(["export", "declare", "typeset", "readonly", "local"]);
const SHELL_ASSIGN_RE = /^[A-Za-z_]\w*=/;
const GIT_REPO_ENV_ASSIGN_RE = /^GIT_(DIR|WORK_TREE|INDEX_FILE|OBJECT_DIRECTORY|COMMON_DIR)=/;
const GIT_ENV_NAME_RE = /^GIT_\w*(=|$)/;
const COMPOUND_WORDS = new Set([
  "if", "then", "elif", "else", "fi", "for", "while", "until", "do", "done",
  "case", "esac", "select", "function", "[[", "]]", "{", "}", "coproc",
]);
const GIT_ENV_REDIRECT_RE = /^GIT_(DIR|WORK_TREE|OBJECT_DIRECTORY|COMMON_DIR)=/;
const COMMIT_LIKE_RE = /\bgit\b[\s\S]*\scommit(?![\w-])/;
// Verbs that only print their arguments, never run them (named exception to the
// unenumerated-commit rule).
const DATA_ONLY_VERBS = new Set(["echo", "printf"]);

const defaultTarget = () => ({ kind: "default" });
const explicitTarget = (dir) => ({ kind: "explicit", dir });
const ambiguousTarget = (reason) => ({ kind: "ambiguous", reason });

function literalAbsoluteDir(value) {
  if (typeof value !== "string" || value.length === 0) return null;
  if (/[$`]/.test(value) || value.startsWith("~")) return null;
  if (value.startsWith("/") || /^[A-Za-z]:[\\/]/.test(value)) return value;
  return null;
}

function commitTextOf(gitArgv) {
  return "git " + gitArgv.map(quoteIfNeeded).join(" ");
}

function targetOfCommit(seg, gitArgv, cwd) {
  const tokens = [seg.cmd0].concat(seg.argv);
  const prefix = tokens.slice(0, tokens.length - gitArgv.length);
  if (prefix.some((t) => typeof t === "string" && GIT_ENV_REDIRECT_RE.test(t))) {
    return ambiguousTarget("git-env-redirect");
  }
  const cValues = [];
  let i = 0;
  while (i < gitArgv.length) {
    const tok = gitArgv[i];
    if (typeof tok !== "string" || tok[0] !== "-") break;
    if (tok.startsWith("-C") && tok !== "-C") return ambiguousTarget("attached-C");
    const eq = tok.indexOf("=");
    const key = eq === -1 ? tok : tok.slice(0, eq);
    if (key === "--git-dir" || key === "--work-tree") return ambiguousTarget("git-dir-flag");
    if (key === "-C") cValues.push(eq === -1 ? gitArgv[i + 1] : tok.slice(eq + 1));
    i += eq === -1 && FLAGS_WITH_ARG.has(key) ? 2 : 1;
  }
  if (cValues.length > 1) return ambiguousTarget("multiple-dash-c");
  if (cValues.length === 1) {
    const dir = literalAbsoluteDir(cValues[0]);
    return dir ? explicitTarget(dir) : ambiguousTarget("dash-c-not-literal-absolute");
  }
  return Object.assign({}, cwd);
}

function cdTransition(seg, structural) {
  const verb = commandBasename(resolveEffectiveCommand(seg));
  if (verb !== "cd") return ambiguousTarget(verb);
  if (structural) return ambiguousTarget("cd-in-group");
  const args = Array.isArray(seg.argv) ? seg.argv : [];
  const dir = args.length === 1 ? literalAbsoluteDir(args[0]) : null;
  return dir ? explicitTarget(dir) : ambiguousTarget("cd-not-literal-absolute");
}

function posixInlineBody(seg) {
  const base = commandBasename(resolveEffectiveCommand(seg));
  if (!POSIX_SHELLS.has(base)) return null;
  const argv = resolveEffectiveArgv(seg);
  const j = argv.findIndex((a) => isInlineBodyFlag(a, base));
  if (j === -1) return null;
  const attached = attachedBodyOf(argv[j]);
  if (attached !== null) return attached;
  const k = skipShellOptions(argv, j + 1);
  return k < argv.length && typeof argv[k] === "string" ? argv[k] : null;
}

// eval and PowerShell bodies are not walked (POSIX `-c` bodies are), so any
// commit-like text in them is a commit whose target cannot be proven.
function isOpaqueCommitWrapper(seg) {
  const base = commandBasename(resolveEffectiveCommand(seg));
  if (base !== "eval" && !PWSH_SHELLS.has(base) && !POSIX_SHELLS.has(base)) return false;
  const argv = resolveEffectiveArgv(seg).filter((a) => typeof a === "string");
  return COMMIT_LIKE_RE.test(argv.join(" "));
}

function segmentTokens(seg) {
  return [seg.cmd0].concat(Array.isArray(seg.argv) ? seg.argv : []).filter((t) => typeof t === "string");
}

// A statement (not a command prefix) that leaves GIT_DIR & co. set for later commands.
function setsGitEnv(seg) {
  const tokens = segmentTokens(seg);
  if (ENV_DECLARE_VERBS.has(seg.cmd0)) return tokens.slice(1).some((t) => GIT_ENV_NAME_RE.test(t));
  return tokens.length > 0 && tokens.every((t) => SHELL_ASSIGN_RE.test(t))
    && tokens.some((t) => GIT_REPO_ENV_ASSIGN_RE.test(t));
}

// Bodies of $(...) and backticks, nested ones included; single quotes suppress them.
function substitutionBodies(text) {
  const out = [];
  let inSingle = false;
  let inDouble = false;
  for (let i = 0; i < text.length; i += 1) {
    const c = text[i];
    if (inSingle) { if (c === "'") inSingle = false; continue; }
    if (c === "\\") { i += 1; continue; }
    if (c === "'" && !inDouble) { inSingle = true; continue; }
    if (c === '"') { inDouble = !inDouble; continue; }
    let start = -1;
    let end = -1;
    if (c === "$" && text[i + 1] === "(") {
      start = i + 2;
      let depth = 1;
      for (end = start; end < text.length && depth > 0; end += 1) {
        if (text[end] === "(") depth += 1;
        else if (text[end] === ")") depth -= 1;
      }
      end = depth === 0 ? end - 1 : text.length;
    } else if (c === "`") {
      start = i + 1;
      end = text.indexOf("`", start);
      if (end === -1) end = text.length;
    }
    if (start === -1) continue;
    const body = text.slice(start, end);
    out.push(body, ...substitutionBodies(body));
    i = end;
  }
  return out;
}

// An unquoted `(` that does not open `$(`: a subshell, a `name()` definition, or a
// process substitution.
function hasBareOpenParen(text) {
  let inSingle = false;
  let inDouble = false;
  for (let i = 0; i < text.length; i += 1) {
    const c = text[i];
    if (inSingle) { if (c === "'") inSingle = false; continue; }
    if (c === "\\") { i += 1; continue; }
    if (c === "'" && !inDouble) { inSingle = true; continue; }
    if (c === '"') { inDouble = !inDouble; continue; }
    if (inDouble || c !== "(") continue;
    if (text[i - 1] !== "$") return true;
    while (text[i + 1] === "(") i += 1;
  }
  return false;
}

// Compound commands are not modelled at all: their commits cannot be enumerated
// reliably, so the line is gated as a whole instead (allowlist, not patching).
function hasCompoundSyntax(ir, text) {
  if ((ir.segments || []).some((seg) => COMPOUND_WORDS.has(seg.cmd0))) return true;
  return hasBareOpenParen(scanHeredocs(text).lexText);
}

function hasSubstitutedCommit(text) {
  return substitutionBodies(text).some((b) => COMMIT_LIKE_RE.test(scanHeredocs(b).lexText));
}

function segmentText(seg) {
  return typeof seg.rawText === "string" ? seg.rawText : segmentTokens(seg).join(" ");
}

// Any launcher not modelled below (xargs, find -exec, env, sudo, ...) can still run a
// commit, so a commit-like segment that yielded no entry is gated, not trusted.
function visitSegment(seg, ctx, env) {
  const gitArgv = resolveGitArgvForSegment(seg);
  if (gitArgv !== null) {
    if (isCommitArgv(gitArgv)) {
      const target = ctx.gitEnv ? ambiguousTarget("exported-git-env") : targetOfCommit(seg, gitArgv, ctx.cwd);
      env.out.push({ target, commitText: commitTextOf(gitArgv) });
    }
    return;
  }
  const before = env.out.length;
  visitNonGitSegment(seg, ctx, env);
  if (env.out.length === before && !DATA_ONLY_VERBS.has(seg.cmd0) && COMMIT_LIKE_RE.test(segmentText(seg))) {
    env.out.push({ target: ambiguousTarget("unenumerated-commit"), commitText: null });
  }
}

function visitNonGitSegment(seg, ctx, env) {
  let hidden = null;
  scanWrappedVerb(seg, (tok, rest) => {
    if (hidden === null && isGitBasename(tok) && isCommitArgv(rest)) hidden = rest;
    return hidden !== null;
  });
  if (hidden !== null) {
    env.out.push({ target: ambiguousTarget("wrapper"), commitText: commitTextOf(hidden) });
    return;
  }
  const body = posixInlineBody(seg);
  if (body === null) {
    if (isOpaqueCommitWrapper(seg)) env.out.push({ target: ambiguousTarget("wrapped-commit"), commitText: null });
    return;
  }
  env.bodies += 1;
  env.bytes += body.length;
  if (env.depth >= MAX_DEPTH || env.bodies > MAX_BODIES || env.bytes > MAX_TOTAL_BYTES) {
    if (COMMIT_LIKE_RE.test(body)) env.out.push({ target: ambiguousTarget("inline-body-limit"), commitText: null });
    return;
  }
  // A child shell's cd never reaches the parent, so the body walks a copy.
  env.depth += 1;
  const gitEnv = ctx.gitEnv || segmentTokens(seg).some((t) => GIT_REPO_ENV_ASSIGN_RE.test(t));
  walkText(body, { cwd: Object.assign({}, ctx.cwd), sawCd: false, gitEnv }, env);
  env.depth -= 1;
}

function walkParsedLine(ir, ctx, env) {
  const seps = Array.isArray(ir.separators) ? ir.separators : [];
  const structural = seps.some((s) => !FLOW_SEPS.has(s) && !BREAK_SEPS.has(s));
  let lineCd = false;
  let conditional = false;
  (ir.segments || []).forEach((seg, i) => {
    if (i > 0 && lineCd && BREAK_SEPS.has(seps[i - 1])) ctx.cwd = ambiguousTarget("conditional-cd");
    if (i > 0 && CHAIN_RESET_SEPS.has(seps[i - 1])) conditional = false;
    else if (i > 0 && CONDITIONAL_SEPS.has(seps[i - 1])) conditional = true;
    if (setsGitEnv(seg)) {
      ctx.gitEnv = true;
      return;
    }
    if (CD_VERBS.has(commandBasename(resolveEffectiveCommand(seg)))) {
      ctx.cwd = conditional ? ambiguousTarget("conditional-cd") : cdTransition(seg, structural);
      ctx.sawCd = true;
      lineCd = true;
      return;
    }
    visitSegment(seg, ctx, env);
  });
}

// The line split can cut inside a quoted span (`-m "$(cat <<'EOF' ... )"`), so a
// line that fails to parse absorbs the following lines until it parses. The parser
// reads a newline inside such a span as plain whitespace, so a joined span keeps only
// explicit -C targets and turns a commit it cannot see into ambiguous (fail-closed).
function walkJoinedSpan(ir, span, ctx, env) {
  const before = env.out.length;
  walkParsedLine(ir, ctx, env);
  for (let i = before; i < env.out.length; i += 1) {
    if (env.out[i].target.kind !== "explicit") env.out[i].target = ambiguousTarget("multi-line-span");
  }
  if (env.out.length === before && COMMIT_LIKE_RE.test(span)) {
    env.out.push({ target: ambiguousTarget("multi-line-span"), commitText: null });
  }
}

// A cd or GIT_* export inside the compound may or may not run, so the modelled
// state after it is unknown too.
function walkCompoundLine(span, ctx, env) {
  if (COMMIT_LIKE_RE.test(span)) env.out.push({ target: ambiguousTarget("compound-shell"), commitText: null });
  ctx.cwd = ambiguousTarget("compound-shell");
  ctx.sawCd = true;
  if (/\bGIT_\w/.test(span)) ctx.gitEnv = true;
}

function walkText(text, ctx, env) {
  let pending = null;
  for (const line of logicalLines(text)) {
    const span = pending === null ? line : pending + "\n" + line;
    const ir = parse(span);
    if (ir.parseFailure === true) {
      pending = span;
      continue;
    }
    pending = null;
    if (hasCompoundSyntax(ir, span)) {
      walkCompoundLine(span, ctx, env);
      continue;
    }
    if (span === line) walkParsedLine(ir, ctx, env);
    else walkJoinedSpan(ir, span, ctx, env);
    if (hasSubstitutedCommit(span)) {
      env.out.push({ target: ambiguousTarget("substituted-commit"), commitText: null });
    }
  }
  if (pending !== null && (isCommitCommand(parse(pending)) || COMMIT_LIKE_RE.test(pending))) {
    env.out.push({ target: ambiguousTarget("parse-failure"), commitText: null });
  }
}

// Elements of a runCommands array may or may not share one shell, so a cd or a
// GIT_* export in an earlier element leaves later commits unprovable.
function enumerateCommitTargets(commandList) {
  const env = { out: [], depth: 0, bodies: 0, bytes: 0 };
  let priorElementCd = false;
  let priorElementGitEnv = false;
  for (const element of Array.isArray(commandList) ? commandList : []) {
    if (typeof element !== "string" || element.trim() === "") continue;
    const ctx = {
      cwd: priorElementCd ? ambiguousTarget("cross-element-cd") : defaultTarget(),
      sawCd: false,
      gitEnv: priorElementGitEnv,
    };
    walkText(element, ctx, env);
    if (ctx.sawCd) priorElementCd = true;
    if (ctx.gitEnv) priorElementGitEnv = true;
  }
  return env.out;
}

function isWipCommitText(text) {
  if (typeof text !== "string") return false;
  return parseGitConfigValues(text, "workflow.wip").some((v) => v === "1" || v.toLowerCase() === "true");
}

function allCommitsAreWip(commitTargets) {
  if (!Array.isArray(commitTargets) || commitTargets.length === 0) return false;
  return commitTargets.every((t) => t && isWipCommitText(t.commitText));
}

module.exports = { enumerateCommitTargets, isWipCommitText, allCommitsAreWip };
