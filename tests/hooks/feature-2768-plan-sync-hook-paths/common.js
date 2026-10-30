"use strict";
// Part of tests/hooks/feature-2768-plan-sync-hook-{paths,diff,fallback}.js: drives show-plan-link.js
// with hand-built PostToolUse inputs and renders the expected no-diff plan-link block.

const path = require("node:path");

const DUTY_TEXT = "Show the turn diff line above once in this summary, placed before the [plan-link] line(s) so they " +
  "still end the text block as required; do not repeat it in later turns.";
const DIFF_HEAD = "\n\n[plan-sync] turn diff";

// hook(F, repo, tool, toolInput, {sid}) -> show-plan-link output for one hand-built tool call. No
// transcript_path: under A-pure the turn comes from the UserPromptSubmit record alone.
function hook(F, repo, tool, toolInput, o) {
  const input = { tool_name: tool, tool_input: toolInput, tool_response: tool === "Bash" ? { stdout: "", stderr: "", interrupted: false } : { success: true },
    session_id: o.sid, cwd: F.project(repo.host), hook_event_name: "PostToolUse" };
  const res = F.runNode("hooks/show-plan-link.js", input, { env: { WORKFLOW_PLANS_DIR: repo.dir, PLAN_SYNC_REMOTE_URL: repo.url,
    GIT_SSH_STUB_BARE: repo.bare } });
  const hso = (res.json && res.json.hookSpecificOutput) || {};
  return Object.assign(res, { ctx: hso.additionalContext || "", msg: (res.json && res.json.systemMessage) || "" });
}
const progressName = (sid) => `${sid}-session-progress.md`;
const editProgress = (F, repo, sid) => hook(F, repo, "Edit", { file_path: F.absOf(repo, progressName(sid)), old_string: "a", new_string: "b" },
  { sid });
const assembleCmd = (F, repo, rel) => `bash skills/_shared/assemble-mandatory.sh /tmp/src.md /tmp/planner.md ${F.slash(F.absOf(repo, rel))}`;
function learn(F, repo) {
  F.git(repo.dir, ["config", "--local", "plansync.remoteStateUrl", F.config(repo.dir, "remote.origin.url")]);
  F.git(repo.dir, ["config", "--local", "plansync.forceRejected", "true"]);
}
// expectedHead(F, repo, rel) -> the plan-link block exactly as the hook renders it without a turn diff.
function expectedHead(F, repo, rel) {
  const PL = require(path.join(F.ROOT, "hooks", "lib", "plan-link"));
  const { planGateState } = require(path.join(F.ROOT, "hooks", "lib", "confirm-gate", "plan-gate"));
  const entry = { stage: "intent", url: F.blobUrl(rel), path: path.resolve(F.absOf(repo, rel)), gate: planGateState("intent", { timeoutMs: 5000 }) };
  return PL.renderModelContext([entry], { when: "after-write" });
}
// multiWrite(F, repo, rels, {sid}) -> one editFiles call naming every rel (per-entry file_path in edits[]).
const multiWrite = (F, repo, rels, o) => hook(F, repo, "editFiles",
  { edits: rels.map((rel) => ({ file_path: F.absOf(repo, rel), old_string: "x", new_string: "y" })) }, o);

module.exports = { DUTY_TEXT, DIFF_HEAD, hook, progressName, editProgress, assembleCmd, learn, expectedHead, multiWrite };
