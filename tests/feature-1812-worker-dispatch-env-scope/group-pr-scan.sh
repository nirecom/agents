# Part of tests/feature-1812-worker-dispatch-env-scope.sh — sourced, not run.
# Tests: bin/worker-dispatch/workers/commit-push/pr.js
# Tags: worker-dispatch, pr, scan-outbound, commit-push, TL1, scope:issue-specific
#
# Group G — ensurePullRequest outbound-scan WITHHOLD path (both forges).
# Non-zero scan-outbound → status "pushed", summary "PR withheld", no create call.
# G2/G4 control cases prove the withholding is conditional, not vacuous.
# TL3 gap: real bin/scan-outbound.sh on real PR text; spawn is mocked here.
# Sibling of feature-1673-commit-push-worker.sh group_f; same spawn seam.

# assert_contains / assert_not_contains — not defined by the parent; file-local.
assert_contains() {
    local name="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) pass "$name" ;;
        *) fail "$name" "expected to contain $(printf '%q' "$needle"), got: $hay" ;;
    esac
}
assert_not_contains() {
    local name="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) fail "$name" "expected NOT to contain $(printf '%q' "$needle"), got: $hay" ;;
        *) pass "$name" ;;
    esac
}

# Node driver — written once at source time into the parent's $TMPD.
G_PR_SCAN_DRIVER="$TMPD/g-pr-scan-driver.js"
cat > "$G_PR_SCAN_DRIVER" <<'NODE'
"use strict";
const path = require("path");
const AGENTS = process.argv[2];
const REMOTE = process.argv[3];
const BRANCH = "feature/2308";
const SPAWNS = [];
const spawnPath = require.resolve(path.join(AGENTS, "bin", "worker-dispatch", "spawn.js"));
function ok(stdout) { return { status: 0, stdout: stdout || "", stderr: "", spawnError: null, timedOut: false }; }
function err(status, stderr) { return { status: status, stdout: "", stderr: stderr || "", spawnError: null, timedOut: false }; }
function fakeRun(entry, opts) {
  const cmd = opts.command;
  const script = opts.script || "";
  const args = opts.args || [];
  const a = args.join(" ");
  SPAWNS.push([cmd, script, a].filter(Boolean).join(" "));
  if (cmd === "git") {
    if (args[0] === "remote" && args[1] === "get-url") return ok(REMOTE + "\n");
    return ok("");
  }
  if (cmd === "bash") {
    if (script === "scanOutbound") {
      return process.env.SCAN_BLOCK === "1"
        ? err(1, "BLOCKED: private repo name 'my-private-repo' present in PR text")
        : ok("");
    }
    return ok("");
  }
  if (cmd === "gh") {
    if (a.indexOf("pr view") >= 0) return err(1, "no pr");
    if (a.indexOf("pr create") >= 0) return ok("https://github.com/acme/widgets/pull/7\n");
    if (a.indexOf("issue view") >= 0) return ok("Some Issue Title\n");
    return ok("");
  }
  if (cmd === "glab") {
    if (a.indexOf("mr view") >= 0) return err(1, "no mr");
    if (a.indexOf("mr create") >= 0) return ok("https://gitlab.com/acme/widgets/-/merge_requests/3\n");
    if (a.indexOf("api") >= 0) return ok("main\n");
    if (a.indexOf("issue view") >= 0) return ok("Some Issue Title\n");
    return ok("");
  }
  return ok("");
}
require.cache[spawnPath] = {
  id: spawnPath, filename: spawnPath, loaded: true, exports:
  { run: fakeRun, resolveScript: () => "", scriptExists: () => true, buildEnv: () => ({}), DEFAULT_TIMEOUT_MS: 1000 },
};
const { ensurePullRequest } = require(path.join(AGENTS, "bin", "worker-dispatch", "workers", "commit-push", "pr.js"));
const tmp = process.env.F_TMP;
const payload = {
  branch: BRANCH,
  worktree_path: tmp,
  session_id: "sess-g",
  commit_message: "feat: a thing",
  wip_mode: true,
  enforce_worktree: "on",
  closes_issues: [],
};
const ctx = {
  entry: { name: "commit-push", binaries: { external: [], scripts: {} } },
  anchors: { acd: path.join(tmp, "acd-none"), plansDir: tmp },
  path: path,
  fsguard: { writeFile: (t) => t },
};
const log = [];
let res;
try { res = ensurePullRequest(payload, ctx, log); } catch (e) { res = { status: "THREW", summary: String(e && e.message) }; }
process.stdout.write(JSON.stringify({ status: res.status, summary: res.summary, spawns: SPAWNS }));
NODE

# Per-invocation runner: creates a fresh sub-dir inside $TMPD per call.
# $1 = remote URL, $2 = SCAN_BLOCK (0|1)
_gprs_run() {
    local gtmp="$TMPD/g-prs-$$-$RANDOM"
    mkdir -p "$gtmp"
    run_with_timeout 40 env "F_TMP=$(nodepath "$gtmp")" "SCAN_BLOCK=${2:-0}" \
        node "$(nodepath "$G_PR_SCAN_DRIVER")" "$(nodepath "$AGENTS_DIR")" "$1" 2>/dev/null
}

_gprs_status() {
    printf '%s' "$1" | node -e \
        'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{try{process.stdout.write(String(JSON.parse(s).status));}catch(e){process.stdout.write("PARSE_ERR");}})' \
        2>/dev/null
}

group_pr_scan() {
    local PR_JS="$AGENTS_DIR/bin/worker-dispatch/workers/commit-push/pr.js"
    if [ ! -f "$PR_JS" ]; then
        fail "G/prerequisite" "missing $PR_JS"
        return
    fi

    local OUT=""

    # G1: gitlab MR, scan BLOCKS → withheld, no `glab mr create`, scan did run.
    OUT="$(_gprs_run 'https://gitlab.com/acme/widgets.git' 1)"
    assert_eq "G1/pr-withhold/gitlab-scan-blocked status=pushed" "pushed" "$(_gprs_status "$OUT")"
    assert_contains "G1/pr-withhold/gitlab-scan-blocked summary=PR withheld" "PR withheld" "$OUT"
    assert_contains "G1/pr-withhold/gitlab-scan-blocked ran the outbound scan" "scanOutbound" "$OUT"
    assert_not_contains "G1/pr-withhold/gitlab-scan-blocked no MR created" "glab mr create" "$OUT"

    # G2 (control): gitlab MR, scan CLEAN → MR created (proves G1 is conditional).
    OUT="$(_gprs_run 'https://gitlab.com/acme/widgets.git' 0)"
    assert_eq "G2/pr-withhold/gitlab-scan-clean status=pr_created" "pr_created" "$(_gprs_status "$OUT")"
    assert_contains "G2/pr-withhold/gitlab-scan-clean created the MR" "glab mr create" "$OUT"

    # G3 (CPR-ORTH): github PR, scan BLOCKS → withheld, no `gh pr create`.
    OUT="$(_gprs_run 'https://github.com/acme/widgets.git' 1)"
    assert_eq "G3/pr-withhold/github-scan-blocked status=pushed" "pushed" "$(_gprs_status "$OUT")"
    assert_contains "G3/pr-withhold/github-scan-blocked summary=PR withheld" "PR withheld" "$OUT"
    assert_contains "G3/pr-withhold/github-scan-blocked ran the outbound scan" "scanOutbound" "$OUT"
    assert_not_contains "G3/pr-withhold/github-scan-blocked no PR created" "gh pr create" "$OUT"

    # G4 (control): github PR, scan CLEAN → PR created (ORTH counterpart of G2).
    OUT="$(_gprs_run 'https://github.com/acme/widgets.git' 0)"
    assert_eq "G4/pr-withhold/github-scan-clean status=pr_created" "pr_created" "$(_gprs_status "$OUT")"
    assert_contains "G4/pr-withhold/github-scan-clean created the PR" "gh pr create" "$OUT"
}
