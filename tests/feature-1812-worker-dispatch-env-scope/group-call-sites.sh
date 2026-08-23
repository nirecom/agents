# Part of tests/feature-1812-worker-dispatch-env-scope.sh — sourced, not run.
# Tests: bin/worker-dispatch/workers/commit-push.js, bin/worker-dispatch/workers/commit-push/push.js, bin/worker-dispatch/workers/commit-push/pr.js, bin/worker-dispatch/workers/doc-append.js
# Tags: worker-dispatch, commit-push, doc-append, env-scope, credential-scope, security, TL2, scope:issue-specific
#
# Groups B and C — the CALL SITES, through the real workers under the real
# dispatcher. The scope a worker asks for is read back out of the stub's call
# log rather than grepped out of the source, so moving a call or changing a
# helper's default shows up here as a want!=got.
LOGQ="$TMPD/envscope-logq.js"
cat > "$LOGQ" <<'LOGJS'
"use strict";
const fs = require("fs");
const [, , logFile, query, arg, nthRaw] = process.argv;
let calls = [];
try {
  calls = fs.readFileSync(logFile, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
} catch (_e) { calls = []; }

const lineOf = (c) => [c.command, c.script || ""].concat(c.args || []).join(" ").replace(/\s+/g, " ").trim();
// "(absent)" and "(empty)" are DIFFERENT verdicts: absent means the call
// passed no envScope at all and therefore inherits the worker's full declared
// set — the pre-#1812 behaviour this file exists to fence.
const scopeOf = (c) => {
  if (c.envScope === null || c.envScope === undefined) return "(absent)";
  if (!Array.isArray(c.envScope)) return "(not-an-array)";
  return c.envScope.length === 0 ? "(empty)" : c.envScope.slice().sort().join(",");
};
const matching = (needle) => calls.filter((c) => lineOf(c).indexOf(needle) !== -1);
const carriers = (name) => calls
  .filter((c) => Array.isArray(c.envScope) && c.envScope.includes(name))
  .map(lineOf).join(" ; ");
const out = (s) => process.stdout.write(String(s));

switch (query) {
  case "scope": {
    const hits = matching(arg);
    if (hits.length === 0) { out("(no-call)"); break; }
    const nth = nthRaw ? Number(nthRaw) : 1;
    if (!hits[nth - 1]) { out("(no-such-call)"); break; }
    out(scopeOf(hits[nth - 1]));
    break;
  }
  case "count": out(matching(arg).length); break;
  case "total": out(calls.length); break;
  case "carriers": out(carriers(arg)); break;
  // Every call site of these workers is expected to decide explicitly; an
  // "(absent)" one silently re-widens to the full declared set.
  case "unscoped": out(calls.filter((c) => c.envScope === null || c.envScope === undefined).map(lineOf).join(" ; ")); break;
  case "lines": out(calls.map(lineOf).join(" ; ")); break;
  default: out("(unknown-query)");
}
LOGJS
q() { node "$(nodepath "$LOGQ")" "$(nodepath "$CALLLOG")" "$@"; }

# `worktree_path` does not reach a call site as the caller typed it: the
# `family-worktree` capability replaces it with the realpath'd member of the
# worktree family (bin/worker-dispatch/capability.js checkFamilyMember), which
# is the platform-native form — backslashes on Windows, unchanged on POSIX.
# Assertions on the bootstrapProbe argument must expect that form, so derive it
# with the same primitive rather than assuming the mixed form `$CWD` holds.
CWD_NATIVE="$(node -e 'const fs=require("fs"),p=require("path");process.stdout.write(p.resolve(fs.realpathSync(process.argv[1])));' "$CWD")"

GH_SCOPE="GH_TOKEN,GITHUB_TOKEN"
GATE_SCOPE="CLAUDE_PROJECT_DIR,CLAUDE_WORKFLOW_DIR,DEFAULT_BRANCHES,ENFORCE_WORKTREE,WORKFLOW_PLANS_DIR,WORKFLOW_SESSION_ID"

CP_GATE='{"match":"workflowGate","stdout":"{\"decision\":\"approve\"}"}'
CP_HEAD='{"match":"rev-parse --abbrev-ref HEAD","status":0,"stdout":"feature/1812-probe\n"}'
CP_UPSTREAM='{"match":"symbolic-full-name","status":0,"stdout":"origin/feature/1812-probe\n"}'
CP_STAGED='{"match":"diff --cached","stdout":" README.md | 1 +\n 1 file changed"}'
CP_UNSTAGED='{"match":"unstagedCheck","status":0}'
CP_BOOTSTRAP='{"match":"bootstrapProbe","stdout":"{\"preBootstrap\":false,\"classification\":\"normal\"}"}'
CP_ISGH='{"match":"isGithubRemote","status":0}'
CP_PRVIEW='{"match":"pr view","status":1,"stderr":"no pull requests found"}'
CP_ISSUEVIEW='{"match":"issue view","status":0,"stdout":"an issue title\n"}'
CP_SCAN='{"match":"scanOutbound","status":0}'
CP_PRCREATE='{"match":"pr create","status":0,"stdout":"https://github.com/o/r/pull/7\n"}'
CP_CATCHALL='{"status":0,"stdout":""}'

CP_RULES_BASE="$CP_GATE,$CP_HEAD,$CP_UPSTREAM,$CP_STAGED,$CP_UNSTAGED,$CP_BOOTSTRAP,$CP_ISGH,$CP_PRVIEW,$CP_ISSUEVIEW,$CP_SCAN,$CP_PRCREATE"

# ===========================================================================
# Group B — commit-push. One full run: commit, push, and the PR step.
# ===========================================================================
group_b() {
    local p
    p="$(write_payload cp-1812 "{\"commit_message\":\"feat(#1812): probe\",\"branch\":\"feature/1812-probe\",\"worktree_path\":\"$CWD\",\"session_id\":\"$SID\",\"enforce_worktree\":\"on\",\"artifact_dir\":\"$PLANS\"}")"
    dispatch commit-push "$CP_PRELOAD" "[$CP_RULES_BASE,$CP_CATCHALL]" "$p"
    assert_eq "B/exit0" "0" "$DRC"
    # Anchor: without a run that reached the PR step, every row below is vacuous.
    assert_eq "B/status" "pr_created" "$(field_of status)"

    assert_eq "B/push-carries-the-ssh-socket" "SSH_AUTH_SOCK" "$(q scope 'push origin')"
    assert_eq "B/commit-carries-nothing" "(empty)" "$(q scope 'commit -F -')"
    assert_eq "B/head-probe-carries-nothing" "(empty)" "$(q scope 'rev-parse --abbrev-ref HEAD')"
    assert_eq "B/staged-check-carries-nothing" "(empty)" "$(q scope 'diff --cached')"
    assert_eq "B/upstream-probe-carries-nothing" "(empty)" "$(q scope 'symbolic-full-name')"
    assert_eq "B/unstaged-script-carries-nothing" "(empty)" "$(q scope unstagedCheck)"
    assert_eq "B/bootstrap-script-carries-the-ssh-socket" "SSH_AUTH_SOCK" "$(q scope bootstrapProbe)"
    assert_eq "B/is-github-script-carries-nothing" "(empty)" "$(q scope isGithubRemote)"
    assert_eq "B/outbound-scan-carries-nothing" "(empty)" "$(q scope scanOutbound)"

    assert_eq "B/gate-carries-its-six-workflow-vars" "$GATE_SCOPE" "$(q scope workflowGate)"
    assert_eq "B/second-gate-call-scoped-alike" "$GATE_SCOPE" "$(q scope workflowGate 2)"
    assert_eq "B/pr-view-carries-the-tokens" "$GH_SCOPE" "$(q scope 'pr view')"
    assert_eq "B/pr-create-carries-the-tokens" "$GH_SCOPE" "$(q scope 'pr create')"

    # The two set-level claims: exactly which calls carry each credential.
    assert_eq "B/bootstrap-and-push-carry-the-ssh-socket" "bash bootstrapProbe $CWD_NATIVE ; git push origin feature/1812-probe" "$(q carriers SSH_AUTH_SOCK)"
    assert_eq "B/only-gh-carries-the-tokens" \
        "gh pr view --json state,url ; gh pr create --head feature/1812-probe --title feat(#1812): probe --body-file -" \
        "$(q carriers GH_TOKEN)"
    assert_eq "B/github-token-carried-alongside" "$(q carriers GH_TOKEN)" "$(q carriers GITHUB_TOKEN)"
    # No call site may fall back to the full declared set.
    assert_eq "B/no-call-site-left-unscoped" "" "$(q unscoped)"
}

# ===========================================================================
# Group B2 — the rebase ladder. `fetch` is the OTHER network git call; it needs
# the socket for exactly the same reason `push` does, and a fix that scoped only
# the push would leave the retry path unauthenticated. The `rebase` replay that
# follows it is deliberately NOT a carrier: it is local, and it can run
# repo-configured hooks (pre-rebase, post-rewrite) and merge/smudge drivers, so
# the signing socket must not be reachable from that code-execution surface.
# The two halves used to be one fused `git pull --rebase`, which handed the
# socket to the hook-running half as well.
# ===========================================================================
group_b2() {
    local p rules
    p="$(write_payload cp-1812-ladder "{\"commit_message\":\"feat(#1812): ladder\",\"branch\":\"feature/1812-probe\",\"worktree_path\":\"$CWD\",\"session_id\":\"$SID\",\"enforce_worktree\":\"off\",\"artifact_dir\":\"$PLANS\"}")"
    rules="[{\"match\":\"push origin\",\"nth\":1,\"status\":1,\"stderr\":\"! [rejected] non-fast-forward\"},{\"match\":\"push origin\",\"nth\":2,\"status\":0},$CP_RULES_BASE,$CP_CATCHALL]"
    dispatch commit-push "$CP_PRELOAD" "$rules" "$p"
    assert_eq "B2/status" "pushed" "$(field_of status)"
    assert_eq "B2/push-attempted-twice" "2" "$(q count 'push origin')"
    assert_eq "B2/fetch-carries-the-ssh-socket" "SSH_AUTH_SOCK" "$(q scope 'fetch origin')"
    assert_eq "B2/rebase-replay-carries-nothing" "(empty)" "$(q scope 'rebase --autostash FETCH_HEAD')"
    assert_eq "B2/rebase-replay-happened" "1" "$(q count 'rebase --autostash FETCH_HEAD')"
    # The fused form is gone; its reappearance would re-arm the hook-running half.
    assert_eq "B2/no-fused-pull-rebase" "0" "$(q count 'pull --rebase')"
    assert_eq "B2/retry-push-carries-the-ssh-socket" "SSH_AUTH_SOCK" "$(q scope 'push origin' 2)"
    assert_eq "B2/commit-still-carries-nothing" "(empty)" "$(q scope 'commit -F -')"
    assert_eq "B2/ssh-socket-carriers-are-the-four-network-calls" \
        "bash bootstrapProbe $CWD_NATIVE ; git push origin feature/1812-probe ; git fetch origin feature/1812-probe ; git push origin feature/1812-probe" \
        "$(q carriers SSH_AUTH_SOCK)"
    # enforce_worktree=off skips the PR step entirely, so no token may travel.
    assert_eq "B2/no-token-on-the-no-pr-path" "" "$(q carriers GH_TOKEN)"
    assert_eq "B2/no-call-site-left-unscoped" "" "$(q unscoped)"
}

# ===========================================================================
# Group B3 — `gh issue view`, the fourth gh call site. It is reached only when
# the commit message yields no title, so the run is steered there deliberately.
# ===========================================================================
group_b3() {
    local p
    p="$(write_payload cp-1812-title "{\"commit_message\":\" \",\"branch\":\"feature/1812-probe\",\"worktree_path\":\"$CWD\",\"session_id\":\"$SID\",\"enforce_worktree\":\"on\",\"closes_issues\":[{\"number\":1812}],\"artifact_dir\":\"$PLANS\"}")"
    dispatch commit-push "$CP_PRELOAD" "[$CP_RULES_BASE,$CP_CATCHALL]" "$p"
    if [ "$(q count 'issue view')" != "1" ]; then
        fail "B3/issue-view-reached" "status=$(field_of status) calls=$(q lines)"
        return
    fi
    pass "B3/issue-view-reached"
    assert_eq "B3/issue-view-carries-the-tokens" "$GH_SCOPE" "$(q scope 'issue view')"
    assert_eq "B3/no-call-site-left-unscoped" "" "$(q unscoped)"
}

# ===========================================================================
# Group C — doc-append. One call site, two scopes: only compose shells out to
# `gh`, so history/changelog must reach their `uv run` with neither token.
# ===========================================================================
DA_TEXT='"category":"FEATURE","subject":"env scope","background":"why","changes":"what"'

group_c() {
    local p
    p="$(write_payload da-1812-hist "{\"mode\":\"history\",\"cwd\":\"$CWD\",$DA_TEXT,\"commits\":\"abc1234\",\"artifact_dir\":\"$PLANS\"}")"
    dispatch doc-append "$DA_PRELOAD" '[{"stdout":"appended"}]' "$p"
    assert_eq "C/history-status" "appended" "$(field_of status)"
    assert_eq "C/history-call-count" "1" "$(q total)"
    assert_eq "C/history-carries-no-token" "(empty)" "$(q scope 'uv run')"

    p="$(write_payload da-1812-chlog "{\"mode\":\"changelog\",\"cwd\":\"$CWD\",$DA_TEXT,\"artifact_dir\":\"$PLANS\"}")"
    dispatch doc-append "$DA_PRELOAD" '[{"stdout":"appended"}]' "$p"
    assert_eq "C/changelog-status" "appended" "$(field_of status)"
    assert_eq "C/changelog-carries-no-token" "(empty)" "$(q scope 'uv run')"

    p="$(write_payload da-1812-comp "{\"mode\":\"compose\",\"cwd\":\"$CWD\",\"notes_path\":\"$NOTES\",\"branch\":\"feature/1812-probe\",\"pr_number\":\"1812\",\"merge_commit\":\"deadbee\",\"pr_title\":\"a title\",\"artifact_dir\":\"$PLANS\"}")"
    dispatch doc-append "$DA_PRELOAD" '[{"stdout":"appended"}]' "$p"
    assert_eq "C/compose-status" "appended" "$(field_of status)"
    assert_eq "C/compose-carries-the-tokens" "$GH_SCOPE" "$(q scope compose-doc-append-entry)"
    assert_eq "C/compose-is-the-only-token-carrier" "1" "$(q count compose-doc-append-entry)"
    assert_eq "C/no-call-site-left-unscoped" "" "$(q unscoped)"
}
