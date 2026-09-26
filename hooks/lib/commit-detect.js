// hooks/lib/commit-detect.js — classifier for "git commit" commands (counterpart of
// merge-detect.js). Resolves each IR segment through the shared wrapper model so
// `rtk git commit`, `env git commit`, `git -C <dir> commit` all reach the commit gate.
// Consumed by workflow-gate.js.

"use strict";

const { resolveGitArgvForSegment, resolveGitSubArgv, isGitBasename } = require("./bash-write-patterns/git-write-ir");
const { scanWrappedVerb, resolveEffectiveCommand, resolveEffectiveArgv, commandBasename } = require("./bash-write-patterns/segment-utils");
const { parse } = require("./command-ir");

const SHELL_SPECIAL_RE = /[\s;|&<>"'`$\\]/;

function quoteIfNeeded(token) {
  const s = String(token);
  if (s === "") return "''";
  if (!SHELL_SPECIAL_RE.test(s)) return s;
  return "'" + s.replace(/'/g, "'\\''") + "'";
}

function isCommitArgv(gitArgv) {
  if (!Array.isArray(gitArgv)) return false;
  return resolveGitSubArgv(gitArgv).subArgv[0] === "commit";
}

// Effective git argv (excluding `git`) of the first commit segment, or null.
// An AMBIGUOUS wrapper peel falls back to the raw argv after the first git token.
function findCommitArgv(ir) {
  if (!ir || !Array.isArray(ir.segments)) return null;
  for (const seg of ir.segments) {
    const gitArgv = resolveGitArgvForSegment(seg);
    if (gitArgv !== null) {
      if (isCommitArgv(gitArgv)) return gitArgv;
      continue;
    }
    let hidden = null;
    scanWrappedVerb(seg, (tok, rest) => {
      if (hidden === null && isGitBasename(tok) && isCommitArgv(rest)) hidden = rest;
      return hidden !== null;
    });
    if (hidden !== null) return hidden;
    // Handle sh -c shell body produced by `rtk run "git commit …"` via shellBodyVerbs
    const ecmd = commandBasename(resolveEffectiveCommand(seg));
    if (ecmd === "sh" || ecmd === "bash") {
      const ea = resolveEffectiveArgv(seg);
      if (ea[0] === "-c" && typeof ea[1] === "string") {
        const bodyResult = findCommitArgv(parse(ea[1]));
        if (bodyResult !== null) return bodyResult;
      }
    }
  }
  return null;
}

// Fail-closed on parse failure: the pre-IR raw-text test stays in force.
function rawLooksLikeCommit(ir) {
  const raw = ir && typeof ir.rawText === "string" ? ir.rawText : "";
  return /\bgit\b/.test(raw) && /\scommit(\s|$)/.test(raw);
}

function isCommitCommand(ir) {
  if (!ir) return false;
  if (ir.parseFailure === true) return rawLooksLikeCommit(ir);
  return findCommitArgv(ir) !== null;
}

// `git <effective argv>` text of the commit segment, for head-anchored text parsers
// such as parseGitConfigValues. Returns null when no commit segment exists.
function extractCommitSegmentText(ir) {
  if (!ir) return null;
  if (ir.parseFailure === true) return rawLooksLikeCommit(ir) ? ir.rawText : null;
  const argv = findCommitArgv(ir);
  if (argv === null) return null;
  return "git " + argv.map(quoteIfNeeded).join(" ");
}

module.exports = { isCommitCommand, extractCommitSegmentText, quoteIfNeeded };
