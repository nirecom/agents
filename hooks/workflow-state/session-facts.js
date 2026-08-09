"use strict";
// lang-check: ignore — pre-existing origin/main content, unmodified by this session's merge.

// Stage 4 (#1644) — 型2: セッション内キャッシュの一度きり解決.
//
// Resolves session-scoped facts (closes_issues, repo context) at most once
// per session and caches the result in the EXISTING top-level state keys
// (see hooks/workflow-state/state-io/projection.js PERSISTED_TOP_LEVEL_KEYS —
// this module never introduces a new one). Consumers that used to call
// parseClosesIssues() directly on every invocation should call
// getClosesIssues() instead so a session settles on one answer.

const path = require("path");
const { readState, updateTopLevel, assertValidSessionId } = require("./state-io");
const { parseClosesIssues } = require("../lib/parse-closes-issues");

// getClosesIssues(sessionId, { plansDir }) -> Array<{number, repo?}>
//
// Write-once cache over the EXISTING `closes_issues` top-level key:
//   - state.closes_issues already non-empty -> return it as-is, no re-parse.
//   - otherwise -> parse <plansDir>/<sessionId>-intent.md via parseClosesIssues()
//     (the format-parsing SSOT, untouched by this module), record the result
//     into state.closes_issues via updateTopLevel, then return it.
//
// The write is skipped when no state file exists yet for sessionId — this
// keeps read-mostly consumers (report renderers, outcome writers) from
// fabricating a workflow state record as a side effect; they simply get the
// freshly-parsed value back, same as calling parseClosesIssues() directly.
function getClosesIssues(sessionId, opts) {
  // M4: sessionId flows unvalidated into a path join below. It was only
  // accidentally safe because readState() (called next) happens to run
  // assertValidSessionId first and throws on a traversal-shaped id — a
  // guarantee that must not depend on call ordering. Assert explicitly here.
  assertValidSessionId(sessionId);
  const plansDir = (opts && opts.plansDir) || "";
  const state = readState(sessionId);

  if (state && Array.isArray(state.closes_issues) && state.closes_issues.length > 0) {
    return state.closes_issues;
  }

  const intentPath = path.join(plansDir, `${sessionId}-intent.md`);
  const parsed = parseClosesIssues(intentPath);

  if (state) {
    updateTopLevel(sessionId, (record) => {
      record.closes_issues = parsed;
    });
  }

  return parsed;
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
