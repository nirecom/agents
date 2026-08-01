"use strict";
// bin/worker-dispatch/workers/issue-close-finalize.js
//
// Stage 4 worker: replaces agents/issue-close-finalize-worker.md (#1673).
//
// ONE DISPATCH ADVANCES EXACTLY ONE PASS. The dispatcher is a fresh process per
// invocation and holds no memory; `phase` says which pass this is, and the
// durable state file under the plans directory is the only thing connecting
// them. That is the whole design, and the regulatory rules the agent prompt used
// to state in prose are structural consequences of it:
//
//   - NO RECURSION. The G.5 loop is owned by the calling main context, which
//     re-dispatches with the next `g5_decision`. This module never loops and
//     never re-enters itself. A worker that recursed would make the state file
//     unobservable between iterations and put an unbounded chain of `gh` calls
//     behind a single approval.
//   - NEVER ASK THE USER. AskUserQuestion belongs to the calling skill. A
//     dispatched process has no such channel, so the decision arrives as the
//     typed `g5_decision` field instead — accept | decline | llm_declined |
//     recurse_done, and nothing else.
//   - NEVER EMIT A WORKFLOW SENTINEL. emit.js is the only writer to stdout and
//     redacts sentinel-shaped bytes regardless of what a child printed.
//   - NEVER EVAL AN ISSUE BODY. Child stdout is parsed as KEY=VALUE bytes by
//     parseKv — split at the FIRST `=`, first key wins. No shell, no eval, no
//     Function constructor. Issue titles and bodies routinely contain `$(...)`,
//     backticks and quotes; here they are inert characters.
//   - G.5-3a IDEMPOTENCY. `g5_history[].g5_3a_completed` is the guard flag that
//     stops the proposal comment from being posted twice when a pass is retried.
//     It lives in the state file and is written by run-loop-step.js; this module
//     validates it but never clears it.
//
// ENVIRONMENT IS RESOLVED, NEVER INHERITED. Every child's extra environment is
// built here from the trust anchors (ACD, MAIN_ROOT) rather than read from
// process.env. `envPassthrough` in the registry describes what MAY reach a
// child, not what SHOULD; relying on inheritance would make the child's
// behaviour depend on the ambient environment of whoever launched the session.
// spawn.js sets AGENTS_CONFIG_DIR itself from the ACD anchor, so it is
// deliberately absent from every extraEnv object below.
//
// ISSUE_CLOSE_SKILL — the hook-bypass env var that lets `gh issue close`
// through — is NOT set here, is not in envPassthrough, and must never be added
// to either. run-finalize-terminal.sh exports it around its own two `gh` calls.
// Setting it at this level would extend the bypass to every child of every phase
// instead of to the invocations that opt into it.
//
// THE COMPARE-AND-SWAP TOKEN CROSSES EVERY PROCESS BOUNDARY. Both non-initial
// passes validate the state file here and then hand the resulting token to the
// child that re-reads the same file — run-loop-step.js on argv 3,
// run-finalize-terminal.sh on argv 4. Neither child acts on content whose digest
// disagrees with that token, so this module's validation binds what the child
// actually reads and not merely what this process happened to see. Validating in
// one process and consuming in another without the token would leave the whole
// state-file wall bypassable by a replacement written in between.

const stateStore = require("./issue-close-finalize/state");
const { run: spawnRun } = require("../spawn");
const { samePath } = require("../anchor");

const INITIAL_TIMEOUT_MS = 600000;
const LOOP_TIMEOUT_MS = 600000;
const TERMINAL_TIMEOUT_MS = 600000;

// What the calling skill branches on. `complete` is this worker's own token for
// "the terminal script finished"; the scripts themselves say STATUS=terminal.
const STATUS_VOCABULARY = [
  "init_done",
  "awaiting_recursion",
  "terminal",
  "complete",
  "failed",
];

const LOOP_STATUSES = ["init_done", "awaiting_recursion", "terminal", "failed"];

const KEY_RE = /^[A-Za-z_][A-Za-z0-9_]*$/;

const REQUIRED_BY_PHASE = {
  initial: [
    "issue_number",
    "root_issue_number",
    "owner_repo",
    "state_file_path",
    "main_worktree_path",
  ],
  loop_step: ["root_issue_number", "owner_repo", "state_file_path", "g5_decision"],
  finalize_terminal: [
    "root_issue_number",
    "owner_repo",
    "state_file_path",
    "session_id",
    "outcome_file_path",
  ],
};

function stamp() {
  return new Date().toISOString().replace(/[:.]/g, "-").replace(/Z$/, "Z");
}

// See the header note on eval. Value keeps everything after the first `=`, so a
// SUMMARY containing `a=b` is not truncated; first key wins, matching a
// `head -1` reading of the same stream, so a trailing line cannot overwrite an
// earlier verdict. CR is stripped so CRLF parses identically to LF.
function parseKv(text) {
  const out = {};
  const lines = String(text === null || text === undefined ? "" : text).split(/\r?\n/);
  for (const line of lines) {
    const at = line.indexOf("=");
    if (at <= 0) continue;
    const key = line.slice(0, at);
    if (!KEY_RE.test(key)) continue;
    if (Object.prototype.hasOwnProperty.call(out, key)) continue;
    out[key] = line.slice(at + 1);
  }
  return out;
}

function mapStatus(token, allowed) {
  return allowed.includes(token) ? token : null;
}

function checkRequired(payload, phase) {
  for (const field of REQUIRED_BY_PHASE[phase]) {
    const v = payload[field];
    if (v === undefined || v === null || v === "") {
      return `phase=${phase} requires '${field}'`;
    }
  }
  return null;
}

// Best-effort artifact. The file name is prefixed with the session id so the
// plans directory stays partitioned by session — TL3 asserts that nothing in it
// belongs to a session other than the one under test.
function writeLog(payload, ctx, lines) {
  const dir = payload.artifact_dir || ctx.anchors.plansDir;
  const sid = typeof payload.session_id === "string" && payload.session_id !== ""
    ? payload.session_id
    : "no-session";
  const target = ctx.path.join(dir, `${sid}-finalize-worker-${stamp()}.log`);
  const body = lines
    .map((l) => String(l === null || l === undefined ? "" : l))
    .filter((l) => l !== "")
    .join("\n");
  try {
    return ctx.fsguard.writeFile(target, `${body}\n`);
  } catch (_e) {
    return "(none)";
  }
}

// The finalize chain scripts are found from the ACD anchor, never from an
// ambient FINALIZE_SCRIPTS_DIR. capability.js derives the same value for the
// `derived-finalize-scripts-dir` field; recomputing it from the anchor keeps
// this module's assumption explicit rather than inherited.
function finalizeScriptsDir(ctx) {
  return ctx.path.join(ctx.anchors.acd, "skills", "issue-close-finalize", "scripts");
}

function spawnChild(ctx, opts, log) {
  let res = null;
  try {
    res = spawnRun(ctx.entry, opts);
  } catch (e) {
    const msg = e && e.message ? e.message : "unknown error";
    log.push(`${opts.script} could not start: ${msg}`);
    return { error: `${opts.script} could not start: ${msg}` };
  }
  log.push(
    `$ ${opts.command} ${opts.script} ${opts.args.join(" ")} -> status=${res.status}`,
    res.stdout,
    res.stderr,
  );
  if (res.timedOut) return { error: `${opts.script} exceeded its ${Math.round(opts.timeoutMs / 1000)}s budget` };
  if (res.spawnError !== null) return { error: `${opts.script} could not run: ${res.spawnError}` };
  // Every chain script exits 0 for each outcome it can describe, so a non-zero
  // exit means it died somewhere it had no verdict for.
  if (res.status !== 0) return { error: `${opts.script} exited ${res.status} without a verdict` };
  return { kv: parseKv(res.stdout) };
}

function buildInitialState(payload, ctx, kv) {
  const state = {
    schema_version: stateStore.SCHEMA_VERSION,
    root_issue_number: Number(payload.root_issue_number),
    current_issue_number: Number(payload.issue_number),
  };
  if (typeof payload.issue_repo === "string" && payload.issue_repo !== "") {
    state.issue_repo = payload.issue_repo;
  }
  state.owner_repo = kv.OWNER_REPO;
  state.agents_config_dir = ctx.anchors.acd;
  state.main_worktree_path = ctx.anchors.mainRoot;
  state.merge_commit = typeof kv.MERGE_COMMIT === "string" ? kv.MERGE_COMMIT.trim() : "";
  state.phase = "init_done";
  state.triage_action = typeof kv.TRIAGE_ACTION === "string" ? kv.TRIAGE_ACTION.trim() : "";
  state.g5_loop_iteration = 0;

  // A meta parent with open sub-issues never enters the G.5 loop, so it gets no
  // history array at all. Seeding an empty one would make "the loop ran and
  // produced nothing" indistinguishable from "the loop never applied".
  if (state.triage_action !== "meta_pending_subs") {
    const parentRaw = typeof kv.PROPOSAL_PARENT === "string" ? kv.PROPOSAL_PARENT.trim() : "";
    const parent = /^[0-9]{1,12}$/.test(parentRaw) ? Number(parentRaw) : null;
    const proposalStatus = typeof kv.PROPOSAL_STATUS === "string" ? kv.PROPOSAL_STATUS.trim() : "";
    state.g5_history = [
      {
        iteration: 0,
        issue_number: String(payload.issue_number),
        proposal_status: ["ok", "skipped", "none"].includes(proposalStatus) ? proposalStatus : "none",
        proposal_parent: parent,
        user_decision: null,
        g5_3a_completed: false,
        recursion_completed: false,
      },
    ];
  }
  state.proposal_counters = { accepted: 0, declined: 0, skipped: 0 };
  return state;
}

function runInitial(payload, ctx, log, finish) {
  const missing = checkRequired(payload, "initial");
  if (missing) return finish("failed", missing);

  // FIRST WRITE WINS, checked BEFORE the spawn. run-initial.sh updates parent
  // issue bodies and runs the G.5 prepare step — external mutations no later
  // refusal can undo. Leaving the only existence check inside writeInitial()
  // meant a re-dispatch of an already-initialized chain performed all of them and
  // was told "refusing to overwrite" afterwards. writeInitial() still re-checks
  // under its own lock; this one exists so the common case never pays for it.
  if (stateStore.alreadyInitialized(payload)) {
    return finish("failed", stateStore.ALREADY_INITIALIZED);
  }

  const args = [String(payload.issue_number), String(payload.root_issue_number)];
  if (typeof payload.issue_repo === "string" && payload.issue_repo !== "") {
    args.push(payload.issue_repo);
  }

  const out = spawnChild(
    ctx,
    {
      anchors: ctx.anchors,
      command: "bash",
      script: "runInitial",
      args,
      cwd: payload.main_worktree_path,
      timeoutMs: INITIAL_TIMEOUT_MS,
      extraEnv: {
        FINALIZE_SCRIPTS_DIR: finalizeScriptsDir(ctx),
        MAIN_WORKTREE_PATH: ctx.anchors.mainRoot,
      },
    },
    log,
  );
  if (out.error) return finish("failed", out.error);

  const kv = out.kv;
  const summary = typeof kv.SUMMARY === "string" && kv.SUMMARY.trim() !== ""
    ? kv.SUMMARY
    : `initial pass for #${payload.issue_number}`;

  if (kv.STATUS !== "init_done") {
    return finish("failed", summary);
  }

  // Cross-repo mix-up detection. The triage step resolves the owning repository
  // from the issue itself; if that disagrees with what the caller believes it is
  // finalizing, the two sides are talking about different issues. Refuse BEFORE
  // any write — a state file with the wrong owner_repo would carry the mistake
  // into every subsequent pass.
  if (kv.OWNER_REPO !== payload.owner_repo) {
    return finish(
      "failed",
      `triage resolved owner_repo '${kv.OWNER_REPO}' but the payload declared '${payload.owner_repo}'`,
    );
  }

  const state = buildInitialState(payload, ctx, kv);
  let written = null;
  try {
    written = stateStore.writeInitial(payload, ctx, state);
  } catch (e) {
    return finish("failed", `state file could not be written: ${e && e.message ? e.message : "unknown error"}`);
  }
  if (written.error) return finish("failed", written.error);

  return finish("init_done", summary);
}

function runLoopStep(payload, ctx, log, finish) {
  const missing = checkRequired(payload, "loop_step");
  if (missing) return finish("failed", missing);

  const loaded = stateStore.loadValidated(payload, ctx);
  if (loaded.error) return finish("failed", loaded.error);

  // COMPARE-AND-SWAP, half 1. The bytes just validated are the token. Re-checked
  // here so a file replaced between the validation and the spawn cannot be acted
  // on with this module's approval behind it, and handed to the child so its
  // write aborts unless the file is still the one this pass validated. Two
  // concurrent passes therefore cannot both write: the second sees a changed
  // token and fails instead of overwriting the first one's result.
  const conflict = stateStore.checkToken(payload.state_file_path, loaded.token);
  if (conflict) return finish("failed", conflict);

  // run-loop-step.js owns every state mutation from here on and writes the file
  // atomically itself. This module does not touch the state file after the
  // spawn: two writers would race for the same bytes.
  const out = spawnChild(
    ctx,
    {
      anchors: ctx.anchors,
      command: "node",
      script: "runLoopStep",
      args: [payload.state_file_path, payload.g5_decision, loaded.token],
      cwd: ctx.anchors.mainRoot,
      timeoutMs: LOOP_TIMEOUT_MS,
      extraEnv: {
        FINALIZE_SCRIPTS_DIR: finalizeScriptsDir(ctx),
      },
    },
    log,
  );
  if (out.error) return finish("failed", out.error);

  const kv = out.kv;
  const status = mapStatus(kv.STATUS, LOOP_STATUSES);
  const summary = typeof kv.SUMMARY === "string" && kv.SUMMARY.trim() !== ""
    ? kv.SUMMARY
    : `loop step '${payload.g5_decision}' for #${payload.root_issue_number}`;
  if (status === null) {
    const seen = kv.STATUS === undefined ? "(no STATUS line)" : kv.STATUS;
    return finish("failed", `loop step reported an unrecognized status: ${seen}`);
  }
  return finish(status, summary);
}

function runFinalizeTerminal(payload, ctx, log, finish) {
  const missing = checkRequired(payload, "finalize_terminal");
  if (missing) return finish("failed", missing);

  const loaded = stateStore.loadValidated(payload, ctx);
  if (loaded.error) return finish("failed", loaded.error);

  // Same compare-and-swap check as loop_step (CPR-5): a state file replaced
  // between validation and spawn must not be acted on. And the token TRAVELS ON,
  // exactly as it does for run-loop-step.js: the terminal script re-reads the
  // state file in its own process and drives `gh issue close` from what it finds
  // there, so a check performed only here would cover bytes that are no longer
  // the ones acted on. The protocol is the same in both languages — the sha256
  // digest of the file's raw bytes, compared before the content is used.
  const conflict = stateStore.checkToken(payload.state_file_path, loaded.token);
  if (conflict) return finish("failed", conflict);

  // No extraEnv at all: AGENTS_CONFIG_DIR comes from the ACD anchor via
  // spawn.js, and the script exports its own ISSUE_CLOSE_SKILL around the two
  // `gh` calls that need it. See the header note.
  const out = spawnChild(
    ctx,
    {
      anchors: ctx.anchors,
      command: "bash",
      script: "runTerminal",
      args: [
        payload.state_file_path,
        payload.session_id,
        payload.outcome_file_path,
        loaded.token,
      ],
      cwd: ctx.anchors.mainRoot,
      timeoutMs: TERMINAL_TIMEOUT_MS,
    },
    log,
  );
  if (out.error) return finish("failed", out.error);

  const kv = out.kv;
  const summary = typeof kv.SUMMARY === "string" && kv.SUMMARY.trim() !== ""
    ? kv.SUMMARY
    : `terminal pass for #${payload.root_issue_number}`;
  if (kv.STATUS === "terminal") return finish("complete", summary);
  return finish("failed", kv.STATUS === undefined ? "terminal pass reported no status" : summary);
}

function run(payload, ctx) {
  const log = [];
  const finish = (status, summary) => ({
    status,
    summary,
    artifactPath: writeLog(payload, ctx, log),
  });

  // Echo-only field; capability.js already refused anything but the resolved
  // ACD. Re-checked so this module's assumption is explicit rather than
  // inherited, exactly as the sibling close-family workers do.
  if (payload.agents_config_dir !== undefined && payload.agents_config_dir !== null) {
    if (!samePath(payload.agents_config_dir, ctx.anchors.acd)) {
      return finish("failed", "agents_config_dir does not match the resolved agents config dir");
    }
  }

  switch (payload.phase) {
    case "initial":
      return runInitial(payload, ctx, log, finish);
    case "loop_step":
      return runLoopStep(payload, ctx, log, finish);
    case "finalize_terminal":
      return runFinalizeTerminal(payload, ctx, log, finish);
    default:
      return finish("failed", `unsupported phase '${payload.phase}'`);
  }
}

module.exports = { run, parseKv, mapStatus, checkRequired, STATUS_VOCABULARY, REQUIRED_BY_PHASE };
