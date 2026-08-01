"use strict";
// bin/worker-dispatch/workers/commit-push.js
//
// Stage 3 worker: replaces agents/commit-push-worker.md (#1673).
//
// The procedure below keeps the step numbers of the agent prompt it replaces, so
// a reader of either document is looking at the same 10 steps:
//
//   0. git rev-parse --abbrev-ref HEAD     payload.branch IS the checked-out branch
//   1. git diff --cached --stat            staged changes exist at all
//   2. bin/check-unstaged-tracked.sh       Gate 3 staging verification (skipped in wip_mode)
//   3. (D1-a) workflow-gate before commit
//   4. git commit
//   5. bin/probe-remote-bootstrap.sh       empty remote -> defer to /worktree-end
//   6. (D1-b) workflow-gate before push
//   7. git push, 3 attempts, rebase ladder, never a force flag
//   8. enforce_worktree=off / non-GitHub remote -> no PR
//   9. gh pr view (reuse) or gh pr create
//  10. write the combined child output to the artifact log
//
// D1 — WHY THE GATE RUNS HERE. Moving `git commit` / `git push` out of the Bash
// tool also moves them out of PreToolUse, where hooks/workflow-gate.js used to
// see them. Two guards go with it: the commit-completion gate (run_tests /
// review_security / docs / user_verification) and the MERGE GATE, which blocks a
// push to a protected branch until user_verification completes regardless of
// ENFORCE_WORKTREE. hooks/pre-commit replaces neither. So the real gate binary is
// driven as a child process twice, with a synthetic PreToolUse payload on stdin,
// and the `command` string it is asked about is the argv this worker is about to
// spawn — joined from that exact array, never a hand-written approximation.
// No payload free text is ever part of that argv: the commit message reaches git
// on stdin (`git commit -F -`), because the gate resolves the repository it
// judges by scanning the command string, and author-controlled text inside it
// could name a different repository than the one being committed to.
//
// FAIL-CLOSED. A gate child that crashes, times out, or answers with something
// that is not JSON is NOT permission. Every such degradation stops the run with
// `gate_blocked`; when the push target is a protected branch the summary says so,
// because that is the case where continuing would have been irreversible.
//
// The five workflow env vars are resolved here and passed EXPLICITLY through
// extraEnv. They are also in the entry's envPassthrough, which permits silent
// inheritance — and an inherited CLAUDE_WORKFLOW_DIR points the gate child at a
// different session's state, where every step reads "missing" and the gate
// approves everything. That is the quiet failure this resolution exists to
// prevent (Risk 3).

const path = require("path");

const { readEnvFile } = require("../../../hooks/lib/load-env");
const { run: spawnRun } = require("../spawn");
const { ensurePullRequest } = require("./commit-push/pr");

const GIT_TIMEOUT_MS = 300000;
const GATE_TIMEOUT_MS = 120000;
const SCRIPT_TIMEOUT_MS = 120000;

const PUSH_ATTEMPTS = 3;
// Waits BEFORE attempt 2 and attempt 3. Attempt 1 is immediate.
const RETRY_WAIT_MS = [0, 2000, 5000];

const DEFAULT_PROTECTED_BRANCHES = "main,master";
const MAX_LISTED_FILES = 5;

// The ONLY decision hooks/workflow-gate.js emits that means "proceed".
const GATE_APPROVE = "approve";

function stamp() {
  return new Date().toISOString().replace(/[:.]/g, "-").replace(/Z$/, "Z");
}

// Synchronous wait: the whole worker is a straight-line spawnSync procedure, and
// introducing an async tick here would change the shape of every caller above it.
function sleepMs(ms) {
  if (!(ms > 0)) return;
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function firstLine(text) {
  return String(text === null || text === undefined ? "" : text)
    .split(/\r?\n/)
    .find((l) => l.trim() !== "") || "";
}

// --- env resolution --------------------------------------------------------

function homeDir() {
  return process.env.HOME || process.env.USERPROFILE || "";
}

// Each of the five is resolved to a concrete value here — never read from
// process.env — with the documented default computed when no source names one.
//
// WHICH SIDE WINS. The three vars that name a session or a checkout come from
// the validated payload and the resolved anchors ONLY — the same rule spawn.js
// applies to AGENTS_CONFIG_DIR. An inherited WORKFLOW_SESSION_ID or
// CLAUDE_PROJECT_DIR from a stale or poisoned parent env would otherwise
// out-rank the payload and point the gate at another session's step statuses or
// another checkout's staged changes, i.e. redirect the verdict away from the
// work actually being committed.
//
// The other two — CLAUDE_WORKFLOW_DIR and DEFAULT_BRANCHES — have no payload or
// anchor counterpart, so they are read from the `.env` at the ACD ANCHOR via
// hooks/lib/load-env.js's readEnvFile(), which is pure and never consults
// process.env. That file is the reviewed main checkout resolved from this
// module's own realpath (see anchor.js resolveAcd, which drops the env
// candidate for the same reason), so neither value is forgeable by an inline
// `VAR=x node bin/...` prefix or by a poisoned parent env. Both are decisions a
// gate depends on: CLAUDE_WORKFLOW_DIR names the state root the gate reads its
// step statuses from — a planted directory holding a fabricated state file
// makes it approve — and DEFAULT_BRANCHES is the protected-branch set that arms
// both isProtectedBranch() below and merge-detect.js's own getProtectedBranches()
// in the gate child, so a list omitting main/master disarms the merge gate.
//
// readEnvFile returns null when the file is missing or unreadable; that is
// treated exactly like an empty map, and the documented defaults apply.
// getWorkflowDir()'s own fallback is <HOME>/.claude/projects/workflow, so the
// default below resolves to the same directory the gate child would compute for
// itself.
function resolveGateEnv(payload, ctx) {
  const cfg = readEnvFile(path.join(ctx.anchors.acd, ".env")) || {};
  return {
    CLAUDE_WORKFLOW_DIR:
      cfg.CLAUDE_WORKFLOW_DIR || path.join(homeDir(), ".claude", "projects", "workflow"),
    WORKFLOW_PLANS_DIR: ctx.anchors.plansDir,
    WORKFLOW_SESSION_ID: payload.session_id,
    CLAUDE_PROJECT_DIR: payload.worktree_path,
    DEFAULT_BRANCHES: cfg.DEFAULT_BRANCHES || DEFAULT_PROTECTED_BRANCHES,
  };
}

// Same set merge-detect.js derives from DEFAULT_BRANCHES, computed from the value
// this worker actually hands the gate child so the two cannot disagree.
function isProtectedBranch(branch, defaultBranches) {
  const list = String(defaultBranches || "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  return (list.length ? list : ["main", "master"]).includes(branch);
}

// --- child process helpers -------------------------------------------------

// `input`, when given, is written to the child's stdin. It is the only channel
// payload-derived free text takes (see spawn.js): text sent this way never
// reaches an argv, a process-table entry, or the gate's command string.
function runGit(ctx, payload, args, log, input) {
  let res = null;
  try {
    const opts = {
      anchors: ctx.anchors,
      command: "git",
      args,
      cwd: payload.worktree_path,
      timeoutMs: GIT_TIMEOUT_MS,
    };
    if (input !== undefined) opts.input = input;
    res = spawnRun(ctx.entry, opts);
  } catch (e) {
    log.push(`git ${args.join(" ")} could not start: ${e && e.message ? e.message : "unknown"}`);
    return null;
  }
  log.push(`$ git ${args.join(" ")} -> status=${res.status}`, res.stdout, res.stderr);
  return res;
}

function runScript(ctx, payload, scriptKey, args, log) {
  let res = null;
  try {
    res = spawnRun(ctx.entry, {
      anchors: ctx.anchors,
      command: "bash",
      script: scriptKey,
      args,
      cwd: payload.worktree_path,
      timeoutMs: SCRIPT_TIMEOUT_MS,
    });
  } catch (e) {
    log.push(`${scriptKey} could not start: ${e && e.message ? e.message : "unknown"}`);
    return null;
  }
  log.push(`$ ${scriptKey} ${args.join(" ")} -> status=${res.status}`, res.stdout, res.stderr);
  return res;
}

// D1. `gitArgs` is the SAME array the caller is about to spawn — the command
// string the gate is asked about is derived from it rather than written twice.
// Returns { ok } | { ok:false, reason, degraded }.
function runGate(ctx, payload, gateEnv, gitArgs, log) {
  const command = ["git"].concat(gitArgs).join(" ");
  const input = JSON.stringify({
    tool_name: "Bash",
    tool_input: { command, cwd: payload.worktree_path },
    session_id: payload.session_id,
  });

  let res = null;
  try {
    res = spawnRun(ctx.entry, {
      anchors: ctx.anchors,
      command: "node",
      script: "workflowGate",
      args: [],
      cwd: payload.worktree_path,
      timeoutMs: GATE_TIMEOUT_MS,
      extraEnv: {
        CLAUDE_WORKFLOW_DIR: gateEnv.CLAUDE_WORKFLOW_DIR,
        WORKFLOW_PLANS_DIR: gateEnv.WORKFLOW_PLANS_DIR,
        WORKFLOW_SESSION_ID: gateEnv.WORKFLOW_SESSION_ID,
        CLAUDE_PROJECT_DIR: gateEnv.CLAUDE_PROJECT_DIR,
        DEFAULT_BRANCHES: gateEnv.DEFAULT_BRANCHES,
      },
      input,
    });
  } catch (e) {
    return {
      ok: false,
      degraded: true,
      reason: `workflow-gate could not start: ${e && e.message ? e.message : "unknown error"}`,
    };
  }
  log.push(`$ workflow-gate <- ${command} -> status=${res.status}`, res.stdout, res.stderr);

  if (res.spawnError !== null) {
    return { ok: false, degraded: true, reason: `workflow-gate failed to run: ${res.spawnError}` };
  }
  if (res.timedOut) {
    return { ok: false, degraded: true, reason: "workflow-gate timed out" };
  }
  // hooks/workflow-gate.js prints its verdict and always exits 0. A non-zero
  // exit therefore means it died before deciding — silence, not permission.
  if (res.status !== 0) {
    return {
      ok: false,
      degraded: true,
      reason: `workflow-gate exited ${res.status} without a verdict`,
    };
  }
  let verdict = null;
  try {
    verdict = JSON.parse(String(res.stdout || "").trim());
  } catch (_e) {
    verdict = null;
  }
  if (verdict === null || typeof verdict !== "object" || typeof verdict.decision !== "string") {
    return { ok: false, degraded: true, reason: "workflow-gate returned an unparsable verdict" };
  }
  if (verdict.decision === "block") {
    return { ok: false, degraded: false, reason: firstLine(verdict.reason) || "blocked by workflow-gate" };
  }
  // Permission is exactly one token. "deny", "ask", a typo, or a decision this
  // worker predates are all treated as refusals: an allowlist of one cannot be
  // widened by anything the gate learns to say later.
  if (verdict.decision !== GATE_APPROVE) {
    return {
      ok: false,
      degraded: true,
      reason: `workflow-gate returned an unrecognized decision: ${firstLine(verdict.decision)}`,
    };
  }
  return { ok: true };
}

// --- the procedure ---------------------------------------------------------

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
  // Nothing downstream re-derives it: the upstream probe, the push refspec, the
  // protected-branch test and `gh pr create --head` all take the payload's word
  // for it. A stale or crafted payload would otherwise commit and push THIS
  // worktree's staged changes under another branch's name, or claim a safe name
  // while the checkout is on main and walk past isProtectedBranch() entirely.
  // A probe that cannot answer is a mismatch, not a pass: this runs before the
  // first mutation, so failing closed costs nothing.
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
  // `-c workflow.wip=1` must precede the subcommand: git ignores it afterwards,
  // and workflow-gate.js only recognizes the pre-subcommand form.
  //
  // `-F -` rather than `-m <message>`: the gate is asked about the joined argv,
  // and hooks/workflow-gate/repo-resolution.js scans that whole string for a
  // `git -C <path>` anywhere in it. A commit message is author-controlled free
  // text, so `-m` would let the message body dictate which repository the gate
  // inspects — and a repo outside the session's own resolves to "approve".
  // Keeping the message off the command line entirely closes that, and the
  // message no longer appears in the process table either. It travels on stdin.
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
  const probe = runScript(ctx, payload, "bootstrapProbe", [payload.worktree_path], log);
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

// Step 7. Returns { status: "ok" } or a terminal { status, summary }.
// No force flag is ever assembled — not `--force`, not `--force-with-lease`.
function pushToRemote(ctx, payload, branch, pushArgs, log) {
  let last = "";
  for (let attempt = 1; attempt <= PUSH_ATTEMPTS; attempt += 1) {
    sleepMs(RETRY_WAIT_MS[attempt - 1]);

    const res = runGit(ctx, payload, pushArgs, log);
    if (res !== null && res.status === 0) return { status: "ok" };
    last = res === null ? "git push could not start" : firstLine(res.stderr) || `exit ${res.status}`;
    if (res === null) break;

    const text = `${res.stdout || ""}\n${res.stderr || ""}`;
    const nonFastForward = /non-fast-forward|rejected|fetch first|behind/i.test(text);
    if (!nonFastForward || attempt === PUSH_ATTEMPTS) continue;

    // Rebase ladder: fetch, replay this branch on top, then retry the SAME
    // explicit push. `--autostash` keeps an unrelated dirty worktree out of it.
    runGit(ctx, payload, ["fetch", "origin", branch], log);
    const rebase = runGit(ctx, payload, ["pull", "--rebase", "--autostash", "origin", branch], log);
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
        summary: `pull --rebase failed before retry: ${firstLine(detail) || "unknown error"}`,
      };
    }
  }
  return {
    status: "push_failed",
    summary: `push to origin/${branch} failed after ${PUSH_ATTEMPTS} attempts: ${last}`,
  };
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

module.exports = { run, resolveGateEnv, isProtectedBranch, pushToRemote };
