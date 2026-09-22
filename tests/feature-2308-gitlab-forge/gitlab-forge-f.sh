#!/bin/bash
# Tests: bin/worker-dispatch/workers/commit-push/procedure.js
# Tags: scope:issue-specific, gitlab, forge, commit-push, TL2
set -u

# Issue #2308 — Group F of the split gitlab-forge suite: the commit-push
# procedure.js forge gate. Drives run() to step 8 with every child result
# canned, then asserts forge routing. Current tree hard-exits non-github remotes
# with "PR skipped (non-GitHub remote)"; GREEN once #2308 routes gitlab to MR.
#
# # TL3 gap
#   - Group F mocks spawn.js, so a missing glab binaries.external declaration is
#     not caught here (a real-spawn TL3 concern).

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

echo "=== Group F: commit-push forge gate ==="

F_DRIVER="$TMPROOT/f-driver.js"
cat > "$F_DRIVER" <<'NODE'
"use strict";
const path = require("path");
const AGENTS = process.argv[2];
const REMOTE = process.argv[3];
const BRANCH = "feature/x";
const SPAWNS = [];
// C7: capture the stdin body (opts.input) handed to `glab mr create` so a test
// can prove the MR description is actually wired through the new gitlab path —
// SPAWNS records only the command line, so a dropped body would pass unnoticed.
const MR_BODIES = [];

const spawnPath = require.resolve(path.join(AGENTS, "bin", "worker-dispatch", "spawn.js"));
function forgeType() {
  if (REMOTE.indexOf("github.com") >= 0) return "github";
  if (REMOTE.indexOf("gitlab.com") >= 0) return "gitlab";
  return "unknown";
}
function ok(stdout) { return { status: 0, stdout: stdout || "", stderr: "", spawnError: null, timedOut: false }; }
function err(status, stderr) { return { status: status, stdout: "", stderr: stderr || "", spawnError: null, timedOut: false }; }
function fakeRun(entry, opts) {
  const cmd = opts.command;
  const script = opts.script || "";
  const args = opts.args || [];
  const a = args.join(" ");
  SPAWNS.push([cmd, script, a].filter(Boolean).join(" "));
  if (cmd === "git") {
    if (a === "rev-parse --abbrev-ref HEAD") return ok(BRANCH);
    if (a === "diff --cached --stat") return ok(" file.txt | 1 +\n");
    if (args[0] === "rev-parse" && a.indexOf("@{upstream}") >= 0) return err(1, "no upstream");
    if (args[0] === "remote" && args[1] === "get-url") return ok(REMOTE + "\n");
    return ok("");
  }
  if (cmd === "node" && script === "workflowGate") return ok(JSON.stringify({ decision: "approve" }));
  if (cmd === "bash") {
    if (script === "bootstrapProbe") return err(1, "");
    if (script === "scanOutbound") return ok("");
    if (script === "unstagedCheck") return ok("");
    if (script === "isGithubRemote") return forgeType() === "github" ? ok("") : err(1, "");
    const t = forgeType();
    return ok(JSON.stringify({ type: t, host: REMOTE.replace(/^.*@/, "").replace(/[:/].*/, ""), project: "acme/widgets" }));
  }
  if (cmd === "gh") {
    if (a.indexOf("pr view") >= 0) return err(1, "no pr");
    if (a.indexOf("issue view") >= 0) return ok("Some Issue Title\n");
    if (a.indexOf("pr create") >= 0) return ok("https://github.com/acme/widgets/pull/7\n");
    return ok("");
  }
  if (cmd === "glab") {
    if (a.indexOf("mr view") >= 0) {
      // GL_MR_EXISTS=1 → an OPEN MR already exists for the branch (reuse path).
      if (process.env.GL_MR_EXISTS === "1") {
        return ok(JSON.stringify({ state: "opened", web_url: "https://gitlab.com/acme/widgets/-/merge_requests/9", iid: 9 }) + "\n");
      }
      return err(1, "no mr");
    }
    if (a.indexOf("mr create") >= 0) {
      MR_BODIES.push(typeof opts.input === "string" ? opts.input : "");
      return ok("https://gitlab.com/acme/widgets/-/merge_requests/3\n");
    }
    if (a.indexOf("issue view") >= 0) return ok("Some Issue Title\n");
    return ok(JSON.stringify({ web_url: "https://gitlab.com/acme/widgets/-/merge_requests/3", iid: 3 }) + "\n");
  }
  return ok("");
}
require.cache[spawnPath] = {
  id: spawnPath, filename: spawnPath, loaded: true, exports:
  { run: fakeRun, resolveScript: () => "", scriptExists: () => true, buildEnv: () => ({}), DEFAULT_TIMEOUT_MS: 1000 },
};

const { run } = require(path.join(AGENTS, "bin", "worker-dispatch", "workers", "commit-push", "procedure.js"));
const tmp = process.env.F_TMP;
const payload = {
  branch: BRANCH,
  worktree_path: tmp,
  session_id: "sess-f",
  commit_message: "feat: a thing",
  wip_mode: true,
  enforce_worktree: "on",
  // F_CLOSES lets a case exercise the closing-ref path (prBody emits `Closes #N`).
  closes_issues: process.env.F_CLOSES ? [{ number: Number(process.env.F_CLOSES) }] : [],
};
const ctx = {
  entry: { name: "commit-push", binaries: { external: [], scripts: {} } },
  anchors: { acd: path.join(tmp, "acd-none"), plansDir: tmp },
  path: path,
  fsguard: { writeFile: (t) => t },
};
let res;
try { res = run(payload, ctx); } catch (e) { res = { status: "THREW", summary: String(e && e.message) }; }
process.stdout.write(JSON.stringify({ status: res.status, summary: res.summary, spawns: SPAWNS, mrCreateBody: MR_BODIES.join("\n") }));
NODE

run_f() {
    F_TMP="$TMPROOT/f-$RANDOM" && mkdir -p "$F_TMP"
    F_TMP="$F_TMP" run_with_timeout 40 node "$F_DRIVER" "$AGENTS_DIR" "$1" 2>/dev/null
}
# run_f_mr <remote> <GL_MR_EXISTS 0|1> : run the driver with the existing-MR flag.
run_f_mr() {
    F_TMP="$TMPROOT/f-$RANDOM" && mkdir -p "$F_TMP"
    F_TMP="$F_TMP" GL_MR_EXISTS="$2" run_with_timeout 40 node "$F_DRIVER" "$AGENTS_DIR" "$1" 2>/dev/null
}
json_field() { printf '%s' "$2" | run_with_timeout 20 node -e '
let s=""; process.stdin.on("data",d=>s+=d); process.stdin.on("end",()=>{ try{const j=JSON.parse(s); process.stdout.write(String(j[process.argv[1]]));}catch(e){process.stdout.write("ERR");} });' "$1" 2>/dev/null; }

# F1: github remote -> reaches the PR path (regression pin; unchanged behavior).
OUT_GH="$(run_f 'https://github.com/acme/widgets.git')"
ST_GH="$(json_field status "$OUT_GH")"
assert_contains "F1/github remote reaches PR path (status pr_*/pushed)" "pr" "$ST_GH"
assert_not_contains "F1b/github remote not skipped as non-forge" "non-GitHub remote" "$OUT_GH"

# F2: gitlab remote -> NOT skipped as a non-GitHub remote. RED now (current code
# returns "...PR skipped (non-GitHub remote)"); GREEN once #2308 routes to MR.
OUT_GL="$(run_f 'https://gitlab.com/acme/widgets.git')"
assert_not_contains "F2/gitlab remote NOT treated as non-forge" "non-GitHub remote" "$OUT_GL"
assert_not_contains "F2b/gitlab remote did NOT create a github PR" "gh pr create" "$OUT_GL"

# F3: unknown remote -> forge gate blocks/skips; never a PR or MR.
OUT_UNK="$(run_f 'https://bitbucket.org/acme/widgets.git')"
assert_not_contains "F3/unknown remote creates no github PR" "gh pr create" "$OUT_UNK"
assert_not_contains "F3b/unknown remote creates no gitlab MR" "glab mr create" "$OUT_UNK"

# C7: F2 only proved "not skipped as non-forge" — it would pass even if NO MR were
# ever created. F4/F5 pin the full glab mr view→create flow and the reuse path.
#
# F4: gitlab remote, NO existing MR (mr view exits 1). The worker must query
# `glab mr view`, then `glab mr create`, generate a title from the commit subject
# ("feat: a thing"; closes_issues is empty), and surface the created MR URL.
OUT_GL_NEW="$(run_f_mr 'https://gitlab.com/acme/widgets.git' 0)"
assert_contains "F4/gitlab no-MR: queries glab mr view" "glab mr view" "$OUT_GL_NEW"
assert_contains "F4b/gitlab no-MR: runs glab mr create" "glab mr create" "$OUT_GL_NEW"
assert_contains "F4c/gitlab no-MR: mr create carries generated title (commit subject)" "feat: a thing" "$OUT_GL_NEW"
assert_contains "F4d/gitlab no-MR: final summary carries the created MR URL" "merge_requests/3" "$OUT_GL_NEW"
assert_not_contains "F4e/gitlab no-MR: never creates a github PR" "gh pr create" "$OUT_GL_NEW"

# F5: gitlab remote, an OPEN MR already exists (GL_MR_EXISTS=1). The worker must
# reuse it — `glab mr view` only, NO `glab mr create` — and surface the existing
# MR URL (merge_requests/9). RED now (same non-GitHub-remote hard-exit).
OUT_GL_REUSE="$(run_f_mr 'https://gitlab.com/acme/widgets.git' 1)"
assert_contains "F5/gitlab existing-MR: queries glab mr view" "glab mr view" "$OUT_GL_REUSE"
assert_contains "F5b/gitlab existing-MR: surfaces the reused MR URL" "merge_requests/9" "$OUT_GL_REUSE"
assert_not_contains "F5c/gitlab existing-MR: does NOT create a second MR" "glab mr create" "$OUT_GL_REUSE"

# F6: gitlab no-MR WITH a closing issue. F4 pins the `mr create` command line but
# would pass even if the MR description were dropped — the body travels on stdin
# (--description-file -), invisible to a command-line-only assertion. F6 captures
# that stdin (opts.input) and proves prBody's closing ref reaches the new gitlab
# MR path, so an empty/dropped description is a loud failure, not a silent one.
OUT_GL_CLOSE="$(F_CLOSES=2308 run_f_mr 'https://gitlab.com/acme/widgets.git' 0)"
BODY_GL_CLOSE="$(json_field mrCreateBody "$OUT_GL_CLOSE")"
assert_contains "F6/gitlab no-MR: mr create stdin body carries prBody closing ref" "Closes #2308" "$BODY_GL_CLOSE"
assert_contains "F6b/gitlab no-MR: mr create stdin body carries the close marker" "issue-close-pr-of: 2308" "$BODY_GL_CLOSE"

finish
