"use strict";
// Commit scope (#1633): which commits the workflow gate inspects. A commit is
// checked only once this session's WF has begun AND it lands in the WF target repo
// set (lib/wf-target-repos.js). Replaces the cwd-anchored cross-repo bypass.
// Verdicts: approve (out of scope), block (one call spans several in-set repos, or
// an unplaceable commit meets a multi-repo set), check (run the gates at repoDir).

const { toWindowsPath } = require("../lib/branch-diff");
const { resolveRepoDir, resolveCommandIndependentRepo, REPO_DIR_SOURCES } = require("./repo-resolution");
const { compareRepoIdentity, resolveRepoLocation, VERDICTS } = require("../lib/repo-identity");
const { readWorkflowBegun } = require("../lib/workflow-begun");
const { readWfTargetRepos, findMainMember, classifyDirAgainstWfTargetRepos } = require("../lib/wf-target-repos");

// A default-target commit is placed only when its repo was named, not guessed:
// the staged-changes pick and a possibly drifted process.cwd() stay ambiguous.
const DETERMINISTIC_DEFAULT_REPO_SOURCES = Object.freeze([
  REPO_DIR_SOURCES.PAYLOAD_CWD,
  REPO_DIR_SOURCES.PROJECT_DIR,
]);

const RESET_HINT = "\n\nTo reset workflow state, run:\n" + '  echo "<<WORKFLOW_RESET_FROM_research: {reason}>>"';

// A bare commit runs in the payload cwd, so a project-dir answer counts only when
// that cwd is the same repo (null = usable; otherwise the reason it is not).
function defaultRepoRejection(defaultRepo, input) {
  if (!DETERMINISTIC_DEFAULT_REPO_SOURCES.includes(defaultRepo.source)) return "non-deterministic-source";
  if (defaultRepo.source !== REPO_DIR_SOURCES.PROJECT_DIR) return null;
  const cwd = input && typeof input.cwd === "string" && input.cwd.length > 0 ? input.cwd : null;
  if (cwd === null) return "payload-cwd-missing";
  const verdict = compareRepoIdentity(toWindowsPath(cwd), toWindowsPath(defaultRepo.dir));
  return verdict === VERDICTS.SAME ? null : "payload-cwd-project-dir-mismatch";
}

function decideCommitScope({ sessionId, commitTargets, commitDetected, command, input }) {
  let scope;
  try {
    scope = decideCommitScopeUnsafe({ sessionId, commitTargets, commitDetected, input });
  } catch (_) {
    scope = { action: "check", repoDir: null };
  }
  if (scope.action === "check" && !scope.repoDir) scope.repoDir = resolveRepoDir(command, input);
  return scope;
}

function decideCommitScopeUnsafe({ sessionId, commitTargets, commitDetected, input }) {
  // No session id: the gate blocks for the missing session_id after the checks.
  if (!sessionId) return { action: "check", repoDir: null };

  const begun = readWorkflowBegun(sessionId);
  if (begun.verdict === "not-begun") return { action: "approve" };
  if (begun.verdict === "unknown") return { action: "check", repoDir: null };

  const wfTargets = readWfTargetRepos(sessionId, begun.state);
  const targets = Array.isArray(commitTargets) ? commitTargets : [];
  // A commit the enumerator could not split out still counts as one unplaceable commit.
  const effectiveTargets = targets.length === 0 && commitDetected
    ? [{ target: { kind: "ambiguous", reason: "unenumerated-commit" } }]
    : targets;

  const inSet = [];
  let ambiguousCount = 0;
  let defaultDir;
  for (const entry of effectiveTargets) {
    const dir = placeCommit(entry && entry.target, () => {
      if (defaultDir === undefined) defaultDir = deterministicDefaultDir(input);
      return defaultDir;
    });
    if (dir === null) { ambiguousCount += 1; continue; }
    if (!wfTargets.ok) {
      // Unknown set: every resolvable commit is treated as in the set (fail-closed).
      const location = resolveRepoLocation(toWindowsPath(dir));
      if (location) inSet.push({ dir, location });
      else ambiguousCount += 1;
      continue;
    }
    const cl = classifyDirAgainstWfTargetRepos(wfTargets.members, dir);
    if (cl.verdict === "in" || cl.verdict === "possibly-in") inSet.push({ dir, location: cl.location });
    else if (cl.verdict === "location-unknown") ambiguousCount += 1;
  }

  const repoDirs = distinctRepoDirs(inSet);
  if (repoDirs.length === 0 && ambiguousCount === 0) return { action: "approve" };
  if (repoDirs.length >= 2) return { action: "block", reason: multiRepoBlockReason(repoDirs) };
  if (ambiguousCount > 0 && wfTargets.ok && wfTargets.members.length >= 2) {
    return { action: "block", reason: ambiguousMultiSetBlockReason() };
  }
  if (repoDirs.length === 1) return { action: "check", repoDir: repoDirs[0] };
  return { action: "check", repoDir: pickAmbiguousCheckDir(wfTargets, input) };
}

// The dir a commit lands in, or null when it cannot be placed.
function placeCommit(target, getDefaultDir) {
  if (!target) return null;
  let dir = null;
  if (target.kind === "explicit") dir = target.dir;
  else if (target.kind === "default") dir = getDefaultDir();
  return typeof dir === "string" && dir.length > 0 ? dir : null;
}

function deterministicDefaultDir(input) {
  const defaultRepo = resolveCommandIndependentRepo(input);
  return defaultRepoRejection(defaultRepo, input) === null ? defaultRepo.dir : null;
}

// One dir per repository (keyed by git common dir), in first-seen order.
function distinctRepoDirs(commits) {
  const seen = new Map();
  for (const c of commits) {
    const key = c.location && c.location.commonDir;
    if (key && !seen.has(key)) seen.set(key, c.dir);
  }
  return [...seen.values()];
}

function multiRepoBlockReason(dirs) {
  return (
    "workflow-gate: one call commits to several repositories in the workflow's target set.\n" +
    "Split the commit into separate calls, one per repository:\n" +
    dirs.map((d) => `  git -C "${d}" commit ...`).join("\n") +
    RESET_HINT
  );
}

function ambiguousMultiSetBlockReason() {
  return (
    "workflow-gate: a commit target cannot be determined and the workflow targets several repositories.\n" +
    "Name the repository explicitly with git -C <path>:\n" +
    "  git -C <repo-path> commit -m ..." +
    RESET_HINT
  );
}

// No placed in-set commit: check the payload's own repo when it is in the set, else the main repo.
function pickAmbiguousCheckDir(wfTargets, input) {
  const fallback = resolveCommandIndependentRepo(input).dir;
  if (!wfTargets.ok) return fallback;
  if (typeof fallback === "string" && fallback.length > 0) {
    const cl = classifyDirAgainstWfTargetRepos(wfTargets.members, fallback);
    if (cl.verdict === "in" || cl.verdict === "possibly-in") return fallback;
  }
  const main = findMainMember(wfTargets.members);
  return main ? toWindowsPath(main.declaredPath) : fallback;
}

function describeUnreadableState(sessionId) {
  const begun = readWorkflowBegun(sessionId);
  let msg;
  if (begun.reason === "invalid-session-id") {
    msg = `workflow-gate: session id ${sessionId} is not a valid session id — workflow state cannot be located. Commit blocked (fail-closed).`;
  } else if (begun.reason === "state-unreadable") {
    msg = `workflow-gate: workflow state for session ${sessionId} is unreadable (corrupt, unsupported version, or failed integrity check). Commit blocked (fail-closed).`;
  } else {
    msg = `workflow-gate: workflow state for session ${sessionId} could not be read. Commit blocked (fail-closed).`;
  }
  return msg + RESET_HINT;
}

module.exports = {
  decideCommitScope,
  describeUnreadableState,
  DETERMINISTIC_DEFAULT_REPO_SOURCES,
  defaultRepoRejection,
};
