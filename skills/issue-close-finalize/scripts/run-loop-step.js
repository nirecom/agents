#!/usr/bin/env node
"use strict";
// run-loop-step.js — phase=loop_step state mutations for issue-close-finalize-worker
// Usage: node run-loop-step.js <state_file_path> <g5_decision>
// Env:   AGENTS_CONFIG_DIR  FINALIZE_SCRIPTS_DIR
// Stdout: STATUS=<value>\nSUMMARY=<value>
// Exit 0 always; check STATUS.

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const [, , stateFilePath, g5Decision] = process.argv;
const agentsConfigDir = process.env.AGENTS_CONFIG_DIR;
const finalizeScriptsDir = process.env.FINALIZE_SCRIPTS_DIR;

function out(status, summary) {
  process.stdout.write(`STATUS=${status}\nSUMMARY=${summary}\n`);
}

function readState(p) {
  try {
    const raw = fs.readFileSync(p, "utf8");
    const s = JSON.parse(raw);
    if (s.schema_version !== 3) throw new Error(`schema_version must be 3, got ${s.schema_version}`);
    return s;
  } catch (e) {
    out("failed", `state file read/parse error: ${e.message}`);
    process.exit(0);
  }
}

function writeState(p, s) {
  const tmp = `${p}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(s, null, 2));
  fs.renameSync(tmp, p);
}

function runBash(args, env = {}) {
  const result = spawnSync("bash", args, {
    env: { ...process.env, ...env },
    encoding: "utf8",
  });
  return {
    rc: result.status ?? 1,
    stdout: result.stdout || "",
    stderr: result.stderr || "",
  };
}

function parseKV(text) {
  const kv = {};
  for (const line of text.split(/\r?\n/)) {
    const m = line.match(/^([A-Z_][A-Z0-9_]*)=(.*)$/);
    if (m) kv[m[1]] = m[2];
  }
  return kv;
}

const state = readState(stateFilePath);
const last = state.g5_history && state.g5_history[state.g5_history.length - 1];

if (!last) {
  out("failed", "g5_history is empty — cannot process loop_step");
  process.exit(0);
}

if (g5Decision === "decline" || g5Decision === "llm_declined") {
  last.user_decision = g5Decision;
  state.proposal_counters = state.proposal_counters || { accepted: 0, declined: 0, skipped: 0 };
  state.proposal_counters.declined = (state.proposal_counters.declined || 0) + 1;
  state.phase = "terminal";
  writeState(stateFilePath, state);
  out("terminal", `loop_step ${g5Decision} recorded — phase=terminal`);

} else if (g5Decision === "accept") {
  if (!last.g5_3a_completed) {
    const res = runBash(
      [path.join(finalizeScriptsDir, "step-g5-loop.sh"), "execute", String(last.proposal_parent), "accept"],
      { AGENTS_CONFIG_DIR: agentsConfigDir, OWNER_REPO: state.owner_repo }
    );
    if (res.rc !== 0) {
      out("failed", `step-g5-loop.sh execute failed: ${res.stderr.trim()}`);
      process.exit(0);
    }
    last.g5_3a_completed = true;
  }
  state.phase = "awaiting_recursion";
  writeState(stateFilePath, state);
  out("awaiting_recursion", "g5 accept: G.5-3a done, awaiting recursion");

} else if (g5Decision === "recurse_done") {
  last.recursion_completed = true;
  state.proposal_counters = state.proposal_counters || { accepted: 0, declined: 0, skipped: 0 };
  state.proposal_counters.accepted = (state.proposal_counters.accepted || 0) + 1;
  state.current_issue_number = last.proposal_parent;
  state.g5_loop_iteration = (state.g5_loop_iteration || 0) + 1;

  // Run G.5-1 for new current_issue_number
  const res = runBash(
    [path.join(finalizeScriptsDir, "step-g5-loop.sh"), "prepare", String(state.current_issue_number)],
    { AGENTS_CONFIG_DIR: agentsConfigDir, OWNER_REPO: state.owner_repo }
  );
  const kv = parseKV(res.stdout);
  const newEntry = {
    iteration: (state.g5_loop_iteration || 1),
    issue_number: String(state.current_issue_number),
    proposal_status: kv.PROPOSAL_STATUS || "skipped",
    proposal_parent: kv.PROPOSAL_PARENT ? parseInt(kv.PROPOSAL_PARENT) : null,
    user_decision: null,
    g5_3a_completed: false,
    recursion_completed: false,
  };
  state.g5_history = state.g5_history || [];
  state.g5_history.push(newEntry);
  state.phase = "init_done";
  writeState(stateFilePath, state);
  out("init_done", `recurse_done: advanced to #${state.current_issue_number}`);

} else {
  out("failed", `unknown g5_decision: ${g5Decision}`);
}
