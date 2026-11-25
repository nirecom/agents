"use strict";
// resolve.js — node entry to the board resolver (bin/github-issues/resolve-board.sh), synchronous.
// resolveBoard(repo, {timeoutMs, noCacheRead, spawnSync?}) -> {status, owner, number, projectId, fieldIds, candidates, reason?};
//   status is resolved | no-link | ambiguous | fetch-failed; any spawn failure, timeout or bad output is fetch-failed.
// toInternalEnv(board) -> the _ISSUE_CREATE_INTERNAL_* env that short-circuits resolve-project.sh.

const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { buildBashScriptSpawn } = require("../../workflow/lib/workflow-init/spawn-env");

const SCRIPT = path.join(__dirname, "..", "..", "github-issues", "resolve-board.sh");
const DEFAULT_TIMEOUT_MS = 30000;
const STATUSES = new Set(["resolved", "no-link", "ambiguous", "fetch-failed"]);
const FIELD_KEYS = {
  contentDateFieldId: "content_date_field_id",
  statusFieldId: "status_field_id",
  todoOptionId: "todo_option_id",
  inProgressOptionId: "in_progress_option_id",
  doneOptionId: "done_option_id",
  sessionIdFieldId: "session_id_field_id",
};

const failed = (reason) => ({ status: "fetch-failed", reason });

function parse(stdout) {
  const kv = {};
  for (const line of String(stdout || "").split(/\r?\n/)) {
    const i = line.indexOf("=");
    if (i > 0) kv[line.slice(0, i)] = line.slice(i + 1);
  }
  return kv;
}

function resolveBoard(repo, opts = {}) {
  const timeoutMs = opts.timeoutMs > 0 ? opts.timeoutMs : DEFAULT_TIMEOUT_MS;
  const args = opts.noCacheRead ? ["--no-cache-read", String(repo)] : [String(repo)];
  let r;
  try {
    const [cmd, argv, spawnOpts] = buildBashScriptSpawn(SCRIPT, args);
    const spawn = typeof opts.spawnSync === "function" ? opts.spawnSync : spawnSync;
    r = spawn(cmd, argv, Object.assign({}, spawnOpts, { timeout: timeoutMs, killSignal: "SIGKILL" }));
  } catch (e) {
    return failed(`resolver spawn threw: ${e.message}`);
  }
  if (r.error) return failed(`resolver spawn failed: ${r.error.code || r.error.message}`);
  if (r.signal) return failed(`resolver killed by ${r.signal} (timeout ${timeoutMs} ms)`);
  const stderr = String(r.stderr || "").trim().split(/\r?\n/).pop() || "";
  if (r.status !== 0) return failed(`resolver exited ${r.status}${stderr ? `: ${stderr}` : ""}`);
  const kv = parse(r.stdout);
  if (!STATUSES.has(kv.status)) return failed(`resolver printed no status line${stderr ? `: ${stderr}` : ""}`);
  const board = {
    status: kv.status,
    owner: kv.owner || "",
    number: kv.number ? Number(kv.number) : null,
    projectId: kv.project_id || "",
    fieldIds: {},
    candidates: (kv.candidates || "").split(/\s+/).filter(Boolean),
  };
  for (const [k, key] of Object.entries(FIELD_KEYS)) board.fieldIds[k] = kv[key] || "";
  if (board.status === "fetch-failed") board.reason = `board lookup failed for ${repo}${stderr ? `: ${stderr}` : ""}`;
  return board;
}

function toInternalEnv(board) {
  const f = (board && board.fieldIds) || {};
  return {
    _ISSUE_CREATE_INTERNAL_OWNER: board.owner,
    _ISSUE_CREATE_INTERNAL_PROJECT_NUM: String(board.number),
    _ISSUE_CREATE_INTERNAL_PROJECT_ID: board.projectId,
    _ISSUE_CREATE_INTERNAL_FIELD_ID: f.contentDateFieldId || "",
    _ISSUE_CREATE_INTERNAL_STATUS_FIELD_ID: f.statusFieldId || "",
    _ISSUE_CREATE_INTERNAL_TODO_OPTION_ID: f.todoOptionId || "",
    _ISSUE_CREATE_INTERNAL_IN_PROGRESS_OPTION_ID: f.inProgressOptionId || "",
    _ISSUE_CREATE_INTERNAL_DONE_OPTION_ID: f.doneOptionId || "",
    _ISSUE_CREATE_INTERNAL_SESSION_ID_FIELD_ID: f.sessionIdFieldId || "",
  };
}

module.exports = { resolveBoard, toInternalEnv };
