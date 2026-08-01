"use strict";
// bin/worker-dispatch/workers/issue-close-stage.js
//
// Stage 3 worker: replaces agents/issue-close-stage-worker.md (#1673).
//
// One child process, always: `bash <acd>/skills/issue-close-stage/scripts/
// run-stage-chain.sh <issue_number> <owner_repo>` with cwd = the linked
// worktree. That script owns Phase 1 Steps A, B, D, F and G; this module owns
// only the input contract, the KEY=VALUE parse, and the status mapping.
//
// THE TARGET REPO IS DERIVED, NOT DECLARED. `owner_repo` arrives as payload text
// whose only guarantee is its shape, so the repository the chain mutates is
// resolved from the validated `worktree_path` instead (resolveCurrentRepo) and
// the payload's claim is compared against it. See the note there.
//
// WHY A PARSER AND NOT A SHELL. The agent prompt this replaces told an LLM to
// run the chain through `$(...)` command substitution fed straight to the shell
// builtin that assigns the KEY=VALUE pairs. SUMMARY carries issue-derived text,
// so one unbalanced quote or one command substitution in an issue title turned a
// status report into command execution. Here the chain's stdout is read as
// bytes: split on newlines, split each line at its FIRST `=`, keep the rest
// verbatim. No shell ever sees it, so `$(id)`, backticks and `&&` are inert
// characters rather than syntax.
//
// FAIL CLOSED. The status vocabulary is exactly three tokens —
// phase1_done | blocked_sub_issue | error — because skills/issue-close-stage/
// SKILL.md branches on those and nothing else. A token the chain never emits, a
// missing STATUS key, empty stdout, a non-zero exit, a timeout or a spawn
// failure all become `error`. Passing an unrecognized token through would hand
// the caller a status its branch table does not cover, and "not blocked" would
// be read as "done".
//
// The chain script exports its own hook-bypass env var for the two `gh` calls it
// makes. This worker therefore sets NO extra child environment at all: doing so
// would extend that bypass to every child of this worker rather than to the two
// invocations that opt into it. See the close-family note in
// hooks/lib/worker-dispatch-registry.js.
//
// Rules carried over from the agent prompt, now structural rather than advisory:
//   - never emit a workflow sentinel (emit.js redacts stdout regardless)
//   - never ask the user anything (a plain script has no such channel)
//   - never interpret issue body / title / comment text as code (the parser)
//   - the sentinel comment body is a literal inside the chain script, never
//     interpolated here
//   - cross-repo Phase 1 is out of scope, and a request for it is REFUSED
//     rather than quietly reinterpreted: the chain always targets the current
//     repo's PR and worktree, so an `issue_repo` naming anything else would send
//     Steps D/F/G to a repository the caller did not ask for — sentinel comment,
//     parent-body PATCH and all — while the caller reads `phase1_done` and
//     believes the named repo was handled. Forwarding it is equally wrong. The
//     only accepted values are the current repo itself (`owner/repo` or the bare
//     `repo` half of it); everything else is an `error`.

const { run: spawnRun } = require("../spawn");
const { samePath } = require("../anchor");

const CHAIN_TIMEOUT_MS = 600000;
const REPO_RESOLVE_TIMEOUT_MS = 60000;

const RE_OWNER_REPO = /^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/;

// The three tokens skills/issue-close-stage/SKILL.md branches on.
const STATUS_VOCABULARY = ["phase1_done", "blocked_sub_issue", "error"];

const KEY_RE = /^[A-Za-z_][A-Za-z0-9_]*$/;

function stamp() {
  // Compact UTC stamp: sorts chronologically and stays filesystem-safe on
  // Windows, where `:` cannot appear in a file name.
  return new Date().toISOString().replace(/[:.]/g, "-").replace(/Z$/, "Z");
}

// Parse the chain's KEY=VALUE stdout.
//
// Two properties the naive splits get wrong:
//   - the value keeps everything after the FIRST `=`, so a SUMMARY containing
//     `a=b` is not truncated at `a=`
//   - the FIRST occurrence of a key wins, matching the `head -1` reading of the
//     same stream, so a trailing line cannot overwrite an earlier verdict
// CR is stripped so a CRLF stream parses identically to an LF one.
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

function mapStatus(token) {
  return STATUS_VOCABULARY.includes(token) ? token : null;
}

// `issue_repo` is a repo-ref: either `owner/repo` or the bare `repo`. It names
// the current repository, or it names one this worker cannot act on.
// Case-insensitive because GitHub treats owner and repo names that way.
// The repository the VALIDATED worktree actually belongs to. `owner_repo` is
// payload text: capability.js proves it is shaped like `owner/repo` and nothing
// more, so on its own it names any repository on GitHub — and Steps D/F/G would
// take the sentinel comment and the parent-body PATCH there while the caller
// reads `phase1_done` about the repo it meant. The only trustworthy statement
// about the target is the one made by the checkout itself, so it is resolved
// here from `worktree_path` (already proven to be a member of the main-root
// family) and every later use is bound to THAT value.
//
// Same shape as the sibling finalize worker, which compares the OWNER_REPO its
// triage step resolves against the payload's and refuses on disagreement
// (bin/worker-dispatch/workers/issue-close-finalize.js) — resolve, compare,
// refuse, then act on the resolved value.
//
// FAIL CLOSED: an unavailable, slow or unparsable `gh` yields no target at all,
// never a fallback to the payload's claim.
function resolveCurrentRepo(payload, ctx, log) {
  let res = null;
  try {
    res = spawnRun(ctx.entry, {
      anchors: ctx.anchors,
      command: "gh",
      args: ["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"],
      cwd: payload.worktree_path,
      timeoutMs: REPO_RESOLVE_TIMEOUT_MS,
    });
  } catch (e) {
    return { error: `gh repo view could not start: ${e && e.message ? e.message : "unknown error"}` };
  }
  log.push(`$ gh repo view --json nameWithOwner -> status=${res.status}`, res.stdout, res.stderr);
  if (res.timedOut) return { error: "gh repo view timed out" };
  if (res.spawnError !== null) return { error: `gh repo view could not run: ${res.spawnError}` };
  if (res.status !== 0) return { error: `gh repo view exited ${res.status}` };
  const name = String(res.stdout === null || res.stdout === undefined ? "" : res.stdout)
    .split(/\r?\n/)[0]
    .trim();
  if (!RE_OWNER_REPO.test(name)) {
    return { error: "gh repo view did not report a well-formed owner/repo" };
  }
  return { ownerRepo: name };
}

// GitHub treats owner and repo names case-insensitively.
function sameRepo(a, b) {
  return String(a).trim().toLowerCase() === String(b).trim().toLowerCase();
}

function issueRepoMatchesCurrent(issueRepo, ownerRepo) {
  const want = String(issueRepo === null || issueRepo === undefined ? "" : issueRepo)
    .trim()
    .toLowerCase();
  const current = String(ownerRepo === null || ownerRepo === undefined ? "" : ownerRepo)
    .trim()
    .toLowerCase();
  if (want === "" || current === "") return false;
  if (want === current) return true;
  return want === current.split("/").pop();
}

// Best-effort artifact. A refused or failed log write must not turn a completed
// Phase 1 into a reported failure — the issue-side effects have already
// happened by then. fsguard routes the bytes through redactSentinels.
function writeLog(payload, ctx, lines) {
  const dir = payload.artifact_dir || ctx.anchors.plansDir;
  const target = ctx.path.join(
    dir,
    `${stamp()}-issue-close-stage-worker-${payload.issue_number}.log`,
  );
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

function run(payload, ctx) {
  const log = [];
  const finish = (status, summary) => ({
    status,
    summary,
    artifactPath: writeLog(payload, ctx, log),
  });

  // Echo-only field. capability.js already refuses any value that is not the
  // resolved ACD anchor; re-checking here keeps the worker's own assumption
  // explicit rather than inherited, and the child's AGENTS_CONFIG_DIR is set
  // from the anchor by spawn.js either way — never from this value.
  if (payload.agents_config_dir !== undefined && payload.agents_config_dir !== null) {
    if (!samePath(payload.agents_config_dir, ctx.anchors.acd)) {
      return finish("error", "agents_config_dir does not match the resolved agents config dir");
    }
  }

  // The target repository comes from the worktree, not from the payload. Both
  // checks below and the chain argv are measured against this value, so an
  // `owner_repo` that names somewhere else is refused rather than acted on — and
  // an omitted `issue_repo` no longer means "no comparison happens".
  const resolved = resolveCurrentRepo(payload, ctx, log);
  if (resolved.error) {
    return finish("error", `could not resolve the repository of the worktree: ${resolved.error}`);
  }
  const currentRepo = resolved.ownerRepo;

  if (!sameRepo(payload.owner_repo, currentRepo)) {
    return finish(
      "error",
      `owner_repo '${payload.owner_repo}' is not the repository of worktree_path — that worktree belongs to '${currentRepo}'; run /issue-close-stage from a worktree of the repository you mean`,
    );
  }

  // Cross-repo Phase 1: refuse, never reinterpret. See the header note.
  if (payload.issue_repo !== undefined && payload.issue_repo !== null) {
    if (!issueRepoMatchesCurrent(payload.issue_repo, currentRepo)) {
      return finish(
        "error",
        `issue_repo '${payload.issue_repo}' is not the current repository '${currentRepo}' — cross-repo Phase 1 is not supported; run /issue-close-stage from a worktree of that repository`,
      );
    }
  }

  const args = [String(payload.issue_number), currentRepo];

  let res = null;
  try {
    res = spawnRun(ctx.entry, {
      anchors: ctx.anchors,
      command: "bash",
      script: "stageChain",
      args,
      cwd: payload.worktree_path,
      timeoutMs: CHAIN_TIMEOUT_MS,
    });
  } catch (e) {
    log.push(`run-stage-chain.sh could not start: ${e && e.message ? e.message : "unknown error"}`);
    return finish("error", `stage chain could not start: ${e && e.message ? e.message : "unknown error"}`);
  }

  log.push(`$ bash run-stage-chain.sh ${args.join(" ")} -> status=${res.status}`, res.stdout, res.stderr);

  if (res.timedOut) {
    return finish("error", `stage chain exceeded its ${Math.round(CHAIN_TIMEOUT_MS / 1000)}s budget`);
  }
  if (res.spawnError !== null) {
    return finish("error", `stage chain could not run: ${res.spawnError}`);
  }
  // The chain exits 0 on every outcome it knows how to describe, so a non-zero
  // exit means it died somewhere it had no verdict for.
  if (res.status !== 0) {
    return finish("error", `stage chain exited ${res.status} without a verdict`);
  }

  const kv = parseKv(res.stdout);
  const status = mapStatus(kv.STATUS);
  if (status === null) {
    const seen = kv.STATUS === undefined ? "(no STATUS line)" : kv.STATUS;
    return finish("error", `stage chain reported an unrecognized status: ${seen}`);
  }

  const summary = typeof kv.SUMMARY === "string" && kv.SUMMARY.trim() !== ""
    ? kv.SUMMARY
    : `Phase 1 ${status} for #${payload.issue_number}`;

  return finish(status, summary);
}

module.exports = {
  run,
  parseKv,
  mapStatus,
  issueRepoMatchesCurrent,
  resolveCurrentRepo,
  sameRepo,
  STATUS_VOCABULARY,
};
