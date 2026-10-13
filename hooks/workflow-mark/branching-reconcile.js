"use strict";
// Delivery-path reconcile for BRANCHING_COMPLETE (#2527 plan 3-13, judgment A).
// The sentinel's `worktree:` segment must agree with the delivery path the session
// will be pinned to, BEFORE anything is written: a pull_request delivery needs a
// linked worktree of the same repository the session runs in; a direct delivery
// must not be declared from or into a linked worktree. Only the sentinel's own
// `worktree:` is judged — a stale state.session_worktree never decides.
//
// reconcileDeliveryPath({ sessionId, decision, repoCwd })
//   -> { ok: true, deliveryPath } | { ok: false, reason, detail }
// Never throws: an internal failure is { ok: false, reason: "reconcile-error" }.

const fs = require("fs");

const WORKTREE_SEGMENT_RE = /\bworktree:\s*([^\s|]+)/;

// Read at call time through the module object so a test preload can replace it.
function rwp() {
  return require("../workflow-state/resolve-worktree-path");
}

function toNative(p) {
  return require("../lib/branch-diff").toWindowsPath(p);
}

function declaredWorktreeOf(decision) {
  const m = typeof decision === "string" ? decision.match(WORKTREE_SEGMENT_RE) : null;
  return m ? toNative(m[1]) : null;
}

function targetDeliveryPath(sessionId, repoCwd) {
  const { readState } = require("../workflow-state");
  const { DELIVERY_PATHS, resolveLiveDeliveryPath } = require("../lib/delivery-path");
  const st = readState(sessionId);
  if (st && DELIVERY_PATHS.includes(st.delivery_path)) return st.delivery_path;
  return resolveLiveDeliveryPath(sessionId, repoCwd);
}

function reject(reason, detail) {
  return { ok: false, reason, detail };
}

function reconcilePullRequest(declared, repoCwd) {
  if (!declared) return reject("no-worktree", "a pull_request delivery needs `worktree: <linked worktree path>` in the decision");
  if (!fs.existsSync(declared)) return reject("worktree-missing", `the declared worktree ${declared} does not exist`);
  if (rwp().isMainWorktree(declared) !== false) {
    const confirmed = rwp().gitCommonDirOf(declared) !== null;
    return reject("worktree-is-main", confirmed
      ? `the declared worktree ${declared} is a main checkout, not a linked worktree`
      : `could not confirm that ${declared} is a linked worktree (git cannot read it)`);
  }
  const repoCommon = repoCwd ? rwp().gitCommonDirOf(repoCwd) : null;
  if (repoCommon === null) return reject("repo-unknown", `git cannot resolve the repository of the session cwd ${repoCwd || "(none)"}`);
  const wtCommon = rwp().gitCommonDirOf(declared);
  if (wtCommon === null || !sameDir(repoCommon, wtCommon)) {
    return reject("worktree-other-repo",
      `the declared worktree belongs to ${wtCommon || "(unknown)"}, the session runs in ${repoCommon}`);
  }
  return null;
}

function reconcileDirect(declared, repoCwd) {
  // A git failure reads as "main" here: only a confirmed linked worktree is rejected.
  const isLinked = (dir) => !!dir && fs.existsSync(dir) && rwp().isMainWorktree(dir) === false;
  if (isLinked(declared)) {
    return reject("direct-in-linked-worktree", `a direct delivery must not declare the linked worktree ${declared}`);
  }
  if (isLinked(repoCwd)) {
    return reject("direct-in-linked-worktree", `a direct delivery must not run from the linked worktree ${repoCwd}`);
  }
  return null;
}

// Windows paths compare case-insensitively; elsewhere the bytes decide.
function sameDir(a, b) {
  const norm = (p) => {
    const s = require("path").resolve(toNative(p)).replace(/\\/g, "/");
    return process.platform === "win32" ? s.toLowerCase() : s;
  };
  return norm(a) === norm(b);
}

function reconcileDeliveryPath({ sessionId, decision, repoCwd } = {}) {
  try {
    const cwd = typeof repoCwd === "string" && repoCwd ? toNative(repoCwd) : null;
    const deliveryPath = targetDeliveryPath(sessionId, cwd);
    const declared = declaredWorktreeOf(decision);
    const r = deliveryPath === "pull_request" ? reconcilePullRequest(declared, cwd) : reconcileDirect(declared, cwd);
    return r || { ok: true, deliveryPath };
  } catch (e) {
    return reject("reconcile-error", `the reconcile itself failed (${e && e.message ? e.message : e})`);
  }
}

module.exports = { reconcileDeliveryPath };
