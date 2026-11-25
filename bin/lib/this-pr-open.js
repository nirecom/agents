"use strict";

// Which this-pr findings in WORKTREE_NOTES.md are still unsettled (#3145 S2/S3), the refusal text
// every block point prints, and the session's notes path bound to the trusted repo dir.

const fs = require("fs");
const path = require("path");
const { findingKey } = require("../../hooks/lib/finding-approval");
const { normalizePathForCompare } = require("../../hooks/lib/repo-identity");
const { toWindowsPath } = require("../../hooks/lib/branch-diff");
const { triageEntries } = require("../worktree-notes-triage/groups");
const { openThisPrReason } = require("./finding-rules");
const { fixedEvidence, defaultGitRunner } = require("./fixed-evidence");

const NOTES_FILE = "WORKTREE_NOTES.md";
const BODY_MAX = 80;
const fwd = (p) => String(p).replace(/\\/g, "/");
// The hint names the triage CLI of this script's own checkout, so a pasted command runs the same code.
const TRIAGE = `node "${fwd(path.resolve(__dirname, "..", "worktree-notes-triage.js"))}"`;

function openOf(entry, runGit) {
  let fixedVerified = false;
  let detail = null;
  if (entry.prScope === "this-pr" && entry.disposed === "fixed" && !entry.userAccepted) {
    const ev = fixedEvidence(entry, runGit);
    fixedVerified = ev.ok;
    if (!ev.ok) detail = `${ev.reason}${ev.path ? ` ${ev.path}` : ""}`;
  }
  const reason = openThisPrReason(entry, { fixedVerified });
  if (reason === null) return null;
  return {
    key: findingKey(entry.section, entry.body), lineNumber: entry.lineNumber,
    section: entry.section, body: entry.body, reason, detail,
  };
}

// {state: "absent"|"ok"|"error", open: [{key, lineNumber, section, body, reason, detail}], reason}.
function readOpenThisPr(notesPath, opts) {
  const o = opts || {};
  let text;
  try {
    text = fs.readFileSync(notesPath, "utf8");
  } catch (e) {
    if (e && e.code === "ENOENT") return { state: "absent", open: [], reason: null };
    return { state: "error", open: [], reason: `unreadable notes: ${(e && e.code) || (e && e.message) || e}` };
  }
  try {
    const runGit = typeof o.runGit === "function" ? o.runGit : defaultGitRunner(path.dirname(notesPath));
    const open = triageEntries(text).map((e) => openOf(e, runGit)).filter(Boolean);
    return { state: "ok", open, reason: null };
  } catch (e) {
    return { state: "error", open: [], reason: `notes check failed: ${(e && e.message) || e}` };
  }
}

function exitsOf(notes, o) {
  const accept = `      (3) accept: echo "<<WORKFLOW_THIS_PR_FINDING_ACCEPTED: key=${o.key} <reason>>>"`;
  const file = `/issue-create --finding-key ${o.key}`;
  if (o.reason === "rescoped-unfiled") {
    return [
      `      (2) file: ${file}`,
      `      (2b) already filed: ${TRIAGE} annotate ${notes} key=${o.key} <issue-number>`,
      accept,
    ];
  }
  const fix = [`      (1) fix: ${TRIAGE} dispose ${notes} key=${o.key} fixed`];
  if (o.detail) fix.push(`          not verified (${o.detail}); change that path and it passes by itself`);
  return fix.concat([`      (2) move out: ${TRIAGE} rescope ${notes} key=${o.key}, then ${file}`, accept]);
}

function formatOpenThisPrRefusal(notesPath, open) {
  const notes = fwd(notesPath);
  const lines = [`this-pr findings are unsettled (${open.length}) in ${notes}:`];
  for (const o of open) {
    lines.push(`  [${o.key}] ${o.reason}: ${String(o.body).slice(0, BODY_MAX)}`);
    lines.push(...exitsOf(notes, o));
  }
  return lines.join("\n");
}

// The refusal for a notes check that could not run (error / repo-unresolved / cwd-mismatch).
function formatDegradedRefusal(reason) {
  const lines = [`this-pr findings cannot be checked: ${reason}`];
  if (/cwd-mismatch/.test(String(reason))) lines.push("  re-run from the session worktree.");
  return lines.join("\n");
}

function realOrSelf(p) {
  try { return fs.realpathSync.native(toWindowsPath(p)); } catch (_e) { return p; }
}

// {path} or {error}: the trusted repo dir's notes, refused when the session's linked worktree
// is elsewhere. A session without a linked worktree reads the trusted repo dir's notes.
function resolveSessionNotesPath(sessionId) {
  const { resolveTrustedRepoDir } = require("../../hooks/workflow-state/record-step-verdict/trusted-repo-dir");
  const { readState } = require("../../hooks/workflow-state/state-io");
  const { resolveSessionWorktreePath } = require("../../hooks/workflow-state/resolve-worktree-path");
  const trusted = resolveTrustedRepoDir();
  if (!trusted) return { error: "repo-unresolved: the current directory is not inside a git repository" };
  let state = null;
  try { state = sessionId ? readState(sessionId) : null; } catch (_e) { state = null; }
  if (state === null) return { error: `no-state: no workflow state for session ${sessionId}` };
  const wt = resolveSessionWorktreePath(sessionId);
  if (wt && normalizePathForCompare(realOrSelf(wt)) !== normalizePathForCompare(realOrSelf(trusted))) {
    return { error: `cwd-mismatch: the current repo ${fwd(trusted)} is not the session worktree ${fwd(wt)}` };
  }
  return { path: path.join(toWindowsPath(trusted), NOTES_FILE) };
}

module.exports = { readOpenThisPr, formatOpenThisPrRefusal, formatDegradedRefusal, resolveSessionNotesPath };
