"use strict";
// bin/worker-dispatch/workers/commit-push/gate.js
//
// The D1 gate seam of the commit-push worker, plus the two child-process
// helpers every step drives its children through. Split out of the parent
// module per rules/coding/file-split.md Pattern A.
//
// What/Why — why the gate runs inside the worker at all, why the argv is
// assembled before the gate is asked, why the six env vars are resolved rather
// than inherited, and the fail-closed rule:
// docs/architecture/claude-code/worker-dispatch/commit-push.md

const path = require("path");

const { readEnvFile } = require("../../../../hooks/lib/load-env");
const { run: spawnRun } = require("../../spawn");

const GIT_TIMEOUT_MS = 300000;
const GATE_TIMEOUT_MS = 120000;
const SCRIPT_TIMEOUT_MS = 120000;

const DEFAULT_PROTECTED_BRANCHES = "main,master";

// The ONLY decision hooks/workflow-gate.js emits that means "proceed".
const GATE_APPROVE = "approve";

// The six workflow env vars the gate child is allowed to see, and the only
// names extraEnv below may set.
const GATE_ENV_SCOPE = [
  "CLAUDE_WORKFLOW_DIR",
  "WORKFLOW_PLANS_DIR",
  "WORKFLOW_SESSION_ID",
  "CLAUDE_PROJECT_DIR",
  "DEFAULT_BRANCHES",
  "ENFORCE_WORKTREE",
];

function firstLine(text) {
  return String(text === null || text === undefined ? "" : text)
    .split(/\r?\n/)
    .find((l) => l.trim() !== "") || "";
}

function homeDir() {
  return process.env.HOME || process.env.USERPROFILE || "";
}

// Each of the six is resolved to a concrete value here — never read from
// process.env — with the documented default computed when no source names one.
// The four that name a session, a checkout, or the worktree-enforcement mode
// come from the validated payload and the resolved anchors; the two with no
// such counterpart come from the `.env` at the ACD anchor via readEnvFile(),
// which never consults process.env.
// Which side wins, and what each value arms: commit-push.md "Gate env
// resolution". readEnvFile returns null for a missing or unreadable file, which
// is treated exactly like an empty map.
function resolveGateEnv(payload, ctx) {
  const cfg = readEnvFile(path.join(ctx.anchors.acd, ".env")) || {};
  return {
    CLAUDE_WORKFLOW_DIR:
      cfg.CLAUDE_WORKFLOW_DIR || path.join(homeDir(), ".claude", "projects", "workflow"),
    WORKFLOW_PLANS_DIR: ctx.anchors.plansDir,
    WORKFLOW_SESSION_ID: payload.session_id,
    CLAUDE_PROJECT_DIR: payload.worktree_path,
    DEFAULT_BRANCHES: cfg.DEFAULT_BRANCHES || DEFAULT_PROTECTED_BRANCHES,
    ENFORCE_WORKTREE: payload.enforce_worktree || "on",
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

// `input`, when given, is written to the child's stdin. It is the only channel
// payload-derived free text takes (see spawn.js): text sent this way never
// reaches an argv, a process-table entry, or the gate's command string.
//
// `envScope` defaults to the EMPTY set, not to the worker's full declared set:
// the SSH signing socket must reach only the network calls, never `git commit`
// or a repo-configured hook (core.hooksPath) a plain commit can also trigger.
function runGit(ctx, payload, args, log, input, envScope) {
  let res = null;
  try {
    const opts = {
      anchors: ctx.anchors,
      command: "git",
      args,
      cwd: payload.worktree_path,
      timeoutMs: GIT_TIMEOUT_MS,
      envScope: envScope || [],
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

function runScript(ctx, payload, scriptKey, args, log, envScope) {
  let res = null;
  try {
    res = spawnRun(ctx.entry, {
      anchors: ctx.anchors,
      command: "bash",
      script: scriptKey,
      args,
      cwd: payload.worktree_path,
      timeoutMs: SCRIPT_TIMEOUT_MS,
      envScope: envScope || [],
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
      envScope: GATE_ENV_SCOPE,
      extraEnv: {
        CLAUDE_WORKFLOW_DIR: gateEnv.CLAUDE_WORKFLOW_DIR,
        WORKFLOW_PLANS_DIR: gateEnv.WORKFLOW_PLANS_DIR,
        WORKFLOW_SESSION_ID: gateEnv.WORKFLOW_SESSION_ID,
        CLAUDE_PROJECT_DIR: gateEnv.CLAUDE_PROJECT_DIR,
        DEFAULT_BRANCHES: gateEnv.DEFAULT_BRANCHES,
        ENFORCE_WORKTREE: gateEnv.ENFORCE_WORKTREE,
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

module.exports = {
  firstLine,
  isProtectedBranch,
  resolveGateEnv,
  runGate,
  runGit,
  runScript,
  DEFAULT_PROTECTED_BRANCHES,
  GATE_APPROVE,
  GATE_TIMEOUT_MS,
  GIT_TIMEOUT_MS,
  SCRIPT_TIMEOUT_MS,
};
