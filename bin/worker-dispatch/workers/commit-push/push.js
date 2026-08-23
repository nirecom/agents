"use strict";
// bin/worker-dispatch/workers/commit-push/push.js
//
// Step 7 of the commit-push procedure: the push attempts and the rebase ladder.
// Split out of the parent module per rules/coding/file-split.md Pattern A.
// What/Why: docs/architecture/claude-code/worker-dispatch/commit-push.md
// ("Step 7 — the push retry and the rebase ladder").

const { firstLine, runGit } = require("./gate");

const PUSH_ATTEMPTS = 3;
// Waits BEFORE attempt 2 and attempt 3. Attempt 1 is immediate.
const RETRY_WAIT_MS = [0, 2000, 5000];

// Synchronous wait: the whole worker is a straight-line spawnSync procedure, and
// introducing an async tick here would change the shape of every caller above it.
function sleepMs(ms) {
  if (!(ms > 0)) return;
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

// Step 7. Returns { status: "ok" } or a terminal { status, summary }.
// No force flag is ever assembled — not `--force`, not `--force-with-lease`.
function pushToRemote(ctx, payload, branch, pushArgs, log) {
  let last = "";
  for (let attempt = 1; attempt <= PUSH_ATTEMPTS; attempt += 1) {
    sleepMs(RETRY_WAIT_MS[attempt - 1]);

    const res = runGit(ctx, payload, pushArgs, log, undefined, ["SSH_AUTH_SOCK"]);
    if (res !== null && res.status === 0) return { status: "ok" };
    last = res === null ? "git push could not start" : firstLine(res.stderr) || `exit ${res.status}`;
    if (res === null) break;

    const text = `${res.stdout || ""}\n${res.stderr || ""}`;
    const nonFastForward = /non-fast-forward|rejected|fetch first|behind/i.test(text);
    if (!nonFastForward || attempt === PUSH_ATTEMPTS) continue;

    const laddered = rebaseOntoRemote(ctx, payload, branch, log);
    if (laddered !== null) return laddered;
  }
  return {
    status: "push_failed",
    summary: `push to origin/${branch} failed after ${PUSH_ATTEMPTS} attempts: ${last}`,
  };
}

// The rebase ladder: fetch, replay this branch on top, then let the caller retry
// the SAME explicit push. Returns null when the ladder succeeded, or a terminal
// { status, summary } when it did not.
//
// Two calls, not one `git pull --rebase`: the FETCH is the network half and is
// the only half that needs SSH_AUTH_SOCK, while the REBASE replay is local and
// can run repo-configured hooks (pre-rebase, post-rewrite) and merge/smudge
// drivers — a code-execution surface that gets an empty env scope. FETCH_HEAD is
// the exact ref `git pull --rebase origin <branch>` resolved to, and
// `--autostash` keeps an unrelated dirty worktree out of the replay.
function rebaseOntoRemote(ctx, payload, branch, log) {
  const fetched = runGit(ctx, payload, ["fetch", "origin", branch], log, undefined, [
    "SSH_AUTH_SOCK",
  ]);
  if (fetched === null || fetched.status !== 0) {
    const detail = fetched === null ? "" : `${fetched.stdout || ""}\n${fetched.stderr || ""}`;
    return {
      status: "push_failed",
      summary: `fetch origin ${branch} failed before retry: ${firstLine(detail) || "unknown error"}`,
    };
  }

  const rebase = runGit(ctx, payload, ["rebase", "--autostash", "FETCH_HEAD"], log, undefined, []);
  if (rebase === null || rebase.status !== 0) {
    const detail = rebase === null ? "" : `${rebase.stdout || ""}\n${rebase.stderr || ""}`;
    if (/conflict/i.test(detail)) {
      return {
        status: "conflict",
        summary: `rebase onto origin/${branch} hit a conflict — resolve it manually, then re-run /commit-push`,
      };
    }
    return {
      status: "push_failed",
      summary: `rebase onto origin/${branch} failed before retry: ${firstLine(detail) || "unknown error"}`,
    };
  }
  return null;
}

module.exports = { pushToRemote, rebaseOntoRemote, sleepMs, PUSH_ATTEMPTS, RETRY_WAIT_MS };
