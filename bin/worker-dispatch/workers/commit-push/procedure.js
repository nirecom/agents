"use strict";
// bin/worker-dispatch/workers/commit-push/procedure.js
//
// The commit-push run() spine — steps 0-6, 8 and 10 — with step 7 in ./push.js,
// step 9 in ./pr.js and the D1 gate seam in ./gate.js. Split out of the parent
// module per rules/coding/file-split.md Pattern A.
//
// The step numbers are those of the agent prompt this worker replaced (#1673),
// so a reader of either document is looking at the same procedure. What each
// step is for and why it fails the way it does:
// docs/architecture/claude-code/worker-dispatch/commit-push.md

const { ensurePullRequest } = require("./pr");
const { firstLine, isProtectedBranch, resolveGateEnv, runGate, runGit, runScript } = require("./gate");
const { pushToRemote } = require("./push");

const MAX_LISTED_FILES = 5;

function stamp() {
  return new Date().toISOString().replace(/[:.]/g, "-").replace(/Z$/, "Z");
}

function run(payload, ctx) {
  const log = [];
  const gateEnv = resolveGateEnv(payload, ctx);
  const branch = payload.branch;

  const finish = (status, summary) => ({
    status,
    summary,
    artifactPath: writeLog(payload, ctx, log),
  });

  // Step 0 — `branch` must be the branch actually checked out at worktree_path.
  // Nothing downstream re-derives it, so a stale or crafted payload could push
  // this worktree's staged changes under another branch's name or walk past
  // isProtectedBranch() entirely. A probe that cannot answer is a mismatch, not
  // a pass: this runs before the first mutation, so failing closed costs nothing.
  const head = runGit(ctx, payload, ["rev-parse", "--abbrev-ref", "HEAD"], log);
  if (head === null || head.spawnError !== null || head.timedOut || head.status !== 0) {
    return finish(
      "branch_mismatch",
      "the checked-out branch of the worktree could not be determined — refusing to commit",
    );
  }
  const headBranch = String(head.stdout || "").trim();
  if (headBranch !== branch) {
    return finish(
      "branch_mismatch",
      `checked-out branch '${headBranch}' does not match payload.branch '${branch}'`,
    );
  }

  // Step 1 — staged changes must exist before anything else happens.
  const staged = runGit(ctx, payload, ["diff", "--cached", "--stat"], log);
  if (staged === null || staged.spawnError !== null || staged.timedOut) {
    return finish("staging_check_failed", "git diff --cached could not be run");
  }
  if (staged.status !== 0) {
    return finish("staging_check_failed", `git diff --cached exited ${staged.status}`);
  }
  if (String(staged.stdout || "").trim() === "") {
    return finish("staging_incomplete", "nothing is staged — refusing to commit");
  }

  // Step 2 (agent step 1.5) — Gate 3 staging verification via
  // bin/check-unstaged-tracked.sh. wip_mode is the workflow.wip=1 bypass parity;
  // WORKFLOW_OFF / WORKTREE_OFF is a session marker the caller evaluates, not
  // this worker, which has no session marker of its own to read.
  if (payload.wip_mode !== true) {
    const chk = runScript(ctx, payload, "unstagedCheck", [payload.worktree_path], log);
    if (chk === null || chk.spawnError !== null || chk.timedOut) {
      return finish("staging_check_failed", "check-unstaged-tracked.sh could not be run");
    }
    if (chk.status === 1) {
      const files = String(chk.stdout || "")
        .split(/\r?\n/)
        .map((l) => l.trim())
        .filter(Boolean)
        .slice(0, MAX_LISTED_FILES);
      return finish(
        "staging_incomplete",
        `unstaged tracked file(s) detected — staging incomplete; refusing to commit. Files: ${files.join(", ")}`,
      );
    }
    if (chk.status !== 0) {
      return finish(
        "staging_check_failed",
        `check-unstaged-tracked.sh failed (rc=${chk.status}); refusing to commit. ${firstLine(chk.stderr)}`,
      );
    }
  }

  // Step 3 (D1-a) — the gate sees the exact commit argv assembled below.
  // `-c workflow.wip=1` must precede the subcommand, and `-F -` rather than
  // `-m <message>` keeps author-controlled text out of the string the gate
  // resolves the target repository from. Both reasons: commit-push.md "D1".
  const commitArgs = payload.wip_mode === true
    ? ["-c", "workflow.wip=1", "commit", "-F", "-"]
    : ["commit", "-F", "-"];

  const commitGate = runGate(ctx, payload, gateEnv, commitArgs, log);
  if (!commitGate.ok) {
    return finish("gate_blocked", `commit refused by workflow-gate: ${commitGate.reason}`);
  }

  // Step 4 — commit. `--no-verify` is prohibited; hooks/pre-commit still runs.
  const committed = runGit(ctx, payload, commitArgs, log, String(payload.commit_message));
  if (committed === null || committed.status !== 0) {
    return finish(
      "staging_check_failed",
      `git commit failed: ${committed === null ? "could not start" : firstLine(committed.stderr) || `exit ${committed.status}`}`,
    );
  }

  // Step 5 — an empty remote has no default branch to push against; that
  // bootstrap belongs to /worktree-end, not here.
  const probe = runScript(ctx, payload, "bootstrapProbe", [payload.worktree_path], log, ["SSH_AUTH_SOCK"]);
  if (probe !== null && probe.status === 0) {
    let info = null;
    try {
      info = JSON.parse(String(probe.stdout || "").trim());
    } catch (_e) {
      info = null;
    }
    if (info && info.preBootstrap === true && info.classification === "empty-repo") {
      return finish(
        "bootstrap_pending",
        "committed; remote has no default branch — run /worktree-end to complete bootstrap",
      );
    }
  }

  // Steps 6-7 — the push argv is decided BEFORE the gate, because the gate is
  // asked about that argv. A bare `git push` is never issued: merge-detect.js
  // decides on explicit refspecs, so the bare form can slip past the classifier.
  const upstream = runGit(
    ctx,
    payload,
    ["rev-parse", "--abbrev-ref", "--symbolic-full-name", `${branch}@{upstream}`],
    log,
  );
  const hasUpstream = upstream !== null && upstream.status === 0;
  const pushArgs = hasUpstream
    ? ["push", "origin", branch]
    : ["push", "-u", "origin", branch];

  const pushGate = runGate(ctx, payload, gateEnv, pushArgs, log);
  if (!pushGate.ok) {
    const target = isProtectedBranch(branch, gateEnv.DEFAULT_BRANCHES)
      ? ` (protected branch '${branch}')`
      : "";
    return finish(
      "gate_blocked",
      `commit created, push refused by workflow-gate${target}: ${pushGate.reason}`,
    );
  }

  const pushed = pushToRemote(ctx, payload, branch, pushArgs, log);
  if (pushed.status !== "ok") return finish(pushed.status, pushed.summary);

  // Step 8 — no PR on the direct-main flow, and none against a non-GitHub remote.
  if (payload.enforce_worktree === "off") {
    return finish("pushed", `${branch} pushed; PR skipped (ENFORCE_WORKTREE=off)`);
  }
  const isGithub = runScript(ctx, payload, "isGithubRemote", [], log);
  if (isGithub === null || isGithub.status !== 0) {
    return finish("pushed", `${branch} pushed; PR skipped (non-GitHub remote)`);
  }

  // Step 9 — idempotent PR step: pr_reused when one is already OPEN, otherwise
  // pr_created. CP-2b in the calling skill opens the browser for pr_created only.
  const pr = ensurePullRequest(payload, ctx, log);
  return finish(pr.status, pr.summary);
}

// Step 10. Best-effort: a refused log write must not turn a completed push into a
// reported failure. fsguard routes the bytes through redactSentinels.
function writeLog(payload, ctx, log) {
  const dir = payload.artifact_dir || ctx.anchors.plansDir;
  const target = ctx.path.join(dir, `${stamp()}-commit-push-worker.log`);
  const body = log
    .map((l) => String(l === null || l === undefined ? "" : l))
    .filter((l) => l !== "")
    .join("\n");
  try {
    return ctx.fsguard.writeFile(target, `${body}\n`);
  } catch (_e) {
    return "(none)";
  }
}

module.exports = { run, writeLog, stamp, MAX_LISTED_FILES };
