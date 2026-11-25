"use strict";
// End-to-end runner for hooks/enforce-worktree.js, the JavaScript counterpart of tests/lib/ew-runner.sh.
// The hook resolves the repo from its real process cwd, so ewRun spawns it inside <cwd>. Call
// harness isolate() first: the child inherits the pinned WORKFLOW_STATE_DIR / WORKFLOW_PLANS_DIR.
// Not a test on its own.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const ROOT = path.resolve(__dirname, "..", "..");
const EW_GUARD = path.join(ROOT, "hooks", "enforce-worktree.js");

// Every variable that redirects git or widens the session is cleared, so a case sets it explicitly.
const CLEARED = [
  "CLAUDE_CODE_SESSION_ID", "SCRATCHPAD", "DEFAULT_BRANCHES", "ENFORCE_WORKTREE_ADDITIONAL_REPOS",
  "ENFORCE_WORKTREE_EXCLUDE", "WORKFLOW_OFF", "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR",
  "GIT_INDEX_FILE", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT", "EWT_T", "UNSET_VAR", "X",
];

const TRANSCRIPTS = fs.mkdtempSync(path.join(os.tmpdir(), "ew-runner-transcripts-"));
process.on("exit", () => fs.rmSync(TRANSCRIPTS, { recursive: true, force: true }));

const fwd = (p) => String(p).replace(/\\/g, "/");

// ewRun(cwd, command, extraEnv, cfgRoot) → { verdict: allow|block|timeout|crash:<rc>|other, reason, raw }
function ewRun(cwd, command, extraEnv, cfgRoot) {
  const env = { ...process.env };
  for (const name of CLEARED) delete env[name];
  Object.assign(env, {
    ENFORCE_WORKTREE: "on", AGENTS_MAIN_ROOT: cfgRoot, CLAUDE_TRANSCRIPT_BASE_DIR: TRANSCRIPTS,
  }, extraEnv || {});
  const payload = JSON.stringify({ session_id: "test-3147", tool_name: "Bash", tool_input: { command } });
  const r = spawnSync(process.execPath, [EW_GUARD], { cwd, env, input: payload, encoding: "utf8", timeout: 30000 });
  const raw = String(r.stdout || "").trim();
  if (r.error && r.error.code === "ETIMEDOUT") return { verdict: "timeout", reason: "", raw };
  if (r.status !== 0) return { verdict: `crash:${r.status}`, reason: String(r.stderr || ""), raw };
  if (raw === "{}") return { verdict: "allow", reason: "", raw };
  try {
    const out = JSON.parse(raw);
    if (out && out.decision === "block") return { verdict: "block", reason: String(out.reason || ""), raw };
  } catch { /* not JSON: reported as other below */ }
  return { verdict: "other", reason: "", raw };
}

// expectVerdict(label, want, res) — a block must also name the exit switch (ARP-EXBG).
function expectVerdict(label, want, res) {
  assert.equal(res.verdict, want, `${label}: want=${want} got=${res.verdict} raw=${res.raw.slice(0, 300)}`);
  if (want === "block") {
    assert.ok(res.reason.includes("ENFORCE_WORKTREE=off"), `${label}: block reason must name ENFORCE_WORKTREE=off: ${res.reason}`);
  }
}

function gitOut(args, cwd) {
  const r = spawnSync("git", args, { cwd, encoding: "utf8", timeout: 60000 });
  if (r.status !== 0) throw new Error(`git ${args.join(" ")} failed: ${r.stderr || r.error}`);
  return r.stdout.trim();
}

// makeSessionFixture(base, wt2Branch) — MAIN (main checkout) with linked WT (cwd) and WT2, EXT
// (a repo outside the session) and ADD (for ENFORCE_WORKTREE_ADDITIONAL_REPOS); MAIN and EXT
// carry an unchecked-out branch `feat`. Paths use forward slashes.
function makeSessionFixture(base, wt2Branch) {
  const { makeRepo, addWorktree, git } = require("./worktree-leftover-fixture");
  const at = (name) => fwd(path.join(base, name));
  const MAIN = fwd(makeRepo(at("main")));
  const EXT = fwd(makeRepo(at("ext")));
  const ADD = fwd(makeRepo(at("add")));
  git(["-C", MAIN, "branch", "feat"]);
  git(["-C", EXT, "branch", "feat"]);
  const WT = fwd(addWorktree(MAIN, at("wt"), "feature/wt"));
  const WT2 = fwd(addWorktree(MAIN, at("wt2"), wt2Branch));
  const gitDirOf = (dir) => fwd(gitOut(["rev-parse", "--absolute-git-dir"], dir));
  return { MAIN, WT, WT2, EXT, ADD, WT_GITDIR: gitDirOf(WT), WT2_GITDIR: gitDirOf(WT2) };
}

module.exports = { ROOT, EW_GUARD, fwd, ewRun, expectVerdict, gitOut, makeSessionFixture };
