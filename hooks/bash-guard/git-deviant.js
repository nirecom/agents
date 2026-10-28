"use strict";
// hooks/bash-guard/git-deviant.js — the git-deviant detector (#2617), a registry separate from
// the forbidden literals. It reads parsed argv, not substrings, so a `-f` inside a branch name
// or path is never the force flag. Launch options (-C / -c / --no-pager), env/command wrappers,
// path-qualified git and `.exe` resolve through the shared git-write-ir resolvers.

const {
  resolveGitArgvForSegment,
  resolveGitSubArgv,
  isGitBasename,
} = require("../lib/bash-write-patterns/git-write-ir");
const { scanWrappedVerb } = require("../lib/bash-write-patterns/segment-utils");
const { GIT_DEVIANT_FORMS } = require("./git-deviant/forms");
const { judgePush } = require("./git-deviant/push");
const { judgeWorktreeRemove } = require("./git-deviant/worktree-remove");
const { judgeClean } = require("./git-deviant/clean");

function judgeGitArgv(gitArgv) {
  const { subArgv } = resolveGitSubArgv(gitArgv);
  const [sub, ...rest] = subArgv;
  if (sub === "push") return judgePush(rest);
  if (sub === "clean") return judgeClean(rest);
  if (sub === "worktree" && rest[0] === "remove") return judgeWorktreeRemove(rest.slice(1));
  return null;
}

function formIdOfSegment(seg) {
  const gitArgv = resolveGitArgvForSegment(seg);
  if (gitArgv !== null) return judgeGitArgv(gitArgv);
  let formId = null;
  scanWrappedVerb(seg, (tok, rest) => isGitBasename(tok) && (formId = judgeGitArgv(rest)) !== null);
  return formId;
}

/**
 * Takes a command IR parse result.
 * @returns {{formId: string, code: string}|null} the first deviant segment's form
 */
function detectGitDeviant(ir) {
  if (!ir || ir.parseFailure === true || !Array.isArray(ir.segments)) return null;
  for (const seg of ir.segments) {
    const formId = formIdOfSegment(seg);
    if (formId && GIT_DEVIANT_FORMS[formId]) return { formId, code: GIT_DEVIANT_FORMS[formId].code };
  }
  return null;
}

module.exports = { detectGitDeviant };
