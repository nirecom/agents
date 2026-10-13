#!/usr/bin/env bash
# tests/bin/feature-2527-commit-push-resume.sh
# Tests: bin/worker-dispatch/workers/commit-push/procedure.js, bin/worker-dispatch/workers/commit-push/resume.js
# Tags: scope:issue-specific, worker-dispatch, commit-push, resume, up-to-date, issue-2527, TL1
# Issue #2527 step 3-8b: an empty stage resumes from the unpushed-commit
# count instead of ending in staging_incomplete. spawn.js is faked (the
# 1673 group F pattern), so every git / gh / gate call is observed in-process.
# TL3 gap: a real remote, a real workflow-gate verdict and real gh are not
# exercised; tests/bin/TL3-worker-dispatch-commit-push.sh owns that surface.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMPD="$(make_tmp)"
trap 'rm -rf "$TMPD"' EXIT
DRIVER="$TMPD/resume-driver.js"
BR="feature/2527-resume"

cat > "$DRIVER" <<'NODE'
"use strict";
const path = require("path");
const SCRIPT_CHECKOUT_ROOT = process.argv[2];
const E = process.env;
const BRANCH = "feature/2527-resume";
const spawnPath = require.resolve(path.join(SCRIPT_CHECKOUT_ROOT, "bin", "worker-dispatch", "spawn.js"));
const seen = { commits: 0, pushes: [], fetches: 0, revlist: [], gates: [], prCreate: 0, unstagedChecks: 0, probes: 0 };
const ok = (stdout) => ({ status: 0, stdout: stdout || "", stderr: "", spawnError: null, timedOut: false });
const err = (status, stderr) => ({ status, stdout: "", stderr: stderr || "", spawnError: null, timedOut: false });
const originDefault = E.F_ORIGIN_DEFAULT !== "0";
function fakeGit(args) {
  const a = args.join(" ");
  if (a === "rev-parse --abbrev-ref HEAD") return ok(BRANCH);
  if (a === "diff --cached --stat") return ok(E.F_STAGED === "1" ? " file.txt | 1 +\n" : "");
  if (args.includes("commit")) { seen.commits += 1; return ok(""); }
  if (args[0] === "push") { seen.pushes.push(a); return ok(""); }
  if (args[0] === "fetch" || args[0] === "pull" || args[0] === "ls-remote") { seen.fetches += 1; return ok(""); }
  if (args[0] === "rev-list") {
    seen.revlist.push(a);
    if (E.F_AHEAD === "FAIL") return err(128, "fatal: bad revision");
    if (!originDefault && a.includes("origin/") && !a.includes("@{upstream}")) return err(128, "fatal: unknown revision");
    return ok(String(E.F_AHEAD || "0") + "\n");
  }
  if (a.includes("@{upstream}") || a.includes("@{u}")) {
    return E.F_UPSTREAM === "1" ? ok("origin/" + BRANCH + "\n") : err(128, "fatal: no upstream configured");
  }
  if (args[0] === "symbolic-ref") return originDefault ? ok("refs/remotes/origin/main\n") : err(128, "fatal: not a symbolic ref");
  if (args[0] === "rev-parse" && args.includes("--verify")) return originDefault ? ok("abc123\n") : err(128, "fatal: needed a single revision");
  if (args[0] === "remote" && args[1] === "get-url") return ok("https://github.com/acme/widgets.git\n");
  if (args[0] === "status") return ok(E.F_UNSTAGED === "1" ? " M tracked.txt\n" : "");
  if (args[0] === "diff") return ok(E.F_UNSTAGED === "1" ? "tracked.txt\n" : "");
  return ok("");
}
function fakeRun(entry, opts) {
  const args = opts.args || [];
  const a = args.join(" ");
  if (opts.command === "git") return fakeGit(args);
  if (opts.command === "node" && opts.script === "workflowGate") {
    let cmd = "";
    try { cmd = JSON.parse(opts.input).tool_input.command; } catch (_e) { cmd = "<unparsable>"; }
    seen.gates.push(cmd);
    if (E.F_GATE_PUSH === "block" && /^git push/.test(cmd)) return ok(JSON.stringify({ decision: "block", reason: "push blocked by fixture" }));
    return ok(JSON.stringify({ decision: "approve" }));
  }
  if (opts.command === "bash") {
    if (opts.script === "bootstrapProbe") {
      seen.probes += 1;
      if (E.F_PROBE === "empty") return ok(JSON.stringify({ preBootstrap: true, classification: "empty-repo" }));
      return err(1, "");
    }
    if (opts.script === "unstagedCheck") {
      seen.unstagedChecks += 1;
      return E.F_UNSTAGED === "1" ? { status: 1, stdout: "tracked.txt\n", stderr: "", spawnError: null, timedOut: false } : ok("");
    }
    return ok("");
  }
  if (opts.command === "gh") {
    if (a.includes("pr view")) {
      if (E.F_PR_EXISTS === "1") return ok(JSON.stringify({ state: "OPEN", url: "https://github.com/acme/widgets/pull/7" }) + "\n");
      return err(1, "no pr");
    }
    if (a.includes("issue view")) return ok("Some Issue Title\n");
    if (a.includes("pr create")) { seen.prCreate += 1; return ok("https://github.com/acme/widgets/pull/7\n"); }
    return ok("");
  }
  return ok("");
}
require.cache[spawnPath] = {
  id: spawnPath, filename: spawnPath, loaded: true,
  exports: { run: fakeRun, resolveScript: () => "", scriptExists: () => true, buildEnv: () => ({}), DEFAULT_TIMEOUT_MS: 1000 },
};
const { run } = require(path.join(SCRIPT_CHECKOUT_ROOT, "bin", "worker-dispatch", "workers", "commit-push", "procedure.js"));
const tmp = E.F_TMP;
const payload = {
  branch: BRANCH, worktree_path: tmp, session_id: "sess-2527", commit_message: "feat: a thing",
  wip_mode: E.F_WIP !== "false", enforce_worktree: E.F_ENFORCE || "on", closes_issues: [],
};
const ctx = {
  entry: { name: "commit-push", binaries: { external: [], scripts: {} } },
  anchors: { scriptCheckoutRoot: path.join(tmp, "script-checkout-root-none"), plansDir: tmp }, path, fsguard: { writeFile: (t) => t },
};
let res;
try { res = run(payload, ctx); } catch (e) { res = { status: "THREW", summary: String(e && e.message) }; }
const line = (k, v) => process.stdout.write(k + "=" + String(v).replace(/\r?\n/g, " ") + "\n");
line("STATUS", res.status); line("SUMMARY", res.summary);
line("COMMITS", seen.commits); line("PUSHES", seen.pushes.length); line("PUSH_ARGV", seen.pushes.join(" | "));
line("FETCHES", seen.fetches); line("REVLIST", seen.revlist.join(" | ")); line("GATES", seen.gates.join(" | "));
line("PR_CREATE", seen.prCreate); line("UNSTAGED_CHECKS", seen.unstagedChecks); line("PROBES", seen.probes);
NODE

# drive <VAR=value>... — runs the driver with the given fixture knobs.
drive() {
  local ftmp
  ftmp="$(mktemp -d "$TMPD/r-XXXXXX")"
  run_with_timeout 40 env "F_TMP=$(np "$ftmp")" "$@" node "$(np "$DRIVER")" "$(np "$SCRIPT_CHECKOUT_ROOT")" 2>&1
}
# val <output> <KEY> — value of KEY=..., or a <no KEY: ...> marker.
val() {
  local v
  v="$(printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1)"
  if ! printf '%s\n' "$1" | grep -q "^$2="; then v="<no $2: $(printf '%s' "$1" | head -c 300 | tr '\n' ' ')>"; fi
  printf '%s' "$v"
}
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=[$3] got=[$2]"; fi; }
has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "missing [$3] in [$2]" ;; esac; }
hasnt() { case "$2" in *"$3"*) fail "$1" "unexpected [$3] in [$2]" ;; *) pass "$1" ;; esac; }

case_begin "resume-direct-unpushed-commit" "bin/worker-dispatch/workers/commit-push/resume.js"
o="$(drive F_STAGED=0 F_AHEAD=2 F_UPSTREAM=1 F_ENFORCE=off)"
eq "direct resume -> pushed" "$(val "$o" STATUS)" "pushed"
eq "direct resume creates no commit" "$(val "$o" COMMITS)" "0"
eq "direct resume pushes once" "$(val "$o" PUSHES)" "1"
has "direct resume pushes the explicit refspec" "$(val "$o" PUSH_ARGV)" "push origin $BR"
has "direct resume counts against the upstream" "$(val "$o" REVLIST)" "@{upstream}"
has "direct resume push gate still runs" "$(val "$o" GATES)" "git push origin $BR"
hasnt "direct resume skips the commit gate" "$(val "$o" GATES)" "commit -F -"
has "direct resume summary records the resume" "$(val "$o" SUMMARY)" "resumed: push"
eq "direct resume never fetches" "$(val "$o" FETCHES)" "0"
eq "direct resume runs the bootstrap probe" "$(val "$o" PROBES)" "1"
case_end

case_begin "resume-pr-path-unpushed-commit" "bin/worker-dispatch/workers/commit-push/resume.js"
o="$(drive F_STAGED=0 F_AHEAD=1 F_UPSTREAM=1 F_ENFORCE=on F_PR_EXISTS=0)"
eq "PR resume, no PR -> pr_created" "$(val "$o" STATUS)" "pr_created"
eq "PR resume creates no commit" "$(val "$o" COMMITS)" "0"
eq "PR resume pushes once" "$(val "$o" PUSHES)" "1"
o="$(drive F_STAGED=0 F_AHEAD=1 F_UPSTREAM=1 F_ENFORCE=on F_PR_EXISTS=1)"
eq "PR resume, open PR -> pr_reused" "$(val "$o" STATUS)" "pr_reused"
eq "PR resume (reused) creates no commit" "$(val "$o" COMMITS)" "0"
case_end

case_begin "resume-without-upstream" "bin/worker-dispatch/workers/commit-push/resume.js"
o="$(drive F_STAGED=0 F_AHEAD=1 F_UPSTREAM=0 F_ENFORCE=off)"
eq "no-upstream resume -> pushed" "$(val "$o" STATUS)" "pushed"
has "no-upstream resume pushes with -u" "$(val "$o" PUSH_ARGV)" "push -u origin $BR"
has "no-upstream resume counts against origin/<default>" "$(val "$o" REVLIST)" "origin/main"
hasnt "no-upstream resume does not count against @{upstream}" "$(val "$o" REVLIST)" "@{upstream}"
eq "no-upstream resume creates no commit" "$(val "$o" COMMITS)" "0"
case_end

case_begin "resume-no-origin-default-defers-to-bootstrap" "bin/worker-dispatch/workers/commit-push/resume.js"
o="$(drive F_STAGED=0 F_AHEAD=1 F_UPSTREAM=0 F_ORIGIN_DEFAULT=0 F_PROBE=empty F_ENFORCE=off)"
eq "no origin/<default> ref -> bootstrap_pending" "$(val "$o" STATUS)" "bootstrap_pending"
eq "bootstrap deferral creates no commit" "$(val "$o" COMMITS)" "0"
eq "bootstrap deferral pushes nothing" "$(val "$o" PUSHES)" "0"
case_end

case_begin "nothing-left-pr-path-ensures-pr" "bin/worker-dispatch/workers/commit-push/resume.js"
o="$(drive F_STAGED=0 F_AHEAD=0 F_UPSTREAM=1 F_ENFORCE=on F_PR_EXISTS=0)"
eq "nothing left, PR path, no PR -> pr_created" "$(val "$o" STATUS)" "pr_created"
eq "nothing left, PR path pushes nothing" "$(val "$o" PUSHES)" "0"
eq "nothing left, PR path creates no commit" "$(val "$o" COMMITS)" "0"
eq "nothing left, PR path creates the PR once" "$(val "$o" PR_CREATE)" "1"
o="$(drive F_STAGED=0 F_AHEAD=0 F_UPSTREAM=1 F_ENFORCE=on F_PR_EXISTS=1)"
eq "nothing left, PR path, open PR -> pr_reused" "$(val "$o" STATUS)" "pr_reused"
eq "nothing left, open PR creates no PR" "$(val "$o" PR_CREATE)" "0"
case_end

case_begin "nothing-left-direct-up-to-date" "bin/worker-dispatch/workers/commit-push/resume.js"
o="$(drive F_STAGED=0 F_AHEAD=0 F_UPSTREAM=1 F_ENFORCE=off)"
eq "nothing left, direct -> up_to_date" "$(val "$o" STATUS)" "up_to_date"
eq "up_to_date pushes nothing" "$(val "$o" PUSHES)" "0"
eq "up_to_date creates no commit" "$(val "$o" COMMITS)" "0"
eq "up_to_date never fetches" "$(val "$o" FETCHES)" "0"
case_end

case_begin "empty-stage-dirty-tree-still-refused" "bin/worker-dispatch/workers/commit-push/resume.js"
o="$(drive F_STAGED=0 F_AHEAD=0 F_UPSTREAM=1 F_ENFORCE=off F_WIP=false F_UNSTAGED=1)"
eq "empty stage + unstaged tracked -> staging_incomplete" "$(val "$o" STATUS)" "staging_incomplete"
has "refusal names the Gate 3 reason, not 'nothing is staged'" "$(val "$o" SUMMARY)" "unstaged tracked"
eq "dirty refusal pushes nothing" "$(val "$o" PUSHES)" "0"
case_end

case_begin "unpushed-count-failure-fails-closed" "bin/worker-dispatch/workers/commit-push/resume.js"
o="$(drive F_STAGED=0 F_AHEAD=FAIL F_UPSTREAM=1 F_ENFORCE=off)"
eq "rev-list failure -> staging_check_failed" "$(val "$o" STATUS)" "staging_check_failed"
eq "rev-list failure pushes nothing" "$(val "$o" PUSHES)" "0"
eq "rev-list failure creates no commit" "$(val "$o" COMMITS)" "0"
case_end

case_begin "resume-push-gate-block-honoured" "bin/worker-dispatch/workers/commit-push/resume.js"
o="$(drive F_STAGED=0 F_AHEAD=1 F_UPSTREAM=1 F_ENFORCE=off F_GATE_PUSH=block)"
eq "resume with push gate block -> gate_blocked" "$(val "$o" STATUS)" "gate_blocked"
eq "blocked resume pushes nothing" "$(val "$o" PUSHES)" "0"
case_end

case_begin "regression-staged-change-still-commits" "bin/worker-dispatch/workers/commit-push/procedure.js"
o="$(drive F_STAGED=1 F_AHEAD=1 F_UPSTREAM=1 F_ENFORCE=off)"
eq "staged change -> pushed" "$(val "$o" STATUS)" "pushed"
eq "staged change commits once" "$(val "$o" COMMITS)" "1"
has "staged change passes the commit gate" "$(val "$o" GATES)" "commit -F -"
hasnt "staged change is not reported as a resume" "$(val "$o" SUMMARY)" "resumed: push"
o="$(drive F_STAGED=1 F_UPSTREAM=1 F_ENFORCE=off F_WIP=false F_UNSTAGED=1)"
eq "staged + unstaged tracked -> staging_incomplete" "$(val "$o" STATUS)" "staging_incomplete"
eq "staged + unstaged tracked creates no commit" "$(val "$o" COMMITS)" "0"
case_end

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
