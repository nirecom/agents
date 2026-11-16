"use strict";
// Shared #3067 fixture for the tests/hooks/feature-3067-* entrypoints: a git fixture repo whose HEAD
// the approval is bound to, run_tests states seeded straight into the pinned WORKFLOW_STATE_DIR
// (pending with a classification, or already approved), and one in-process call of the
// BASELINE_UNOBSERVED_ACCEPTED handler. Call harness isolate() before requiring this module.

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { gitInit } = require("./harness");

const ROOT = path.resolve(__dirname, "..", "..");
if (!process.env.WORKFLOW_STATE_DIR || !process.env.WORKFLOW_PLANS_DIR) {
  throw new Error("baseline-unobserved-fixture: call isolate() before requiring it");
}

const SENTINEL_NAME = "WORKFLOW_RUN_TESTS_BASELINE_UNOBSERVED_ACCEPTED";
const BASIS = "baseline-unobserved-accepted";
const HANDLER = path.join(ROOT, "hooks", "workflow-mark", "run-tests-baseline-unobserved-handler.js");
const ORIGIN = "workflow-mark-run-tests-baseline-unobserved";
const sentinel = (reason) => `echo "<<${SENTINEL_NAME}: ${reason}>>"`;

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "rtb-3067-uo-"));
fs.mkdirSync(path.join(TMP, "transcripts"));
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(TMP, "transcripts");
const cleanup = () => fs.rmSync(TMP, { recursive: true, force: true });

const { appendEvents } = require(path.join(ROOT, "hooks", "workflow-state", "state-io", "events"));
const { readState } = require(path.join(ROOT, "hooks", "workflow-state"));

function git(repo, args) {
  const r = spawnSync("git", ["-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "-C", repo, ...args],
    { encoding: "utf8", timeout: 30000 });
  if (r.status !== 0) throw new Error(`git ${args.join(" ")} failed: ${r.stderr || r.error}`);
  return String(r.stdout || "").trim();
}

let serial = 0;
const sid = (label) => `uo-${label.replace(/[^A-Za-z0-9-]/g, "_")}-${process.pid}-${++serial}`;

// repo(label) — a fixture repo with one commit; returns its forward-slash path.
function repo(label) {
  const dir = path.join(TMP, `repo-${label}-${++serial}`).replace(/\\/g, "/");
  gitInit(dir);
  fs.writeFileSync(path.join(dir, "src.txt"), "0\n");
  git(dir, ["add", "src.txt"]);
  git(dir, ["commit", "-q", "-m", "init"]);
  return dir;
}
const headOf = (dir) => git(dir, ["rev-parse", "HEAD"]);

// commit(dir, file) — one more commit touching `file`; returns the new HEAD.
function commit(dir, file) {
  const p = path.join(dir, file);
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, `${Date.now()}-${++serial}\n`);
  git(dir, ["add", file]);
  git(dir, ["commit", "-q", "-m", `edit ${file}`]);
  return headOf(dir);
}

// stage(dir, file) — a staged, uncommitted change to `file` (the set the commit gate judges).
function stage(dir, file) {
  const p = path.join(dir, file);
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, `staged-${++serial}\n`);
  git(dir, ["add", file]);
}

const ann = (key, value, origin = "run-tests-hook", provenance = "observed") =>
  ({ kind: "step_annotation", step: "run_tests", key, value, provenance, origin });
const status = (s, origin = "run-tests-hook", provenance = "observed") =>
  ({ kind: "step_status", step: "run_tests", status: s, provenance, origin });

// rows are [path, class, detail]; entries carry the new_lines shape record writes.
const entriesOf = (rows) => rows.map(([p, cls, detail]) => ({ path: p, class: cls, detail, new_lines: { count: 0, head: [] } }));

// seedPending(id, o) — a failing run_tests left pending with a baseline classification.
// o: rows, failing (default: the rows' paths), unrunnable (default 0), head (omitted: legacy
// shape without head), classification:false (no classification), status (default pending).
function seedPending(id, o) {
  const failing = o.failing || o.rows.map((r) => r[0]);
  const events = [status("pending"), ann("run_outcome", "fail"), ann("failing_tests", failing),
    ann("unrunnable_count", o.unrunnable === undefined ? 0 : o.unrunnable)];
  if (o.classification !== false) {
    const value = { base: "f".repeat(40), entries: entriesOf(o.rows) };
    if (o.head !== undefined) value.head = o.head;
    events.push(ann("baseline_classification", value, "run-tests-baseline-evidence"));
  }
  if (o.status && o.status !== "pending") events.push(status(o.status, "run-tests-baseline-evidence"));
  if (o.hits !== undefined) events.push(ann("hit_count", o.hits));
  if (o.outcomeSource !== undefined) events.push(ann("outcome_source", o.outcomeSource));
  if (o.unsettledDispatch) dispatchUnsettled(id);
  appendEvents(id, events);
}

// dispatchUnsettled(id) — a test-runner dispatch marker with no .ingested beside it.
function dispatchUnsettled(id) {
  const { getSessionControlDir } = require(path.join(ROOT, "hooks", "workflow-state", "state-io", "control-dir"));
  const dir = getSessionControlDir(id);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, "worker-test-runner.dispatched"), "");
}

// nonGitDir() — a temp dir outside any git work tree: HEAD cannot be read there.
function nonGitDir() {
  const dir = fs.mkdtempSync(path.join(TMP, "nogit-")).replace(/\\/g, "/");
  const r = spawnSync("git", ["-C", dir, "rev-parse", "HEAD"], { encoding: "utf8", timeout: 30000 });
  if (r.status === 0) throw new Error(`control: git rev-parse HEAD succeeds in ${dir}`);
  return dir;
}

// seedApproved(id, o) — the state the handler leaves: complete on the new basis with its record.
// o: head, rows (approved [path, class, detail]), basis (default BASIS), accept (overrides the record).
function seedApproved(id, o) {
  const rows = o.rows || [["tests/bin/a.sh", "undetermined", "unrunnable-at-base"]];
  const accept = o.accept !== undefined ? o.accept
    : { reason: "base worktree could not start the test", head: o.head, tests: rows.map(([p, c, d]) => ({ path: p, class: c, detail: d })) };
  const events = [status("pending"), ann("run_outcome", "fail"), ann("failing_tests", rows.map((r) => r[0])),
    ann("unrunnable_count", 0),
    ann("baseline_classification", { base: "f".repeat(40), head: o.head, entries: entriesOf(rows) }, "run-tests-baseline-evidence"),
    ann("run_outcome", "pass", ORIGIN, "declared"),
    ann("completion_basis", o.basis === undefined ? BASIS : o.basis, ORIGIN, "declared")];
  if (accept !== null) events.push(ann("baseline_unobserved_accept", accept, ORIGIN, "declared"));
  events.push(status("complete", ORIGIN, "declared"));
  appendEvents(id, events);
}

// cli(args) — one run of bin/workflow/run-tests-baseline-evidence from a neutral cwd.
function cli(args) {
  const r = spawnSync(process.execPath, [path.join(ROOT, "bin", "workflow", "run-tests-baseline-evidence"), ...args],
    { cwd: TMP, encoding: "utf8", timeout: 30000 });
  return { rc: r.status, out: String(r.stdout || ""), err: String(r.stderr || "") };
}

function runTests(id) {
  const s = readState(id);
  return (s && s.steps && s.steps.run_tests) || {};
}

// handle(id, cmd, repoCwd, toolCwd) — one in-process handler call → { handled, info, unapplied }.
function handle(id, cmd, repoCwd, toolCwd) {
  const info = [];
  const unapplied = [];
  const handled = require(HANDLER).handle({
    cmd, sessionId: id, repoCwd, toolCwd,
    pushMessage: (m) => info.push(m), pushUnapplied: (m) => unapplied.push(m), signalFatal: (m) => unapplied.push(m),
  });
  return { handled, info: info.join("\n"), unapplied: unapplied.join("\n") };
}

module.exports = {
  ROOT, TMP, SENTINEL_NAME, BASIS, HANDLER, sentinel, cleanup, git, sid, repo, headOf, commit, stage,
  seedPending, seedApproved, dispatchUnsettled, nonGitDir, cli, runTests, handle, readState, appendEvents,
};
