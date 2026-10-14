"use strict";

// Stage 4 (#1644) — session-scoped facts (closes_issues, repo context).
//
// closes_issues is parsed from <plansDir>/<sid>-intent.md on every call (#2654);
// this module never reads or writes state.closes_issues. Repo context is a
// read-only view over the EXISTING session_start_context state key.

const path = require("path");
const { readState, assertValidSessionId } = require("./state-io");
const { parseClosesIssues } = require("../lib/parse-closes-issues");

// getClosesIssues(sessionId, { plansDir }) -> Array<{number, repo?}>
//
// Parses <plansDir>/<sessionId>-intent.md `## Issues` via parseClosesIssues()
// (the format-parsing SSOT) on each call. A missing or unreadable intent.md
// yields [] — no fallback to any recorded value.
function getClosesIssues(sessionId, opts) {
  // sessionId flows into a path join below; reject traversal-shaped ids.
  assertValidSessionId(sessionId);
  const plansDir = (opts && opts.plansDir) || "";
  return parseClosesIssues(path.join(plansDir, `${sessionId}-intent.md`));
}

// getSessionRepoContext(sessionId) -> { cwd, git_branch }
//
// Read-only synthesis over the EXISTING `session_start_context` key, written
// once by createInitialState and immutable after (CPR-SC). Never writes.
function getSessionRepoContext(sessionId) {
  const state = readState(sessionId);
  const ctx = (state && state.session_start_context) || {};
  return {
    cwd: typeof ctx.cwd === "string" ? ctx.cwd : null,
    git_branch: ctx.git_branch !== undefined ? ctx.git_branch : null,
  };
}

module.exports = { getClosesIssues, getSessionRepoContext };
