"use strict";
// Fixture builders for tests/hooks/feature-2304-inheritance-state-copy.js. Every path resolves
// against the dirs harness.isolate() pinned, so nothing here reaches a real state store.

const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..", "..", "..");
const mod = (rel) => require(path.join(ROOT, rel));
const S = () => mod("hooks/workflow-state/state-io");

const UP_CTX = { cwd: "/fixture/up", git_branch: "feature/up", transcript_path: "/fixture/t/up.jsonl" };

const statePath = (sid) => path.join(process.env.WORKFLOW_STATE_DIR, sid + ".json");
const raw = (sid) => JSON.parse(fs.readFileSync(statePath(sid), "utf8"));
const bytes = (sid) => (fs.existsSync(statePath(sid)) ? fs.readFileSync(statePath(sid), "utf8") : null);
const writeRaw = (sid, obj) => fs.writeFileSync(statePath(sid), JSON.stringify(obj, null, 2));
const supervisorPath = (sid) => path.join(process.env.WORKFLOW_STATE_DIR, sid + ".control", "supervisor-state.json");

function worktreeEvent(cwd, branch) {
  return {
    kind: "worktree", transition: "entered", git_branch: branch, cwd, worktree_path: cwd,
    path_source: "tool_input", provenance: "observed", origin: "enter-worktree",
  };
}

// A throwaway git repo (created once, inside the pinned state dir's parent) that the #2529
// glossary_check records bind to: R-S stages read its (empty) index.
let glossaryRepo = null;
function glossaryRepoDir() {
  if (glossaryRepo) return glossaryRepo;
  glossaryRepo = path.join(path.dirname(process.env.WORKFLOW_STATE_DIR), "glossary-repo");
  fs.mkdirSync(glossaryRepo, { recursive: true });
  require(path.join(ROOT, "tests/lib/harness")).gitInit(glossaryRepo);
  return glossaryRepo;
}

// #2529: a glossary-gated completion also needs a current glossary_check record.
function completeGated(sid, step) {
  require(path.join(ROOT, "tests/lib/glossary-check-record"))
    .completeWithRecord(sid, step, glossaryRepoDir(), (...a) => S().markStep(...a));
}

// seedUpstream(sid, opts) — a session upstream carrying a worktree entry, a gated completion with
// its approval, an annotated skip, worktree-dependent completions (one with a wsid) and session facts.
function seedUpstream(sid, opts) {
  const o = opts || {};
  const io = S();
  io.writeState(sid, io.createInitialState(sid, o.ctx || UP_CTX));
  io.appendEvents(sid, [worktreeEvent("/fixture/up-wt", "feature/up")]);
  io.markStep(sid, "workflow_init", "complete");
  require(path.join(ROOT, "tests/lib/plan-approval-fixture")).approveLive(sid, "clarify_intent");
  completeGated(sid, "clarify_intent");
  io.markStep(sid, "research", "skipped", { skip_reason: "nothing to survey" });
  io.markStep(sid, "write_tests", "complete", { wsid: "wsid-up" });
  completeGated(sid, "review_tests");
  if (o.cleanup) io.markStep(sid, "cleanup", o.cleanup);
  if (o.model) io.recordSessionModel(sid, { id: o.model, source: "transcript" });
  io.recordComplexityEvaluation(sid, ["S1-multi-file"]);
  io.setLastPushedSha(sid, "a".repeat(40));
  const st = io.readState(sid);
  st.closes_issues = [2304];
  io.writeState(sid, st);
  return raw(sid);
}

// seedDownstream(sid, ctx) — the freshly created session downstream; returns its created_at.
function seedDownstream(sid, ctx) {
  const io = S();
  io.writeState(sid, io.createInitialState(sid, ctx || UP_CTX));
  return raw(sid).created_at;
}

// seedSupervisor(sid) — a supervisor state file owned by <sid>, with non-empty sections to compare.
function seedSupervisor(sid) {
  const st = mod("hooks/lib/supervisor-state-schema").createEmptyState(sid);
  st.layer1.findings = [{ id: "f-2304", severity: "low", note: "copied verbatim" }];
  fs.mkdirSync(path.dirname(supervisorPath(sid)), { recursive: true });
  fs.writeFileSync(supervisorPath(sid), JSON.stringify(st, null, 2));
  return st;
}

// corruptSeq(sid) — leaves a seq gap in an otherwise valid stream.
function corruptSeq(sid) {
  const st = raw(sid);
  st.events[st.events.length - 1].seq += 5;
  writeRaw(sid, st);
}

const pre = (st) => st.events.filter((e) => e.seq <= st.upstream_copy_seq);
const post = (st) => st.events.filter((e) => e.seq > st.upstream_copy_seq);

module.exports = {
  ROOT, mod, S, UP_CTX, statePath, raw, bytes, writeRaw, supervisorPath,
  worktreeEvent, seedUpstream, seedDownstream, seedSupervisor, corruptSeq, pre, post,
};
