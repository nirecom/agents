// hooks/enforce-worktree/effective-target/inputs.js
// #3147: collect, per git write segment, every input that moves the write away from the
// cwd repo (--git-dir / --work-tree / -c core.worktree / --config-env / GIT_DIR /
// GIT_WORK_TREE, inline or inherited). No git is run here.

"use strict";

const path = require("path");
const { resolveGitArgvForSegment, isGitWriteArgv, resolveGitSubArgv } = require("../../lib/bash-write-patterns/git-write-ir");
const { extractGitScopeFlagsFromArgv } = require("../../lib/parse-git-args");
const { toWindowsPath } = require("../../lib/branch-diff");
const { resolveScopeValue, AMBIGUOUS_SCOPE } = require("../git-repo-detection");
const { homeDiverges, hasWriteRedirect, C_CONFINED_WRITE_SUBCOMMANDS } = require("../git-c-write-scope");

const ENV_KEYS = ["GIT_DIR", "GIT_WORK_TREE"];
const NAMES_TARGET_ENV_RE = /(^|=)(GIT_DIR|GIT_WORK_TREE)(=|$)/;
const TARGET_ASSIGN_RE = /^(GIT_DIR|GIT_WORK_TREE)=([\s\S]*)$/;
const ASSIGN_RE = /^([A-Za-z_][A-Za-z0-9_]*)=([\s\S]*)$/;
const SETTER_CMDS = new Set(["export", "declare", "typeset", "local", "readonly", "unset", "env"]);
// Builtins that run or define another command: any mention of the target variables inside them can set them.
const INDIRECT_CMDS = new Set(["command", "builtin", "eval", "source", ".", "printf", "read"]);
const MENTIONS_TARGET_ENV_RE = /GIT_(DIR|WORK_TREE|CONFIG)/;
// Config the probe does not replay: any of these can carry core.worktree into the real write.
const CONFIG_ENV_RE = /^GIT_CONFIG_(COUNT|PARAMETERS|GLOBAL|SYSTEM|KEY_\d+|VALUE_\d+)$/;
const CWD_CMDS = new Set(["cd", "pushd", "popd", "chdir", "set-location", "push-location", "sl"]);
const PARSE_FAILURE_KEYWORDS_RE =/--git-dir|--work-tree|core\.worktree|--config-env|GIT_DIR|GIT_WORK_TREE/i;

const NONE = { segments: [], anyOverride: false, coversAllWrites: false };

function failed(reason, inherited) {
  return { segments: [{ unresolvable: reason, inherited }], anyOverride: true, coversAllWrites: false };
}

// Relative values stay relative: git resolves them itself (against the cwd, or the git dir
// for core.worktree). Only a value the shell would still expand is unresolvable.
function literalValue(raw) {
  if (typeof raw !== "string" || raw === "") return { reason: "an empty value" };
  if (/[$`]/.test(raw)) return { reason: `${raw} needs shell expansion` };
  if (raw.startsWith("~")) {
    if (!/^~(?:[\\/]|$)/.test(raw)) return { reason: `${raw} names another user's home` };
    if (homeDiverges()) return { reason: "HOME differs from the user profile, so ~ is ambiguous" };
  }
  const abs = resolveScopeValue(raw);
  return { value: abs === AMBIGUOUS_SCOPE ? raw : abs };
}

// A segment other than the git write that sets or unsets GIT_DIR / GIT_WORK_TREE for later segments.
function setsTargetEnv(seg) {
  const cmd0 = typeof seg.cmd0 === "string" ? seg.cmd0 : "";
  if (INDIRECT_CMDS.has(cmd0.toLowerCase())) {
    return [cmd0, ...(seg.argv || [])].some((t) => typeof t === "string" && MENTIONS_TARGET_ENV_RE.test(t));
  }
  if (!ASSIGN_RE.test(cmd0) && !SETTER_CMDS.has(cmd0)) return false;
  return [cmd0, ...(seg.argv || [])].some((t) => typeof t === "string" && NAMES_TARGET_ENV_RE.test(t));
}

// A segment that moves the cwd (cd / pushd / env -C / env --chdir): relative inputs of a later
// git write then resolve against a directory the tool cwd does not show.
function changesCwd(seg) {
  let cmd0 = typeof seg.cmd0 === "string" ? seg.cmd0.toLowerCase() : "";
  if ((cmd0 === "command" || cmd0 === "builtin") && typeof (seg.argv || [])[0] === "string") cmd0 = seg.argv[0].toLowerCase();
  if (CWD_CMDS.has(cmd0)) return true;
  if (cmd0 !== "env") return false;
  return (seg.argv || []).some((t) => typeof t === "string" && /^(-C|--chdir)(=|$)|^-C./.test(t));
}

function segmentInputs(seg, argv, confined, toolCwd, env) {
  const toks = [seg.cmd0, ...(seg.argv || [])];
  const prefix = toks.slice(0, Math.max(0, toks.length - argv.length - 1));
  const f = extractGitScopeFlagsFromArgv(argv);
  const assigns = {};
  const envOverride = {};
  let unsets = false;
  for (const t of prefix) {
    if (typeof t !== "string") continue;
    const m = ASSIGN_RE.exec(t);
    if (m) assigns[m[1]] = m[2];
    if (TARGET_ASSIGN_RE.test(t)) envOverride[m[1]] = m[2];
    else if (NAMES_TARGET_ENV_RE.test(t)) unsets = true;
  }
  const inheritedKeys = ENV_KEYS.filter((k) => envOverride[k] === undefined && env[k] !== undefined);
  const override = f.gitDir !== null || f.workTree !== null || f.worktreeConfig !== null ||
    Object.keys(envOverride).length > 0 || unsets || inheritedKeys.length > 0;
  const out = { confined, override, origin: null, gitDir: null, workTree: null, coreWorktree: null, envOverride: {}, inherited: false };
  out.inherited = (inheritedKeys.includes("GIT_DIR") && f.gitDir === null) ||
    (inheritedKeys.includes("GIT_WORK_TREE") && f.workTree === null);
  const fail = (reason) => Object.assign(out, { unresolvable: reason, override: true });
  if (unsets) return fail("GIT_DIR / GIT_WORK_TREE is unset in the command");
  if (Object.keys(assigns).some((k) => CONFIG_ENV_RE.test(k))) return fail("a GIT_CONFIG_* assignment can carry core.worktree");
  for (const k of inheritedKeys) if (env[k] === "") return fail(`the inherited ${k} is empty`);

  let origin = toWindowsPath(toolCwd || process.cwd());
  for (const c of f.cList) {
    const r = literalValue(c);
    if (r.reason) return fail(`-C: ${r.reason}`);
    origin = path.resolve(origin, toWindowsPath(r.value));
  }
  out.origin = origin;
  for (const [key, raw, label] of [["gitDir", f.gitDir, "--git-dir"], ["workTree", f.workTree, "--work-tree"]]) {
    if (raw === null) continue;
    const r = literalValue(raw);
    if (r.reason) return fail(`${label}: ${r.reason}`);
    out[key] = r.value;
  }
  for (const [k, raw] of Object.entries(envOverride)) {
    const r = literalValue(raw);
    if (r.reason) return fail(`${k}: ${r.reason}`);
    out.envOverride[k] = r.value;
  }
  const wc = f.worktreeConfig;
  if (wc) {
    let raw = wc.value;
    if (wc.form === "config-env") {
      raw = Object.prototype.hasOwnProperty.call(assigns, wc.envvar) ? assigns[wc.envvar] : env[wc.envvar];
      if (raw === undefined) return fail(`--config-env names ${wc.envvar}, which is not set`);
      if (!Object.prototype.hasOwnProperty.call(assigns, wc.envvar)) out.inherited = true;
    }
    const r = literalValue(raw);
    if (r.reason) return fail(`core.worktree: ${r.reason}`);
    out.coreWorktree = r.value;
  }
  return out;
}

// → { segments, anyOverride, coversAllWrites }. coversAllWrites: every write is an
// overridden, repo-confined git write and nothing else in the command can write.
function collectInputs(ir, toolCwd, env) {
  const inheritedSet = ENV_KEYS.some((k) => env[k] !== undefined);
  if (!ir || ir.parseFailure === true || !Array.isArray(ir.segments)) {
    const raw = String((ir && ir.rawText) || "");
    return inheritedSet || PARSE_FAILURE_KEYWORDS_RE.test(raw) ? failed("the command cannot be parsed", inheritedSet) : NONE;
  }
  const segments = [];
  let covers = true;
  let setter = false;
  let cwdMoves = false;
  for (const seg of ir.segments) {
    if (changesCwd(seg)) cwdMoves = true;
    const argv = resolveGitArgvForSegment(seg);
    if (argv === null) {
      covers = false;
      if (setsTargetEnv(seg)) setter = true;
      continue;
    }
    if (hasWriteRedirect(seg)) covers = false;
    const confined = C_CONFINED_WRITE_SUBCOMMANDS.has(resolveGitSubArgv(argv).subArgv[0]);
    if (!isGitWriteArgv(argv) && !confined) continue;
    segments.push(segmentInputs(seg, argv, confined, toolCwd, env));
  }
  if (segments.length === 0) return NONE;
  if (setter) return failed("another segment sets or unsets GIT_DIR / GIT_WORK_TREE", inheritedSet);
  const anyOverride = segments.some((s) => s.override);
  if (cwdMoves && anyOverride) return failed("the command changes directory before a redirected git write", inheritedSet);
  const coversAllWrites = covers && segments.every((s) => s.override && s.confined && !s.unresolvable);
  return { segments, anyOverride, coversAllWrites };
}

module.exports = { collectInputs };
